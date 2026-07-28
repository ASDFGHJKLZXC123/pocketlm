#include "FakePocketLMCoreControl.h"
#include "pocketlm_core.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

struct pocketlm_session {
    std::mutex mutex;
    std::condition_variable condition;
    std::thread worker;
    pocketlm_session_config config{};
    int32_t next_request_id = 1;
    bool busy = false;
    bool cancel_requested = false;
    bool release_requested = false;
    bool shutting_down = false;
};

static std::atomic<int32_t> g_create_count{0};
static std::atomic<int32_t> g_destroy_count{0};
static std::atomic<int32_t> g_callback_count{0};
static std::atomic<int32_t> g_generate_call_count{0};
static std::atomic<int32_t> g_cancel_call_count{0};
static std::atomic<int32_t> g_diagnostics_call_count{0};
static std::atomic<bool> g_throw_next_cancel{false};
static std::atomic<int32_t> g_diagnostic_requested_override{-1};
static std::atomic<int32_t> g_diagnostic_selected_override{-1};
static std::atomic<int32_t> g_diagnostic_offloaded_override{
    std::numeric_limits<int32_t>::min()};
static std::atomic<int32_t> g_diagnostic_kqv_override{
    std::numeric_limits<int32_t>::min()};
static std::atomic<int64_t> g_diagnostic_peak_rss_override{
    std::numeric_limits<int64_t>::min()};
static std::mutex g_sessions_mutex;
static std::vector<pocketlm_session *> g_sessions;
static std::mutex g_destroy_control_mutex;
static std::condition_variable g_destroy_control_condition;
static bool g_destroy_blocked = false;
static int32_t g_destroy_started_count = 0;

struct fake_interleave_slot {
    pocketlm_session *session = nullptr;
    pocketlm_event_cb callback = nullptr;
    void *user_data = nullptr;
    int32_t request_id = 0;
    bool fault_sequence = false;
};

static std::mutex g_interleave_mutex;
static fake_interleave_slot g_interleave_a;
static fake_interleave_slot g_interleave_b;
static std::mutex g_idle_condition_mutex;
static std::condition_variable g_idle_condition;

static void fake_notify_idle_waiters(void) {
    {
        // Pair with wait_for's mutex so a transition cannot notify between the
        // predicate check and its atomic wait.
        std::lock_guard<std::mutex> lock(g_idle_condition_mutex);
    }
    g_idle_condition.notify_all();
}

static bool fake_all_sessions_idle(void) {
    std::lock_guard<std::mutex> sessions_lock(g_sessions_mutex);
    for (pocketlm_session *session : g_sessions) {
        std::lock_guard<std::mutex> session_lock(session->mutex);
        if (session->busy) {
            return false;
        }
    }
    return true;
}

static void fake_emit_token(pocketlm_event_cb callback, void *user_data,
                            int32_t request_id, int32_t index, const std::string &text) {
    pocketlm_token_event event{text.data(), text.size(), index};
    g_callback_count.fetch_add(1, std::memory_order_relaxed);
    callback(user_data, request_id, POCKETLM_EVT_TOKEN, &event);
}

static void fake_emit_done(pocketlm_event_cb callback, void *user_data,
                           int32_t request_id, pocketlm_finish_reason reason,
                           int32_t generated_tokens) {
    pocketlm_stats stats{11, 22, 7, generated_tokens, 123456, reason};
    g_callback_count.fetch_add(1, std::memory_order_relaxed);
    callback(user_data, request_id, POCKETLM_EVT_DONE, &stats);
}

static void fake_emit_error(pocketlm_event_cb callback, void *user_data,
                            int32_t request_id, pocketlm_error_code code) {
    std::string message = std::string("fake-") + pocketlm_error_code_string(code);
    pocketlm_error error{code, message.data(), message.size()};
    g_callback_count.fetch_add(1, std::memory_order_relaxed);
    callback(user_data, request_id, POCKETLM_EVT_ERROR, &error);
}

