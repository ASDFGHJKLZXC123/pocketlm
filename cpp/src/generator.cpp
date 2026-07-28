#include "generator.h"

#include "metrics.h"
#include "tokenizer.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace {

std::atomic<int> g_live_sessions{0};
std::atomic<int> g_live_requests{0};

} // namespace

pocketlm_session::~pocketlm_session() {
    g_live_sessions.fetch_sub(1, std::memory_order_relaxed);
}

namespace pocketlm {
namespace {

class SystemClock final : public Clock {
public:
    int64_t now_ms() const noexcept override {
        using namespace std::chrono;
        return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
    }
};

struct Terminal {
    bool is_error = false;
    pocketlm_error_code error_code = POCKETLM_OK;
    std::string error_message;
    const char* static_error_message = nullptr;
    size_t static_error_message_length = 0;
    pocketlm_stats stats{};
};

constexpr char kGenerationOomMessage[] = "out of memory during generation";
constexpr char kGenerationExceptionMessage[] =
    "internal exception during generation";
constexpr char kFinalizationExceptionMessage[] =
    "internal exception during request finalization";

bool is_cancelled(const pocketlm_session* session,
                  pocketlm_request_id request_id) noexcept {
    return session->cancellation_id.load(std::memory_order_acquire) == request_id;
}

void update_peak_rss(pocketlm_session* session) noexcept {
    const int64_t rss = static_cast<int64_t>(rss_bytes());
    if (rss <= 0) {
        return;
    }
    int64_t previous = session->peak_rss_bytes.load(std::memory_order_relaxed);
    while (rss > previous &&
           !session->peak_rss_bytes.compare_exchange_weak(
               previous, rss, std::memory_order_relaxed)) {
    }
}

void call_hook(pocketlm_session* session,
               SessionState state,
               pocketlm_request_id request_id) {
    if (session->hooks != nullptr) {
        session->hooks->at_state(state, request_id);
    }
}

void enter_worker_state(pocketlm_session* session,
                        SessionState state,
                        pocketlm_request_id request_id) {
    {
        std::lock_guard<std::mutex> lock(session->mutex);
        if (!session->shutdown) {
            session->state = state;
        }
    }
    call_hook(session, state, request_id);
}

Terminal make_error(pocketlm_error_code code, std::string message) {
    Terminal terminal;
    terminal.is_error = true;
    terminal.error_code = code == POCKETLM_OK ? POCKETLM_ERR_INTERNAL : code;
    terminal.error_message = sanitizeUtf8(message);
    if (terminal.error_message.empty()) {
        terminal.error_message = "unknown inference error";
    }
    return terminal;
}

template <size_t N>
Terminal make_static_error(pocketlm_error_code code,
                           const char (&message)[N]) noexcept {
    static_assert(N > 1U, "terminal error messages must be non-empty");
    Terminal terminal;
    terminal.is_error = true;
    terminal.error_code = code == POCKETLM_OK ? POCKETLM_ERR_INTERNAL : code;
    terminal.static_error_message = message;
    terminal.static_error_message_length = N - 1U;
    return terminal;
}

Terminal make_cancelled(int64_t prefill_ms,
                        int64_t decode_ms,
                        int32_t prompt_tokens,
                        int32_t generated_tokens) {
    Terminal terminal;
    terminal.stats.prefill_ms = prefill_ms;
    terminal.stats.decode_ms = decode_ms;
    terminal.stats.prompt_tokens = prompt_tokens;
    terminal.stats.generated_tokens = generated_tokens;
    terminal.stats.reason = POCKETLM_FINISH_CANCELLED;
    return terminal;
}

bool emit_token(const Request& request,
                int32_t index,
                const std::string& bytes) noexcept {
    if (bytes.empty()) {
        return true;
    }
    const pocketlm_token_event payload{bytes.data(), bytes.size(), index};
    try {
        request.callback(
            request.user_data, request.id, POCKETLM_EVT_TOKEN, &payload);
        return true;
    } catch (...) {
        return false;
    }
}

BackendResult tokenize_with_trimming(pocketlm_session* session,
                                     const Request& request,
                                     std::vector<int32_t>& prompt_tokens) {
    std::vector<OwnedMessage> retained = request.messages;
    const int32_t context_size = session->backend->diagnostics().context_size;

    while (true) {
        if (is_cancelled(session, request.id)) {
            return BackendResult::cancelled();
        }

        prompt_tokens.clear();
        BackendResult result = session->backend->format_and_tokenize(
            retained, prompt_tokens);
        if (!result) {
            return result;
        }

        const int64_t required = static_cast<int64_t>(prompt_tokens.size()) +
            static_cast<int64_t>(request.params.max_tokens);
        if (required <= context_size) {
            return BackendResult::success();
        }

        const size_t first_turn =
            retained.front().role == POCKETLM_ROLE_SYSTEM ? 1U : 0U;
        const size_t messages_after_prefix = retained.size() - first_turn;
        if (messages_after_prefix < 3U) {
            return BackendResult::failure(
                POCKETLM_ERR_PROMPT_TOO_LONG,
                "the system message and newest user turn do not fit with the requested output allowance");
        }

        retained.erase(
            retained.begin() + static_cast<std::ptrdiff_t>(first_turn),
            retained.begin() + static_cast<std::ptrdiff_t>(first_turn + 2U));
    }
}

Terminal run_request(pocketlm_session* session, const Request& request) {
    const int64_t prefill_started = session->clock->now_ms();
    int32_t prompt_token_count = 0;
    int32_t generated_tokens = 0;

    if (is_cancelled(session, request.id)) {
        return make_cancelled(0, 0, 0, 0);
    }

    std::vector<int32_t> prompt_tokens;
    BackendResult result = tokenize_with_trimming(session, request, prompt_tokens);
    if (result.aborted || is_cancelled(session, request.id)) {
        return make_cancelled(
            session->clock->now_ms() - prefill_started, 0, 0, 0);
    }
    if (!result) {
        return make_error(result.code, std::move(result.message));
    }

    if (prompt_tokens.size() >
        static_cast<size_t>(std::numeric_limits<int32_t>::max())) {
        return make_error(
            POCKETLM_ERR_PROMPT_TOO_LONG,
            "the formatted prompt has too many tokens");
    }
    prompt_token_count = static_cast<int32_t>(prompt_tokens.size());

    result = session->backend->begin_request(request.params);
    if (result.aborted || is_cancelled(session, request.id)) {
        return make_cancelled(
            session->clock->now_ms() - prefill_started,
            0,
            prompt_token_count,
            0);
    }
    if (!result) {
        return make_error(result.code, std::move(result.message));
    }

    session->backend->set_abort_probe(&session->cancellation_id, request.id);

    const pocketlm_session_diagnostics diagnostics = session->backend->diagnostics();
    const size_t batch_size = static_cast<size_t>(std::max(1, diagnostics.batch_size));
    for (size_t offset = 0; offset < prompt_tokens.size(); offset += batch_size) {
        if (is_cancelled(session, request.id)) {
            return make_cancelled(
                session->clock->now_ms() - prefill_started,
                0,
                prompt_token_count,
                0);
        }
        const size_t count = std::min(batch_size, prompt_tokens.size() - offset);
        result = session->backend->decode(prompt_tokens.data() + offset, count);
        if (result.aborted || is_cancelled(session, request.id)) {
            return make_cancelled(
                session->clock->now_ms() - prefill_started,
                0,
                prompt_token_count,
                0);
        }
        if (!result) {
            return make_error(result.code, std::move(result.message));
        }
        update_peak_rss(session);
    }

    const int64_t prefill_ms = session->clock->now_ms() - prefill_started;
    enter_worker_state(session, SessionState::Decoding, request.id);
    const int64_t decode_started = session->clock->now_ms();

    const int32_t remaining_context = diagnostics.context_size - prompt_token_count;
    if (remaining_context <= 0) {
        Terminal terminal;
        terminal.stats.prefill_ms = prefill_ms;
        terminal.stats.decode_ms = 0;
        terminal.stats.prompt_tokens = prompt_token_count;
        terminal.stats.generated_tokens = 0;
        terminal.stats.reason = POCKETLM_FINISH_CONTEXT_EXHAUSTED;
        return terminal;
    }

    const int32_t output_limit = std::min(request.params.max_tokens, remaining_context);
    const bool context_limited = remaining_context < request.params.max_tokens;
    pocketlm_finish_reason reason = context_limited
        ? POCKETLM_FINISH_CONTEXT_EXHAUSTED
        : POCKETLM_FINISH_MAX_TOKENS;

    Utf8Flusher utf8;
    int32_t fragment_index = 0;
    while (generated_tokens < output_limit) {
        if (is_cancelled(session, request.id)) {
            utf8.discard_incomplete();
            return make_cancelled(
                prefill_ms,
                session->clock->now_ms() - decode_started,
                prompt_token_count,
                generated_tokens);
        }

        SampleResult sampled = session->backend->sample();
        if (sampled.result.aborted || is_cancelled(session, request.id)) {
            utf8.discard_incomplete();
            return make_cancelled(
                prefill_ms,
                session->clock->now_ms() - decode_started,
                prompt_token_count,
                generated_tokens);
        }
        if (!sampled.result) {
            utf8.discard_incomplete();
            return make_error(
                sampled.result.code, std::move(sampled.result.message));
        }
        if (sampled.eog) {
            reason = POCKETLM_FINISH_EOS;
            break;
        }

        ++generated_tokens;
        const std::string fragment = utf8.feed(
            sampled.bytes.data(), static_cast<int>(sampled.bytes.size()));
        if (!fragment.empty()) {
            if (!emit_token(request, fragment_index, fragment)) {
                utf8.discard_incomplete();
                return make_error(
                    POCKETLM_ERR_INTERNAL,
                    "the event callback threw an exception");
            }
            ++fragment_index;
        }

        if (is_cancelled(session, request.id)) {
            utf8.discard_incomplete();
            return make_cancelled(
                prefill_ms,
                session->clock->now_ms() - decode_started,
                prompt_token_count,
                generated_tokens);
        }
        if (generated_tokens >= output_limit) {
            break;
        }

        result = session->backend->decode(&sampled.token, 1U);
        if (result.aborted || is_cancelled(session, request.id)) {
            utf8.discard_incomplete();
            return make_cancelled(
                prefill_ms,
                session->clock->now_ms() - decode_started,
                prompt_token_count,
                generated_tokens);
        }
        if (!result) {
            utf8.discard_incomplete();
            return make_error(result.code, std::move(result.message));
        }
        update_peak_rss(session);
    }

    utf8.discard_incomplete();
    Terminal terminal;
    terminal.stats.prefill_ms = prefill_ms;
    terminal.stats.decode_ms = session->clock->now_ms() - decode_started;
    terminal.stats.prompt_tokens = prompt_token_count;
    terminal.stats.generated_tokens = generated_tokens;
    terminal.stats.reason = reason;
    return terminal;
}

void emit_terminal(const Request& request, const Terminal& terminal) noexcept {
    try {
        if (terminal.is_error) {
            const bool has_static_message =
                terminal.static_error_message != nullptr;
            const pocketlm_error payload{
                terminal.error_code,
                has_static_message
                    ? terminal.static_error_message
                    : terminal.error_message.data(),
                has_static_message
                    ? terminal.static_error_message_length
                    : terminal.error_message.size(),
            };
            request.callback(
                request.user_data, request.id, POCKETLM_EVT_ERROR, &payload);
        } else {
            request.callback(
                request.user_data, request.id, POCKETLM_EVT_DONE, &terminal.stats);
        }
    } catch (...) {
        // A foreign callback is required to return normally. Suppress exceptions
        // so the worker and session lifetime remain intact.
    }
}

void finish_request(pocketlm_session* session,
                    const Request& request,
                    Terminal terminal) noexcept {
    session->backend->clear_request();
    update_peak_rss(session);
    terminal.stats.peak_rss_bytes =
        session->peak_rss_bytes.load(std::memory_order_relaxed);

    try {
        enter_worker_state(session, SessionState::Finishing, request.id);
    } catch (...) {
        if (!terminal.is_error) {
            terminal = make_static_error(
                POCKETLM_ERR_INTERNAL,
                kFinalizationExceptionMessage);
        }
    }
    emit_terminal(request, terminal);

    std::lock_guard<std::mutex> lock(session->mutex);
    session->active_request_id.store(
        POCKETLM_REQUEST_ID_INVALID, std::memory_order_release);
    session->cancellation_id.store(
        POCKETLM_REQUEST_ID_INVALID, std::memory_order_release);
    session->state = session->shutdown
        ? SessionState::ShuttingDown
        : SessionState::Idle;
    session->worker_cv.notify_all();
}

} // namespace

Request::Request() {
    g_live_requests.fetch_add(1, std::memory_order_relaxed);
}

Request::~Request() {
    g_live_requests.fetch_sub(1, std::memory_order_relaxed);
}

std::shared_ptr<Clock> make_system_clock() {
    return std::make_shared<SystemClock>();
}

pocketlm_error_code create_session_with_backend(
    std::unique_ptr<Backend> backend,
    std::shared_ptr<Clock> clock,
    std::shared_ptr<WorkerHooks> hooks,
    pocketlm_session** out_session) {
    if (out_session == nullptr || backend == nullptr) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }
    *out_session = nullptr;

