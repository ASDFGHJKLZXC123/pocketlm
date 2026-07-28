#include "fake_backend.h"

#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <new>
#include <stdexcept>
#include <utility>

namespace {

// This translation unit is linked only into the test_async executable. Keep
// the replacement allocator backed by malloc/free so sanitizer interceptors
// retain matching allocation and deallocation families.
thread_local bool g_fail_allocations_on_current_thread = false;

void* test_allocate(std::size_t size) {
    if (g_fail_allocations_on_current_thread) {
        throw std::bad_alloc();
    }
    void* allocation = std::malloc(size == 0U ? 1U : size);
    if (allocation == nullptr) {
        throw std::bad_alloc();
    }
    return allocation;
}

} // namespace

void* operator new(std::size_t size) {
    return test_allocate(size);
}

void* operator new[](std::size_t size) {
    return test_allocate(size);
}

void operator delete(void* allocation) noexcept {
    std::free(allocation);
}

void operator delete[](void* allocation) noexcept {
    std::free(allocation);
}

void operator delete(void* allocation, std::size_t) noexcept {
    std::free(allocation);
}

void operator delete[](void* allocation, std::size_t) noexcept {
    std::free(allocation);
}

namespace pocketlm::testing {

bool allocation_failure_armed_on_current_thread() noexcept {
    return g_fail_allocations_on_current_thread;
}

void disarm_allocation_failure_on_current_thread() noexcept {
    g_fail_allocations_on_current_thread = false;
}

void Gate::arm() {
    std::lock_guard<std::mutex> lock(mutex_);
    armed_ = true;
    reached_ = false;
    released_ = false;
}

void Gate::arrive_and_wait() {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!armed_) {
        return;
    }
    reached_ = true;
    cv_.notify_all();
    cv_.wait(lock, [&] { return released_; });
    armed_ = false;
}

void Gate::wait_until_reached() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [&] { return reached_; });
}

void Gate::release() {
    std::lock_guard<std::mutex> lock(mutex_);
    released_ = true;
    cv_.notify_all();
}

int64_t FakeClock::now_ms() const noexcept {
    return now_.load(std::memory_order_relaxed);
}

void FakeClock::advance(int64_t milliseconds) noexcept {
    now_.fetch_add(milliseconds, std::memory_order_relaxed);
}

size_t GateHooks::index(SessionState state) {
    return static_cast<size_t>(state);
}

void GateHooks::arm(SessionState state) {
    gates_[index(state)].arm();
}

void GateHooks::wait_until_reached(SessionState state) {
    gates_[index(state)].wait_until_reached();
}

void GateHooks::release(SessionState state) {
    gates_[index(state)].release();
}

void GateHooks::fail_next_request_copy() noexcept {
    fail_request_copy_.store(true, std::memory_order_release);
}

void GateHooks::clear_request_copy_failure() noexcept {
    fail_request_copy_.store(false, std::memory_order_release);
}

bool GateHooks::request_copy_failure_pending() const noexcept {
    return fail_request_copy_.load(std::memory_order_acquire);
}

int GateHooks::request_copy_attempts() const noexcept {
    return request_copy_attempts_.load(std::memory_order_acquire);
}

void GateHooks::before_request_copy() {
    request_copy_attempts_.fetch_add(1, std::memory_order_relaxed);
    if (fail_request_copy_.exchange(false, std::memory_order_acq_rel)) {
        throw std::bad_alloc();
    }
}

void GateHooks::at_state(SessionState state, pocketlm_request_id request_id) {
    request_ids_[index(state)].store(request_id, std::memory_order_release);
    gates_[index(state)].arrive_and_wait();
}

pocketlm_request_id GateHooks::last_request_id(SessionState state) const {
    return request_ids_[index(state)].load(std::memory_order_acquire);
}

FakeControl::FakeControl() : clock(std::make_shared<FakeClock>()) {
    diagnostics.requested_accelerator = POCKETLM_ACCELERATOR_CPU;
    diagnostics.selected_accelerator = POCKETLM_ACCELERATOR_CPU;
    diagnostics.context_size = 128;
    diagnostics.batch_size = 4;
    diagnostics.model_layers = 24;
    diagnostics.offloaded_layers = 0;
    diagnostics.kqv_offloaded = 0;
    diagnostics.peak_rss_bytes = 0;
}

namespace {

class FakeBackend final : public Backend {
public:
    explicit FakeBackend(std::shared_ptr<FakeControl> control)
        : control_(std::move(control)) {
        std::lock_guard<std::mutex> lock(control_->mutex);
        ++control_->live_backends;
    }

    ~FakeBackend() override {
        std::lock_guard<std::mutex> lock(control_->mutex);
        --control_->live_backends;
    }

    pocketlm_session_diagnostics diagnostics() const noexcept override {
        std::lock_guard<std::mutex> lock(control_->mutex);
        return control_->diagnostics;
    }