static bool fake_messages_valid(const pocketlm_message *messages, size_t count) {
    if (messages == nullptr || count == 0) {
        return false;
    }
    for (size_t i = 0; i < count; ++i) {
        if (messages[i].content == nullptr || messages[i].content[0] == '\0') {
            return false;
        }
    }
    return true;
}

extern "C" pocketlm_session_config pocketlm_default_session_config(void) {
    return {2048, POCKETLM_ACCELERATOR_AUTO, 0};
}

extern "C" pocketlm_params pocketlm_default_params(void) {
    return {256, 0.7f, 40, 0.9f, -1, 0};
}

extern "C" pocketlm_error_code pocketlm_create_v2(
    const char *model_path,
    const pocketlm_session_config *config,
    pocketlm_session **out_session) {
    if (out_session == nullptr) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }
    *out_session = nullptr;
    pocketlm_session_config effective = config == nullptr
        ? pocketlm_default_session_config() : *config;
    if (model_path == nullptr || model_path[0] == '\0' || effective.context_size <= 0 ||
        effective.gpu_layers < 0 || effective.accelerator < POCKETLM_ACCELERATOR_AUTO ||
        effective.accelerator > POCKETLM_ACCELERATOR_METAL) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }
    if (std::strstr(model_path, "load-fail") != nullptr) {
        return POCKETLM_ERR_MODEL_LOAD_FAILED;
    }
    auto *session = new pocketlm_session();
    session->config = effective;
    {
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        g_sessions.push_back(session);
    }
    g_create_count.fetch_add(1, std::memory_order_relaxed);
    *out_session = session;
    return POCKETLM_OK;
}

extern "C" void pocketlm_destroy(pocketlm_session *session) {
    if (session == nullptr) {
        return;
    }
    {
        std::unique_lock<std::mutex> lock(g_destroy_control_mutex);
        g_destroy_started_count += 1;
        g_destroy_control_condition.notify_all();
        g_destroy_control_condition.wait(lock, [] {
            return !g_destroy_blocked;
        });
    }
    {
        std::lock_guard<std::mutex> lock(g_sessions_mutex);
        g_sessions.erase(std::remove(g_sessions.begin(), g_sessions.end(), session),
                         g_sessions.end());
    }
    {
        std::lock_guard<std::mutex> lock(g_interleave_mutex);
        if (g_interleave_a.session == session) {
            g_interleave_a = {};
        }
        if (g_interleave_b.session == session) {
            g_interleave_b = {};
        }
    }
    {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->shutting_down = true;
        session->cancel_requested = true;
        session->release_requested = true;
    }
    session->condition.notify_all();
    if (session->worker.joinable()) {
        session->worker.join();
    }
    g_destroy_count.fetch_add(1, std::memory_order_relaxed);
    delete session;
}