    try {
        std::unique_ptr<pocketlm_session> session(new pocketlm_session());
        g_live_sessions.fetch_add(1, std::memory_order_relaxed);
        session->backend = std::move(backend);
        session->clock = clock != nullptr ? std::move(clock) : make_system_clock();
        session->hooks = std::move(hooks);
        update_peak_rss(session.get());
        session->worker = std::thread(worker_main, session.get());
        *out_session = session.release();
        return POCKETLM_OK;
    } catch (const std::bad_alloc&) {
        return POCKETLM_ERR_OOM;
    } catch (...) {
        return POCKETLM_ERR_INTERNAL;
    }
}

void worker_main(pocketlm_session* session) noexcept {
    while (true) {
        pocketlm_request_id queued_id = POCKETLM_REQUEST_ID_INVALID;
        {
            std::unique_lock<std::mutex> lock(session->mutex);
            session->worker_cv.wait(lock, [&] {
                return session->pending_request != nullptr || session->shutdown;
            });
            if (session->pending_request == nullptr && session->shutdown) {
                break;
            }
            queued_id = session->pending_request->id;
        }

        try {
            call_hook(session, SessionState::Queued, queued_id);
        } catch (...) {
            // The request is still finalized below as an internal error.
        }

        std::unique_ptr<Request> request;
        {
            std::lock_guard<std::mutex> lock(session->mutex);
            request = std::move(session->pending_request);
            if (!session->shutdown) {
                session->state = SessionState::Prefilling;
            }
        }

        Terminal terminal;
        if (is_cancelled(session, request->id)) {
            terminal = make_cancelled(0, 0, 0, 0);
        } else {
            try {
                call_hook(session, SessionState::Prefilling, request->id);
                terminal = run_request(session, *request);
            } catch (const std::bad_alloc&) {
                terminal = make_static_error(
                    POCKETLM_ERR_OOM, kGenerationOomMessage);
            } catch (const std::exception&) {
                terminal = make_static_error(
                    POCKETLM_ERR_INTERNAL, kGenerationExceptionMessage);
            } catch (...) {
                terminal = make_static_error(
                    POCKETLM_ERR_INTERNAL,
                    kGenerationExceptionMessage);
            }
        }

        finish_request(session, *request, std::move(terminal));
        request.reset();

        std::lock_guard<std::mutex> lock(session->mutex);
        if (session->shutdown) {
            break;
        }
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    session->state = SessionState::Destroyed;
    session->worker_cv.notify_all();
}

namespace testing {
int live_session_count() noexcept {
    return g_live_sessions.load(std::memory_order_relaxed);
}

int live_request_count() noexcept {
    return g_live_requests.load(std::memory_order_relaxed);
}
} // namespace testing

} // namespace pocketlm