    BackendResult format_and_tokenize(
        const std::vector<OwnedMessage>& messages,
        std::vector<int32_t>& tokens) override {
        control_->clock->advance(1);
        {
            std::lock_guard<std::mutex> lock(control_->mutex);
            ++control_->format_calls;
            if (control_->persistent_format_bad_alloc) {
                g_fail_allocations_on_current_thread = true;
                throw std::bad_alloc();
            }
            if (control_->throw_format_count > 0) {
                --control_->throw_format_count;
                throw std::runtime_error("scripted format exception");
            }
            if (control_->format_failures > 0) {
                --control_->format_failures;
                return BackendResult::failure(
                    POCKETLM_ERR_CHAT_TEMPLATE_FAILED,
                    "scripted template failure");
            }
            control_->last_formatted_messages = messages;
        }

        size_t token_count = 0;
        for (const OwnedMessage& message : messages) {
            token_count += message.content.size();
        }
        tokens.resize(token_count);
        for (size_t index = 0; index < token_count; ++index) {
            tokens[index] = static_cast<int32_t>(index + 1U);
        }
        {
            std::lock_guard<std::mutex> lock(control_->mutex);
            if (control_->context_size_after_format > 0) {
                control_->diagnostics.context_size =
                    control_->context_size_after_format;
                control_->context_size_after_format = -1;
            }
        }
        return BackendResult::success();
    }

    BackendResult begin_request(const pocketlm_params& params) override {
        control_->clock->advance(1);
        std::lock_guard<std::mutex> lock(control_->mutex);
        ++control_->begin_calls;
        control_->last_params = params;
        sample_index_ = 0;
        if (control_->begin_failures > 0) {
            --control_->begin_failures;
            return BackendResult::failure(
                POCKETLM_ERR_TOKENIZE_FAILED,
                "scripted begin failure");
        }
        return BackendResult::success();
    }

    BackendResult decode(const int32_t*, size_t) override {
        control_->clock->advance(1);
        int call = 0;
        int gated_call = -1;
        int throw_call = -1;
        int failure_call = -1;
        {
            std::lock_guard<std::mutex> lock(control_->mutex);
            call = control_->decode_calls++;
            gated_call = control_->gated_decode_call;
            throw_call = control_->throw_decode_call;
            failure_call = control_->decode_failure_call;
        }
        if (call == gated_call) {
            control_->decode_gate.arrive_and_wait();
        }
        if (cancellation_id_ != nullptr &&
            cancellation_id_->load(std::memory_order_acquire) == request_id_) {
            return BackendResult::cancelled();
        }
        if (call == throw_call) {
            throw std::runtime_error("scripted decode exception");
        }
        if (call == failure_call) {
            return BackendResult::failure(
                POCKETLM_ERR_DECODE_FAILED,
                "scripted decode failure");
        }
        return BackendResult::success();
    }

    SampleResult sample() override {
        control_->clock->advance(1);
        SampleResult output;
        std::lock_guard<std::mutex> lock(control_->mutex);
        ++control_->sample_calls;
        if (control_->sample_failures > 0) {
            --control_->sample_failures;
            output.result = BackendResult::failure(
                POCKETLM_ERR_DECODE_FAILED,
                "scripted sample failure");
            return output;
        }
        if (sample_index_ >= control_->pieces.size()) {
            output.result = BackendResult::success();
            output.eog = control_->emit_eog_after_pieces;
            output.token = static_cast<int32_t>(sample_index_ + 1U);
            return output;
        }
        output.result = BackendResult::success();
        output.token = static_cast<int32_t>(sample_index_ + 1U);
        output.bytes = control_->pieces[sample_index_++];
        return output;
    }

    void set_abort_probe(
        const std::atomic<pocketlm_request_id>* cancellation_id,
        pocketlm_request_id request_id) noexcept override {
        cancellation_id_ = cancellation_id;
        request_id_ = request_id;
    }

    void clear_request() noexcept override {
        cancellation_id_ = nullptr;
        request_id_ = POCKETLM_REQUEST_ID_INVALID;
        std::lock_guard<std::mutex> lock(control_->mutex);
        ++control_->clear_calls;
    }

private:
    std::shared_ptr<FakeControl> control_;
    size_t sample_index_ = 0;
    const std::atomic<pocketlm_request_id>* cancellation_id_ = nullptr;
    pocketlm_request_id request_id_ = POCKETLM_REQUEST_ID_INVALID;
};

} // namespace

pocketlm_error_code create_fake_session(
    const std::shared_ptr<FakeControl>& control,
    const std::shared_ptr<GateHooks>& hooks,
    pocketlm_session** out_session) {
    if (control == nullptr) {
        return POCKETLM_ERR_INVALID_ARGUMENT;
    }
    return create_session_with_backend(
        std::make_unique<FakeBackend>(control), control->clock, hooks, out_session);
}

} // namespace pocketlm::testing