extern "C" pocketlm_request_id pocketlm_generate_v2(
    pocketlm_session *session,
    const pocketlm_message *messages,
    size_t message_count,
    const pocketlm_params *params,
    pocketlm_event_cb callback,
    void *user_data) {
    g_generate_call_count.fetch_add(1, std::memory_order_relaxed);
    if (session == nullptr || callback == nullptr ||
        !fake_messages_valid(messages, message_count)) {
        return POCKETLM_GENERATE_INVALID_ARGUMENT;
    }
    pocketlm_params effective = params == nullptr ? pocketlm_default_params() : *params;
    if (effective.max_tokens <= 0 || effective.temperature < 0 || effective.top_k < 0 ||
        effective.top_p <= 0 || effective.top_p > 1 || effective.n_threads < 0) {
        return POCKETLM_GENERATE_INVALID_ARGUMENT;
    }
    std::string mode = messages[message_count - 1].content;
    if (mode == "reject") {
        return POCKETLM_GENERATE_BUSY;
    }

    int32_t request_id = 0;
    std::thread completed_worker;
    {
        std::lock_guard<std::mutex> lock(session->mutex);
        if (session->shutting_down) {
            return POCKETLM_GENERATE_SHUTTING_DOWN;
        }
        if (session->busy) {
            return POCKETLM_GENERATE_BUSY;
        }
        // An asynchronous request clears busy before its worker returns so the
        // bridge can observe Idle promptly. Reap that finished worker outside
        // the session mutex before assigning the next worker: overwriting a
        // still-joinable std::thread would call std::terminate.
        if (session->worker.joinable()) {
            completed_worker = std::move(session->worker);
        }
        session->busy = true;
        session->cancel_requested = false;
        session->release_requested = false;
        request_id = session->next_request_id++;
    }
    if (completed_worker.joinable()) {
        completed_worker.join();
    }

    auto finish_sync = [session] {
        {
            std::lock_guard<std::mutex> lock(session->mutex);
            session->busy = false;
        }
        fake_notify_idle_waiters();
    };

    if (mode == "malformed-done-null") {
        g_callback_count.fetch_add(1, std::memory_order_relaxed);
        callback(user_data, request_id, POCKETLM_EVT_DONE, nullptr);
        finish_sync();
        return request_id;
    }
    if (mode == "malformed-error-null") {
        g_callback_count.fetch_add(1, std::memory_order_relaxed);
        callback(user_data, request_id, POCKETLM_EVT_ERROR, nullptr);
        finish_sync();
        return request_id;
    }
    if (mode == "invalid-request-id") {
        g_callback_count.fetch_add(1, std::memory_order_relaxed);
        callback(user_data, POCKETLM_REQUEST_ID_INVALID, POCKETLM_EVT_DONE, nullptr);
        finish_sync();
        return request_id;
    }
    if (mode == "wrong-request-id-sync") {
        int32_t wrong_request_id = request_id + 1000;
        fake_emit_token(callback, user_data, wrong_request_id, 0, "wrong-sync");
        fake_emit_done(callback, user_data, wrong_request_id, POCKETLM_FINISH_EOS, 1);
        finish_sync();
        return request_id;
    }
    if (mode == "no-terminal") {
        finish_sync();
        return request_id;
    }
    if (mode == "interleave-a" || mode == "interleave-b" ||
        mode == "interleave-fault-a" || mode == "interleave-fault-b") {
        std::lock_guard<std::mutex> lock(g_interleave_mutex);
        bool fault_sequence = mode == "interleave-fault-a" ||
                              mode == "interleave-fault-b";
        fake_interleave_slot slot{session, callback, user_data, request_id,
                                  fault_sequence};
        if (mode == "interleave-a" || mode == "interleave-fault-a") {
            g_interleave_a = slot;
        } else {
            g_interleave_b = slot;
        }
        return request_id;
    }
    if (mode == "gap-then-done") {
        fake_emit_token(callback, user_data, request_id, 1, "gap");
        fake_emit_done(callback, user_data, request_id, POCKETLM_FINISH_EOS, 1);
        finish_sync();
        return request_id;
    }
    if (mode == "over-safe-prefill" || mode == "over-safe-decode" ||
        mode == "over-safe-peak-rss") {
        pocketlm_stats stats{
            mode == "over-safe-prefill" ? 9007199254740992LL : 11,
            mode == "over-safe-decode" ? 9007199254740992LL : 22,
            7,
            1,
            mode == "over-safe-peak-rss" ? 9007199254740992LL : 123456,
            POCKETLM_FINISH_EOS,
        };
        g_callback_count.fetch_add(1, std::memory_order_relaxed);
        callback(user_data, request_id, POCKETLM_EVT_DONE, &stats);
        finish_sync();
        return request_id;
    }

    if (mode.rfind("error:", 0) == 0) {
        int code = std::stoi(mode.substr(6));
        fake_emit_error(callback, user_data, request_id, (pocketlm_error_code)code);
        finish_sync();
        return request_id;
    }
    if (mode.rfind("done:", 0) == 0) {
        int reason = std::stoi(mode.substr(5));
        fake_emit_done(callback, user_data, request_id, (pocketlm_finish_reason)reason, 0);
        finish_sync();
        return request_id;
    }
    if (mode == "byte-threshold") {
        fake_emit_token(callback, user_data, request_id, 0, std::string(5000, 'x'));
        fake_emit_done(callback, user_data, request_id, POCKETLM_FINISH_MAX_TOKENS, 1);
        finish_sync();
        return request_id;
    }
    if (mode == "burst") {
        for (int32_t i = 0; i < 1000; ++i) {
            fake_emit_token(callback, user_data, request_id, i, "x");
        }
        fake_emit_done(callback, user_data, request_id, POCKETLM_FINISH_MAX_TOKENS, 1000);
        finish_sync();
        return request_id;
    }
    if (mode == "timer" || mode == "hold" || mode == "stream-hold" ||
        mode == "wrong-request-id-delayed") {
        session->worker = std::thread([session, callback, user_data, request_id, mode] {
            if (mode == "timer") {
                fake_emit_token(callback, user_data, request_id, 0, "timer");
                std::unique_lock<std::mutex> lock(session->mutex);
                session->condition.wait_for(lock, std::chrono::milliseconds(45), [session] {
                    return session->cancel_requested;
                });
                bool cancelled = session->cancel_requested;
                lock.unlock();
                fake_emit_done(callback, user_data, request_id,
                               cancelled ? POCKETLM_FINISH_CANCELLED : POCKETLM_FINISH_EOS, 1);
            } else {
                if (mode == "stream-hold") {
                    fake_emit_token(callback, user_data, request_id, 0, "stream");
                }
                std::unique_lock<std::mutex> lock(session->mutex);
                session->condition.wait(lock, [session] {
                    return session->release_requested || session->cancel_requested;
                });
                bool cancelled = session->cancel_requested;
                lock.unlock();
                if (mode == "wrong-request-id-delayed" && !cancelled) {
                    int32_t wrong_request_id = request_id + 1000;
                    fake_emit_token(callback, user_data, wrong_request_id, 0, "wrong-delayed");
                    fake_emit_done(callback, user_data, wrong_request_id,
                                   POCKETLM_FINISH_EOS, 1);
                } else if (!cancelled) {
                    if (mode != "stream-hold") {
                        fake_emit_token(callback, user_data, request_id, 0, "old");
                    }
                    fake_emit_done(callback, user_data, request_id,
                                   POCKETLM_FINISH_EOS, 1);
                } else {
                    fake_emit_done(callback, user_data, request_id,
                                   POCKETLM_FINISH_CANCELLED,
                                   mode == "stream-hold" ? 1 : 0);
                }
            }
            {
                std::lock_guard<std::mutex> lock(session->mutex);
                session->busy = false;
            }
            fake_notify_idle_waiters();
        });
        return request_id;
    }

    fake_emit_token(callback, user_data, request_id, 0, "a");
    fake_emit_token(callback, user_data, request_id, 1, "b");
    fake_emit_token(callback, user_data, request_id, 2, "c");
    fake_emit_done(callback, user_data, request_id, POCKETLM_FINISH_EOS, 3);
    finish_sync();
    return request_id;
}

