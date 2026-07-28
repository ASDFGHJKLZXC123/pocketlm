#include "pocketlm_core.h"

#include "generator.h"
#include "llama_backend.h"
#include "session.h"
#include "tokenizer.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr const char* kVersion = "0.1.0-dev+llama.b8833";

bool valid_accelerator(pocketlm_accelerator accelerator) noexcept {
    return accelerator == POCKETLM_ACCELERATOR_AUTO ||
        accelerator == POCKETLM_ACCELERATOR_CPU ||
        accelerator == POCKETLM_ACCELERATOR_METAL;
}

bool valid_config(const pocketlm_session_config& config) noexcept {
    return config.context_size > 0 && config.gpu_layers >= 0 &&
        valid_accelerator(config.accelerator);
}

bool valid_params(const pocketlm_params& params) noexcept {
    return params.max_tokens > 0 &&
        std::isfinite(params.temperature) && params.temperature >= 0.0F &&
        params.top_k >= 0 && std::isfinite(params.top_p) &&
        params.top_p > 0.0F && params.top_p <= 1.0F &&
        params.n_threads >= 0;
}

bool copy_and_validate_messages(const pocketlm_message* messages,
                                size_t message_count,
                                std::vector<pocketlm::OwnedMessage>& output) {
    if (messages == nullptr || message_count == 0 ||
        message_count > static_cast<size_t>(std::numeric_limits<int32_t>::max())) {
        return false;
    }

    size_t index = 0;
    if (messages[0].role == POCKETLM_ROLE_SYSTEM) {
        index = 1;
    }
    if (index >= message_count) {
        return false;
    }

    output.clear();
    output.reserve(message_count);
    for (size_t current = 0; current < message_count; ++current) {
        const pocketlm_message& message = messages[current];
        if (message.content == nullptr || message.content[0] == '\0') {
            return false;
        }

        pocketlm_role expected = POCKETLM_ROLE_SYSTEM;
        if (current != 0 || index == 0) {
            const size_t turn_index = current - index;
            expected = turn_index % 2U == 0U
                ? POCKETLM_ROLE_USER
                : POCKETLM_ROLE_ASSISTANT;
        }
        if (message.role != expected) {
            return false;
        }

        std::string content(message.content);
        if (!pocketlm::isValidUtf8(content)) {
            return false;
        }
        output.push_back({message.role, std::move(content)});
    }

    return output.back().role == POCKETLM_ROLE_USER;
}

} // namespace

extern "C" pocketlm_session_config pocketlm_default_session_config(void) {
    return {2048, POCKETLM_ACCELERATOR_AUTO, 0};
}

extern "C" pocketlm_params pocketlm_default_params(void) {
    return {256, 0.7F, 40, 0.9F, -1, 0};
}

extern "C" pocketlm_error_code pocketlm_create_v2(
    const char* model_path,
    const pocketlm_session_config* config,
    pocketlm_session** out_session) {
    if (out_session == nullptr) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }
    *out_session = nullptr;
    if (model_path == nullptr || model_path[0] == '\0') {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }

    try {
        const std::string path(model_path);
        if (!pocketlm::isValidUtf8(path)) {
            return POCKETLM_ERR_INVALID_ARGUMENT;
        }
        const pocketlm_session_config selected_config = config != nullptr
            ? *config
            : pocketlm_default_session_config();
        if (!valid_config(selected_config)) {
            return POCKETLM_ERR_INVALID_ARGUMENT;
        }

        std::unique_ptr<pocketlm::Backend> backend;
        pocketlm::BackendResult result = pocketlm::create_llama_backend(
            model_path, selected_config, backend);
        if (!result) {
            return result.code;
        }
        return pocketlm::create_session_with_backend(
            std::move(backend), nullptr, nullptr, out_session);
    } catch (const std::bad_alloc&) {
        return POCKETLM_ERR_OOM;
    } catch (...) {
        return POCKETLM_ERR_INTERNAL;
    }
}

extern "C" void pocketlm_destroy(pocketlm_session* session) {
    if (session == nullptr) {
        return;
    }

    try {
        {
            std::unique_lock<std::mutex> lock(session->mutex);
            session->accepting_api_calls = false;
            session->api_cv.notify_all();
            session->api_cv.wait(lock, [&] {
                return session->admitted_api_calls == 0;
            });
            session->shutdown = true;
            session->state = pocketlm::SessionState::ShuttingDown;
            const pocketlm_request_id active =
                session->active_request_id.load(std::memory_order_acquire);
            if (active != POCKETLM_REQUEST_ID_INVALID) {
                session->cancellation_id.store(active, std::memory_order_release);
            }
            session->worker_cv.notify_all();
        }

        if (session->worker.joinable()) {
            if (session->worker.get_id() == std::this_thread::get_id()) {
                // Recursive destruction from a callback violates the frozen
                // contract. Prefer a bounded leak to self-join/use-after-free.
                return;
            }
            session->worker.join();
        }
        delete session;
    } catch (...) {
        // No exception may cross the C ABI. Correct callers never reach the
        // exceptional self-join/system-error path.
    }
}

