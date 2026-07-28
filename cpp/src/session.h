#pragma once

#include "backend.h"
#include "pocketlm_core.h"

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace pocketlm {

enum class SessionState {
    Idle,
    Queued,
    Prefilling,
    Decoding,
    Finishing,
    ShuttingDown,
    Destroyed,
};

class WorkerHooks {
public:
    virtual ~WorkerHooks() = default;
    virtual void before_request_copy() {}
    virtual void at_state(SessionState state, pocketlm_request_id request_id) = 0;
};

struct Request {
    Request();
    ~Request();

    Request(const Request&) = delete;
    Request& operator=(const Request&) = delete;

    pocketlm_request_id id = POCKETLM_REQUEST_ID_INVALID;
    std::vector<OwnedMessage> messages;
    pocketlm_params params{};
    pocketlm_event_cb callback = nullptr;
    void* user_data = nullptr;
};

class ApiCallGuard;

} // namespace pocketlm

struct pocketlm_session {
    std::unique_ptr<pocketlm::Backend> backend;
    std::shared_ptr<pocketlm::Clock> clock;
    std::shared_ptr<pocketlm::WorkerHooks> hooks;

    mutable std::mutex mutex;
    std::condition_variable worker_cv;
    std::condition_variable api_cv;
    pocketlm::SessionState state = pocketlm::SessionState::Idle;
    std::unique_ptr<pocketlm::Request> pending_request;
    bool shutdown = false;
    bool accepting_api_calls = true;
    size_t admitted_api_calls = 0;

    std::thread worker;
    int64_t next_request_id = 1;
    std::atomic<pocketlm_request_id> active_request_id{POCKETLM_REQUEST_ID_INVALID};
    std::atomic<pocketlm_request_id> cancellation_id{POCKETLM_REQUEST_ID_INVALID};
    std::atomic<int64_t> peak_rss_bytes{0};

    pocketlm_session() = default;
    ~pocketlm_session();
    pocketlm_session(const pocketlm_session&) = delete;
    pocketlm_session& operator=(const pocketlm_session&) = delete;
};

namespace pocketlm {

class ApiCallGuard {
public:
    explicit ApiCallGuard(pocketlm_session* session) : session_(session) {
        if (session_ == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(session_->mutex);
        if (!session_->accepting_api_calls) {
            return;
        }
        ++session_->admitted_api_calls;
        admitted_ = true;
    }

    ~ApiCallGuard() {
        if (!admitted_) {
            return;
        }
        std::lock_guard<std::mutex> lock(session_->mutex);
        --session_->admitted_api_calls;
        if (session_->admitted_api_calls == 0) {
            session_->api_cv.notify_all();
        }
    }

    ApiCallGuard(const ApiCallGuard&) = delete;
    ApiCallGuard& operator=(const ApiCallGuard&) = delete;

    bool admitted() const noexcept { return admitted_; }

private:
    pocketlm_session* session_ = nullptr;
    bool admitted_ = false;
};

pocketlm_error_code create_session_with_backend(
    std::unique_ptr<Backend> backend,
    std::shared_ptr<Clock> clock,
    std::shared_ptr<WorkerHooks> hooks,
    pocketlm_session** out_session);

void worker_main(pocketlm_session* session) noexcept;

namespace testing {
int live_session_count() noexcept;
int live_request_count() noexcept;
} // namespace testing

} // namespace pocketlm