extern "C" void pocketlm_cancel(pocketlm_session *session, pocketlm_request_id request_id) {
    g_cancel_call_count.fetch_add(1, std::memory_order_relaxed);
    if (g_throw_next_cancel.exchange(false, std::memory_order_acq_rel)) {
        throw std::runtime_error("fake cancel exception");
    }
    if (session == nullptr || request_id <= POCKETLM_REQUEST_ID_INVALID) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(session->mutex);
        if (!session->busy) {
            return;
        }
        session->cancel_requested = true;
    }
    session->condition.notify_all();
}

extern "C" pocketlm_error_code pocketlm_get_diagnostics(
    const pocketlm_session *session,
    pocketlm_session_diagnostics *out_diagnostics) {
    g_diagnostics_call_count.fetch_add(1, std::memory_order_relaxed);
    if (session == nullptr || out_diagnostics == nullptr) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }
    int32_t requested_override =
        g_diagnostic_requested_override.load(std::memory_order_relaxed);
    out_diagnostics->requested_accelerator = requested_override >= 0
        ? (pocketlm_accelerator)requested_override
        : session->config.accelerator;
    int32_t selected_override =
        g_diagnostic_selected_override.load(std::memory_order_relaxed);
    out_diagnostics->selected_accelerator = selected_override >= 0
        ? (pocketlm_accelerator)selected_override
        : (session->config.accelerator == POCKETLM_ACCELERATOR_AUTO
               ? POCKETLM_ACCELERATOR_METAL
               : session->config.accelerator);
    out_diagnostics->context_size = session->config.context_size;
    out_diagnostics->batch_size = 128;
    out_diagnostics->model_layers = 24;
    int32_t offloaded_override =
        g_diagnostic_offloaded_override.load(std::memory_order_relaxed);
    out_diagnostics->offloaded_layers =
        offloaded_override != std::numeric_limits<int32_t>::min()
        ? offloaded_override
        : (session->config.accelerator == POCKETLM_ACCELERATOR_CPU ? 0 : 24);
    int32_t kqv_override =
        g_diagnostic_kqv_override.load(std::memory_order_relaxed);
    out_diagnostics->kqv_offloaded =
        kqv_override != std::numeric_limits<int32_t>::min()
        ? kqv_override
        : (session->config.accelerator == POCKETLM_ACCELERATOR_CPU ? 0 : 1);
    int64_t peak_rss_override =
        g_diagnostic_peak_rss_override.load(std::memory_order_relaxed);
    out_diagnostics->peak_rss_bytes =
        peak_rss_override != std::numeric_limits<int64_t>::min()
        ? peak_rss_override
        : 987654;
    return POCKETLM_OK;
}