extern "C" pocketlm_request_id pocketlm_generate_v2(
    pocketlm_session* session,
    const pocketlm_message* messages,
    size_t message_count,
    const pocketlm_params* params,
    pocketlm_event_cb callback,
    void* user_data) {
    if (session == nullptr) {
        return POCKETLM_GENERATE_INVALID_ARGUMENT;
    }

    pocketlm::ApiCallGuard guard(session);
    if (!guard.admitted()) {
        return POCKETLM_GENERATE_SHUTTING_DOWN;
    }

    try {
        std::lock_guard<std::mutex> lock(session->mutex);
        if (session->shutdown || !session->accepting_api_calls) {
            return POCKETLM_GENERATE_SHUTTING_DOWN;
        }
        if (session->state != pocketlm::SessionState::Idle) {
            return POCKETLM_GENERATE_BUSY;
        }
        if (callback == nullptr) {
            return POCKETLM_GENERATE_INVALID_ARGUMENT;
        }

        const pocketlm_params copied_params = params != nullptr
            ? *params
            : pocketlm_default_params();
        if (!valid_params(copied_params)) {
            return POCKETLM_GENERATE_INVALID_ARGUMENT;
        }

        if (session->hooks != nullptr) {
            session->hooks->before_request_copy();
        }
        std::unique_ptr<pocketlm::Request> request(new pocketlm::Request());
        if (!copy_and_validate_messages(
                messages, message_count, request->messages)) {
            return POCKETLM_GENERATE_INVALID_ARGUMENT;
        }
        request->params = copied_params;
        request->callback = callback;
        request->user_data = user_data;

        if (session->next_request_id >
            static_cast<int64_t>(std::numeric_limits<pocketlm_request_id>::max())) {
            return POCKETLM_GENERATE_ID_EXHAUSTED;
        }

        request->id = static_cast<pocketlm_request_id>(session->next_request_id++);
        const pocketlm_request_id accepted_id = request->id;
        session->active_request_id.store(accepted_id, std::memory_order_release);
        session->cancellation_id.store(
            POCKETLM_REQUEST_ID_INVALID, std::memory_order_release);
        session->pending_request = std::move(request);
        session->state = pocketlm::SessionState::Queued;
        session->worker_cv.notify_one();
        return accepted_id;
    } catch (const std::bad_alloc&) {
        return POCKETLM_GENERATE_OOM;
    } catch (...) {
        return POCKETLM_GENERATE_INVALID_ARGUMENT;
    }
}

extern "C" void pocketlm_cancel(
    pocketlm_session* session,
    pocketlm_request_id request_id) {
    if (session == nullptr || request_id <= POCKETLM_REQUEST_ID_INVALID) {
        return;
    }
    pocketlm::ApiCallGuard guard(session);
    if (!guard.admitted()) {
        return;
    }

    const pocketlm_request_id active =
        session->active_request_id.load(std::memory_order_acquire);
    if (active == request_id) {
        session->cancellation_id.store(request_id, std::memory_order_release);
        session->worker_cv.notify_all();
    }
}

extern "C" pocketlm_error_code pocketlm_get_diagnostics(
    const pocketlm_session* session,
    pocketlm_session_diagnostics* out_diagnostics) {
    if (session == nullptr || out_diagnostics == nullptr) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }
    auto* mutable_session = const_cast<pocketlm_session*>(session);
    pocketlm::ApiCallGuard guard(mutable_session);
    if (!guard.admitted()) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }

    try {
        *out_diagnostics = session->backend->diagnostics();
        out_diagnostics->peak_rss_bytes =
            session->peak_rss_bytes.load(std::memory_order_relaxed);
        return POCKETLM_OK;
    } catch (...) {
        return POCKETLM_ERR_INTERNAL;
    }
}

extern "C" int64_t pocketlm_peak_rss_bytes(const pocketlm_session* session) {
    if (session == nullptr) {
        return 0;
    }
    auto* mutable_session = const_cast<pocketlm_session*>(session);
    pocketlm::ApiCallGuard guard(mutable_session);
    if (!guard.admitted()) {
        return 0;
    }
    return session->peak_rss_bytes.load(std::memory_order_relaxed);
}

extern "C" uint32_t pocketlm_abi_version(void) {
    return POCKETLM_ABI_VERSION;
}

extern "C" const char* pocketlm_version(void) {
    return kVersion;
}

extern "C" const char* pocketlm_error_code_string(pocketlm_error_code code) {
    switch (code) {
    case POCKETLM_OK:
        return "OK";
    case POCKETLM_ERR_INVALID_ARGUMENT:
        return "INVALID_ARGUMENT";
    case POCKETLM_ERR_OOM:
        return "OOM";
    case POCKETLM_ERR_MODEL_LOAD_FAILED:
        return "MODEL_LOAD_FAILED";
    case POCKETLM_ERR_CONTEXT_CREATE_FAILED:
        return "CONTEXT_CREATE_FAILED";
    case POCKETLM_ERR_METAL_UNAVAILABLE:
        return "METAL_UNAVAILABLE";
    case POCKETLM_ERR_CHAT_TEMPLATE_FAILED:
        return "CHAT_TEMPLATE_FAILED";
    case POCKETLM_ERR_TOKENIZE_FAILED:
        return "TOKENIZE_FAILED";
    case POCKETLM_ERR_PROMPT_TOO_LONG:
        return "PROMPT_TOO_LONG";
    case POCKETLM_ERR_DECODE_FAILED:
        return "DECODE_FAILED";
    case POCKETLM_ERR_INTERNAL:
        return "INTERNAL";
    }
    return "UNKNOWN";
}
