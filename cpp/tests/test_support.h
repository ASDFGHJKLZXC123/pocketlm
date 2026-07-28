#pragma once

#include "pocketlm_core.h"
#include "session.h"

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace pocketlm::testing {

struct CapturedEvent {
    pocketlm_request_id request_id = POCKETLM_REQUEST_ID_INVALID;
    pocketlm_event_type type = POCKETLM_EVT_TOKEN;
    int32_t index = -1;
    std::string text;
    pocketlm_stats stats{};
    pocketlm_error_code error_code = POCKETLM_OK;
    std::string error_message;
};

class EventCollector {
public:
    static void callback(void* user_data,
                         pocketlm_request_id request_id,
                         pocketlm_event_type type,
                         const void* payload) {
        static_cast<EventCollector*>(user_data)->capture(request_id, type, payload);
    }

    void wait_for_terminals(size_t count) {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&] { return terminal_count_ >= count; });
    }

    std::vector<CapturedEvent> events() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return events_;
    }

    size_t terminal_count() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return terminal_count_;
    }

private:
    void capture(pocketlm_request_id request_id,
                 pocketlm_event_type type,
                 const void* payload) {
        CapturedEvent event;
        event.request_id = request_id;
        event.type = type;
        if (type == POCKETLM_EVT_TOKEN) {
            const auto* token = static_cast<const pocketlm_token_event*>(payload);
            event.index = token->index;
            event.text.assign(token->bytes, token->length);
        } else if (type == POCKETLM_EVT_DONE) {
            event.stats = *static_cast<const pocketlm_stats*>(payload);
        } else if (type == POCKETLM_EVT_ERROR) {
            const auto* error = static_cast<const pocketlm_error*>(payload);
            event.error_code = error->code;
            event.error_message.assign(error->message, error->message_length);
        }

        std::lock_guard<std::mutex> lock(mutex_);
        events_.push_back(std::move(event));
        if (type == POCKETLM_EVT_DONE || type == POCKETLM_EVT_ERROR) {
            ++terminal_count_;
            cv_.notify_all();
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<CapturedEvent> events_;
    size_t terminal_count_ = 0;
};

inline void wait_for_idle(pocketlm_session* session) {
    std::unique_lock<std::mutex> lock(session->mutex);
    session->worker_cv.wait(lock, [&] {
        return session->state == SessionState::Idle;
    });
}

inline void wait_for_terminal_and_idle(pocketlm_session* session,
                                       EventCollector& collector,
                                       size_t terminal_count = 1U) {
    collector.wait_for_terminals(terminal_count);
    wait_for_idle(session);
}

inline pocketlm_params short_params(int32_t max_tokens = 4) {
    pocketlm_params params = pocketlm_default_params();
    params.max_tokens = max_tokens;
    params.temperature = 0.0F;
    params.top_k = 0;
    params.top_p = 1.0F;
    params.seed = 7;
    return params;
}

inline pocketlm_request_id generate_user(
    pocketlm_session* session,
    const char* text,
    EventCollector& collector,
    const pocketlm_params* params = nullptr) {
    const pocketlm_message message{POCKETLM_ROLE_USER, text};
    return pocketlm_generate_v2(
        session, &message, 1U, params, EventCollector::callback, &collector);
}

} // namespace pocketlm::testing
