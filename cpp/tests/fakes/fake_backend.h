#pragma once

#include "backend.h"
#include "session.h"

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace pocketlm::testing {

class Gate {
public:
    void arm();
    void arrive_and_wait();
    void wait_until_reached();
    void release();

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool armed_ = false;
    bool reached_ = false;
    bool released_ = false;
};

class FakeClock final : public Clock {
public:
    int64_t now_ms() const noexcept override;
    void advance(int64_t milliseconds) noexcept;

private:
    std::atomic<int64_t> now_{0};
};

bool allocation_failure_armed_on_current_thread() noexcept;
void disarm_allocation_failure_on_current_thread() noexcept;

class GateHooks final : public WorkerHooks {
public:
    void arm(SessionState state);
    void wait_until_reached(SessionState state);
    void release(SessionState state);
    void fail_next_request_copy() noexcept;
    void clear_request_copy_failure() noexcept;
    bool request_copy_failure_pending() const noexcept;
    int request_copy_attempts() const noexcept;
    void before_request_copy() override;
    void at_state(SessionState state, pocketlm_request_id request_id) override;

    pocketlm_request_id last_request_id(SessionState state) const;

private:
    static size_t index(SessionState state);
    Gate gates_[7];
    std::atomic<pocketlm_request_id> request_ids_[7]{};
    std::atomic<bool> fail_request_copy_{false};
    std::atomic<int> request_copy_attempts_{0};
};

struct FakeControl {
    FakeControl();

    pocketlm_session_diagnostics diagnostics{};
    std::vector<std::string> pieces{"ok"};
    bool emit_eog_after_pieces = true;

    int format_failures = 0;
    int begin_failures = 0;
    int sample_failures = 0;
    int decode_failure_call = -1;
    int throw_format_count = 0;
    bool persistent_format_bad_alloc = false;
    int throw_decode_call = -1;
    int gated_decode_call = -1;
    int context_size_after_format = -1;

    Gate decode_gate;
    std::shared_ptr<FakeClock> clock;

    mutable std::mutex mutex;
    std::vector<OwnedMessage> last_formatted_messages;
    pocketlm_params last_params{};
    int format_calls = 0;
    int begin_calls = 0;
    int decode_calls = 0;
    int sample_calls = 0;
    int clear_calls = 0;
    int live_backends = 0;
};

pocketlm_error_code create_fake_session(
    const std::shared_ptr<FakeControl>& control,
    const std::shared_ptr<GateHooks>& hooks,
    pocketlm_session** out_session);

} // namespace pocketlm::testing