extern "C" int64_t pocketlm_peak_rss_bytes(const pocketlm_session *session) {
    return session == nullptr ? 0 : 987654;
}

extern "C" uint32_t pocketlm_abi_version(void) {
    return POCKETLM_ABI_VERSION;
}

extern "C" const char *pocketlm_version(void) {
    return "fake-pocketlm-core/2.1";
}

extern "C" const char *pocketlm_error_code_string(pocketlm_error_code code) {
    static const char *names[] = {
        "OK", "INVALID_ARGUMENT", "OOM", "MODEL_LOAD_FAILED", "CONTEXT_CREATE_FAILED",
        "METAL_UNAVAILABLE", "CHAT_TEMPLATE_FAILED", "TOKENIZE_FAILED", "PROMPT_TOO_LONG",
        "DECODE_FAILED", "INTERNAL",
    };
    return code >= POCKETLM_OK && code <= POCKETLM_ERR_INTERNAL ? names[code] : "INTERNAL";
}

extern "C" void pocketlm_fake_reset_counters(void) {
    g_create_count.store(0, std::memory_order_relaxed);
    g_destroy_count.store(0, std::memory_order_relaxed);
    g_callback_count.store(0, std::memory_order_relaxed);
    g_generate_call_count.store(0, std::memory_order_relaxed);
    g_cancel_call_count.store(0, std::memory_order_relaxed);
    g_diagnostics_call_count.store(0, std::memory_order_relaxed);
    g_throw_next_cancel.store(false, std::memory_order_relaxed);
    g_diagnostic_requested_override.store(-1, std::memory_order_relaxed);
    g_diagnostic_selected_override.store(-1, std::memory_order_relaxed);
    g_diagnostic_offloaded_override.store(std::numeric_limits<int32_t>::min(),
                                          std::memory_order_relaxed);
    g_diagnostic_kqv_override.store(std::numeric_limits<int32_t>::min(),
                                    std::memory_order_relaxed);
    g_diagnostic_peak_rss_override.store(std::numeric_limits<int64_t>::min(),
                                         std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(g_destroy_control_mutex);
        g_destroy_blocked = false;
        g_destroy_started_count = 0;
    }
    {
        std::lock_guard<std::mutex> lock(g_interleave_mutex);
        g_interleave_a = {};
        g_interleave_b = {};
    }
    g_destroy_control_condition.notify_all();
}

extern "C" void pocketlm_fake_set_destroy_blocked(int32_t blocked) {
    {
        std::lock_guard<std::mutex> lock(g_destroy_control_mutex);
        g_destroy_blocked = blocked != 0;
    }
    if (blocked == 0) {
        g_destroy_control_condition.notify_all();
    }
}

extern "C" void pocketlm_fake_throw_next_cancel(void) {
    g_throw_next_cancel.store(true, std::memory_order_release);
}

extern "C" int32_t pocketlm_fake_wait_for_destroy_started(
    int32_t minimum_count,
    int32_t timeout_ms) {
    std::unique_lock<std::mutex> lock(g_destroy_control_mutex);
    bool reached = g_destroy_control_condition.wait_for(
        lock, std::chrono::milliseconds(timeout_ms), [minimum_count] {
            return g_destroy_started_count >= minimum_count;
        });
    return reached ? 1 : 0;
}

extern "C" int32_t pocketlm_fake_destroy_started_count(void) {
    std::lock_guard<std::mutex> lock(g_destroy_control_mutex);
    return g_destroy_started_count;
}

extern "C" void pocketlm_fake_set_diagnostics_override(
    int32_t selected_accelerator,
    int32_t offloaded_layers) {
    g_diagnostic_selected_override.store(selected_accelerator, std::memory_order_relaxed);
    g_diagnostic_offloaded_override.store(offloaded_layers, std::memory_order_relaxed);
}

extern "C" void pocketlm_fake_set_diagnostics_requested(
    int32_t requested_accelerator) {
    g_diagnostic_requested_override.store(requested_accelerator,
                                          std::memory_order_relaxed);
}

extern "C" void pocketlm_fake_set_diagnostics_kqv(int32_t kqv_offloaded) {
    g_diagnostic_kqv_override.store(kqv_offloaded, std::memory_order_relaxed);
}

extern "C" void pocketlm_fake_set_diagnostics_peak_rss(int64_t peak_rss_bytes) {
    g_diagnostic_peak_rss_override.store(peak_rss_bytes, std::memory_order_relaxed);
}

extern "C" void pocketlm_fake_clear_diagnostics_override(void) {
    g_diagnostic_requested_override.store(-1, std::memory_order_relaxed);
    g_diagnostic_selected_override.store(-1, std::memory_order_relaxed);
    g_diagnostic_offloaded_override.store(std::numeric_limits<int32_t>::min(),
                                          std::memory_order_relaxed);
    g_diagnostic_kqv_override.store(std::numeric_limits<int32_t>::min(),
                                    std::memory_order_relaxed);
    g_diagnostic_peak_rss_override.store(std::numeric_limits<int64_t>::min(),
                                         std::memory_order_relaxed);
}

extern "C" void pocketlm_fake_release_held_requests(void) {
    std::lock_guard<std::mutex> sessions_lock(g_sessions_mutex);
    for (pocketlm_session *session : g_sessions) {
        {
            std::lock_guard<std::mutex> lock(session->mutex);
            session->release_requested = true;
        }
        session->condition.notify_all();
    }
}

extern "C" int32_t pocketlm_fake_wait_for_all_requests_idle(int32_t timeout_ms) {
    std::unique_lock<std::mutex> lock(g_idle_condition_mutex);
    bool idle = g_idle_condition.wait_for(
        lock, std::chrono::milliseconds(timeout_ms), [] {
            return fake_all_sessions_idle();
        });
    return idle ? 1 : 0;
}

extern "C" int32_t pocketlm_fake_emit_interleaved_requests(void) {
    fake_interleave_slot slot_a;
    fake_interleave_slot slot_b;
    {
        std::lock_guard<std::mutex> lock(g_interleave_mutex);
        if (g_interleave_a.session == nullptr || g_interleave_b.session == nullptr ||
            g_interleave_a.fault_sequence || g_interleave_b.fault_sequence) {
            return 0;
        }
        slot_a = g_interleave_a;
        slot_b = g_interleave_b;
        g_interleave_a = {};
        g_interleave_b = {};
    }

    // One caller thread fixes the exact callback arrival order. B's terminal
    // intentionally arrives before A's timer could flush A1.
    fake_emit_token(slot_a.callback, slot_a.user_data, slot_a.request_id, 0, "a0");
    fake_emit_token(slot_b.callback, slot_b.user_data, slot_b.request_id, 0, "b0");
    fake_emit_token(slot_a.callback, slot_a.user_data, slot_a.request_id, 1, "a1");
    fake_emit_done(slot_b.callback, slot_b.user_data, slot_b.request_id,
                   POCKETLM_FINISH_EOS, 1);
    fake_emit_done(slot_a.callback, slot_a.user_data, slot_a.request_id,
                   POCKETLM_FINISH_EOS, 2);

    {
        std::lock_guard<std::mutex> lock(slot_a.session->mutex);
        slot_a.session->busy = false;
    }
    {
        std::lock_guard<std::mutex> lock(slot_b.session->mutex);
        slot_b.session->busy = false;
    }
    return 1;
}

extern "C" int32_t pocketlm_fake_begin_interleaved_fault_requests(void) {
    fake_interleave_slot slot_a;
    fake_interleave_slot slot_b;
    {
        std::lock_guard<std::mutex> lock(g_interleave_mutex);
        if (g_interleave_a.session == nullptr || g_interleave_b.session == nullptr ||
            !g_interleave_a.fault_sequence || !g_interleave_b.fault_sequence) {
            return 0;
        }
        slot_a = g_interleave_a;
        slot_b = g_interleave_b;
        g_interleave_b = {};
    }

    // A0 is pending when B violates its callback contract. B is no longer
    // busy before the malformed callback can trigger asynchronous teardown.
    fake_emit_token(slot_a.callback, slot_a.user_data, slot_a.request_id, 0, "fault-a0");
    {
        std::lock_guard<std::mutex> lock(slot_b.session->mutex);
        slot_b.session->busy = false;
    }
    g_callback_count.fetch_add(1, std::memory_order_relaxed);
    slot_b.callback(slot_b.user_data, slot_b.request_id, POCKETLM_EVT_DONE, nullptr);
    return 1;
}

extern "C" int32_t pocketlm_fake_finish_interleaved_fault_request(void) {
    fake_interleave_slot slot_a;
    {
        std::lock_guard<std::mutex> lock(g_interleave_mutex);
        if (g_interleave_a.session == nullptr || !g_interleave_a.fault_sequence ||
            g_interleave_b.session != nullptr) {
            return 0;
        }
        slot_a = g_interleave_a;
        g_interleave_a = {};
    }

    fake_emit_token(slot_a.callback, slot_a.user_data, slot_a.request_id, 1, "fault-a1");
    fake_emit_done(slot_a.callback, slot_a.user_data, slot_a.request_id,
                   POCKETLM_FINISH_EOS, 2);
    {
        std::lock_guard<std::mutex> lock(slot_a.session->mutex);
        slot_a.session->busy = false;
    }
    return 1;
}

extern "C" int32_t pocketlm_fake_create_count(void) {
    return g_create_count.load(std::memory_order_relaxed);
}

extern "C" int32_t pocketlm_fake_destroy_count(void) {
    return g_destroy_count.load(std::memory_order_relaxed);
}

extern "C" int32_t pocketlm_fake_callback_count(void) {
    return g_callback_count.load(std::memory_order_relaxed);
}

extern "C" int32_t pocketlm_fake_generate_call_count(void) {
    return g_generate_call_count.load(std::memory_order_relaxed);
}

extern "C" int32_t pocketlm_fake_cancel_call_count(void) {
    return g_cancel_call_count.load(std::memory_order_relaxed);
}

extern "C" int32_t pocketlm_fake_diagnostics_call_count(void) {
    return g_diagnostics_call_count.load(std::memory_order_relaxed);
}
