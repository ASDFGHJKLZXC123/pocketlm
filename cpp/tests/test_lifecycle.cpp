#include <catch2/catch_test_macros.hpp>

#include "fakes/fake_backend.h"
#include "test_support.h"

#include <algorithm>
#include <atomic>
#include <array>
#include <chrono>
#include <condition_variable>
#include <future>
#include <memory>
#include <mutex>
#include <string>

using pocketlm::SessionState;
using pocketlm::testing::EventCollector;
using pocketlm::testing::FakeControl;
using pocketlm::testing::GateHooks;

namespace {

struct CancelOnTokenContext {
    pocketlm_session* session = nullptr;
    EventCollector collector;

    static void callback(void* user_data,
                         pocketlm_request_id request_id,
                         pocketlm_event_type type,
                         const void* payload) {
        auto* context = static_cast<CancelOnTokenContext*>(user_data);
        EventCollector::callback(
            &context->collector, request_id, type, payload);
        if (type == POCKETLM_EVT_TOKEN) {
            pocketlm_cancel(context->session, request_id);
        }
    }
};

struct GenerateOnTerminalContext {
    pocketlm_session* session = nullptr;
    pocketlm_params params{};
    EventCollector collector;
    EventCollector rejected;
    std::atomic<pocketlm_request_id> reentrant_result{
        POCKETLM_REQUEST_ID_INVALID};

    static void callback(void* user_data,
                         pocketlm_request_id request_id,
                         pocketlm_event_type type,
                         const void* payload) {
        auto* context = static_cast<GenerateOnTerminalContext*>(user_data);
        if (type == POCKETLM_EVT_DONE || type == POCKETLM_EVT_ERROR) {
            const pocketlm_message message{POCKETLM_ROLE_USER, "reentrant"};
            context->reentrant_result.store(
                pocketlm_generate_v2(
                    context->session,
                    &message,
                    1U,
                    &context->params,
                    EventCollector::callback,
                    &context->rejected),
                std::memory_order_release);
        }
        EventCollector::callback(
            &context->collector, request_id, type, payload);
    }
};

struct FixedOomTerminalCapture {
    std::atomic<bool> allocation_failure_armed_at_entry{false};
    std::mutex mutex;
    std::condition_variable cv;
    bool callback_seen = false;
    size_t callback_count = 0U;
    pocketlm_request_id request_id = POCKETLM_REQUEST_ID_INVALID;
    pocketlm_event_type type = POCKETLM_EVT_TOKEN;
    pocketlm_error_code error_code = POCKETLM_OK;
    size_t reported_message_length = 0U;
    size_t copied_message_length = 0U;
    std::array<char, 64> message{};

    static void callback(void* user_data,
                         pocketlm_request_id request_id,
                         pocketlm_event_type type,
                         const void* payload) noexcept {
        auto* capture = static_cast<FixedOomTerminalCapture*>(user_data);
        capture->allocation_failure_armed_at_entry.store(
            pocketlm::testing::allocation_failure_armed_on_current_thread(),
            std::memory_order_release);

        std::lock_guard<std::mutex> lock(capture->mutex);
        ++capture->callback_count;
        capture->request_id = request_id;
        capture->type = type;
        if (type == POCKETLM_EVT_ERROR && payload != nullptr) {
            const auto* error = static_cast<const pocketlm_error*>(payload);
            capture->error_code = error->code;
            capture->reported_message_length = error->message_length;
            capture->copied_message_length = std::min(
                error->message_length, capture->message.size());
            for (size_t index = 0U;
                 index < capture->copied_message_length;
                 ++index) {
                capture->message[index] = error->message[index];
            }
        }
        capture->callback_seen = true;
        pocketlm::testing::disarm_allocation_failure_on_current_thread();
        capture->cv.notify_all();
    }

    void wait_for_callback() {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait(lock, [&] { return callback_seen; });
    }
};

} // namespace

TEST_CASE("queued prefill and decode cancellation each produce one DONE",
          "[m1a][lifecycle][concurrency]") {
    const std::array<SessionState, 3> states{
        SessionState::Queued,
        SessionState::Prefilling,
        SessionState::Decoding,
    };

    for (SessionState state : states) {
        DYNAMIC_SECTION("cancel state " << static_cast<int>(state)) {
            auto control = std::make_shared<FakeControl>();
            auto hooks = std::make_shared<GateHooks>();
            hooks->arm(state);
            pocketlm_session* session = nullptr;
            REQUIRE(pocketlm::testing::create_fake_session(
                        control, hooks, &session) == POCKETLM_OK);

            EventCollector collector;
            pocketlm_params params = pocketlm::testing::short_params();
            const pocketlm_request_id request_id =
                pocketlm::testing::generate_user(
                    session, "cancel", collector, &params);
            REQUIRE(request_id == 1);
            hooks->wait_until_reached(state);
            pocketlm_cancel(session, request_id);
            hooks->release(state);
            pocketlm::testing::wait_for_terminal_and_idle(
                session, collector);

            const auto events = collector.events();
            REQUIRE(events.size() == 1U);
            CHECK(events[0].request_id == request_id);
            CHECK(events[0].type == POCKETLM_EVT_DONE);
            CHECK(events[0].stats.reason == POCKETLM_FINISH_CANCELLED);

            EventCollector retried;
            REQUIRE(pocketlm::testing::generate_user(
                        session, "retry", retried, &params) == 2);
            pocketlm::testing::wait_for_terminal_and_idle(
                session, retried);
            REQUIRE(retried.events().back().type == POCKETLM_EVT_DONE);
            pocketlm_destroy(session);
        }
    }
}

TEST_CASE("cancellation aborts a fake prefill decode at its deterministic gate",
          "[m1a][lifecycle][concurrency]") {
    auto control = std::make_shared<FakeControl>();
    control->gated_decode_call = 0;
    control->decode_gate.arm();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params();
    REQUIRE(pocketlm::testing::generate_user(
                session, "prefill", collector, &params) == 1);
    control->decode_gate.wait_until_reached();
    pocketlm_cancel(session, 1);
    control->decode_gate.release();
    collector.wait_for_terminals(1U);

    const auto events = collector.events();
    REQUIRE(events.size() == 1U);
    CHECK(events[0].stats.reason == POCKETLM_FINISH_CANCELLED);
    pocketlm_destroy(session);
}

TEST_CASE("cancel from the final token callback wins over the output limit",
          "[m1a][lifecycle][concurrency]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    CancelOnTokenContext context;
    context.session = session;
    pocketlm_params params = pocketlm::testing::short_params(1);
    const pocketlm_message message{POCKETLM_ROLE_USER, "one"};
    REQUIRE(pocketlm_generate_v2(
                session,
                &message,
                1U,
                &params,
                CancelOnTokenContext::callback,
                &context) == 1);
    pocketlm::testing::wait_for_terminal_and_idle(
        session, context.collector);

    const auto events = context.collector.events();
    REQUIRE(events.size() == 2U);
    CHECK(events[0].type == POCKETLM_EVT_TOKEN);
    CHECK(events[1].type == POCKETLM_EVT_DONE);
    CHECK(events[1].stats.generated_tokens == 1);
    CHECK(events[1].stats.reason == POCKETLM_FINISH_CANCELLED);
    CHECK(context.collector.terminal_count() == 1U);
    pocketlm_destroy(session);
}

TEST_CASE("terminal callback reentrant generate remains BUSY until Idle",
          "[m1a][lifecycle][concurrency]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    GenerateOnTerminalContext context;
    context.session = session;
    context.params = pocketlm::testing::short_params();
    const pocketlm_message message{POCKETLM_ROLE_USER, "first"};
    REQUIRE(pocketlm_generate_v2(
                session,
                &message,
                1U,
                &context.params,
                GenerateOnTerminalContext::callback,
                &context) == 1);
    context.collector.wait_for_terminals(1U);
    CHECK(context.reentrant_result.load(std::memory_order_acquire) ==
          POCKETLM_GENERATE_BUSY);
    CHECK(context.rejected.terminal_count() == 0U);

    pocketlm::testing::wait_for_idle(session);
    EventCollector retried;
    REQUIRE(pocketlm::testing::generate_user(
                session, "retry", retried, &context.params) == 2);
    pocketlm::testing::wait_for_terminal_and_idle(session, retried);
    pocketlm_destroy(session);
}

TEST_CASE("stale and post-completion cancellation do not affect regeneration",
          "[m1a][lifecycle]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);
    pocketlm_params params = pocketlm::testing::short_params();

    EventCollector first;
    REQUIRE(pocketlm::testing::generate_user(
                session, "first", first, &params) == 1);
    pocketlm::testing::wait_for_terminal_and_idle(session, first);
    pocketlm_cancel(session, 1);

    hooks->arm(SessionState::Decoding);
    EventCollector second;
    REQUIRE(pocketlm::testing::generate_user(
                session, "second", second, &params) == 2);
    hooks->wait_until_reached(SessionState::Decoding);
    pocketlm_cancel(session, 1);
    pocketlm_cancel(session, 999);
    hooks->release(SessionState::Decoding);
    second.wait_for_terminals(1U);

    const auto events = second.events();
    REQUIRE(events.back().type == POCKETLM_EVT_DONE);
    CHECK(events.back().stats.reason == POCKETLM_FINISH_EOS);
    pocketlm_destroy(session);
}

TEST_CASE("numeric IDs are interpreted in the supplied session",
          "[m1a][lifecycle]") {
    auto control_one = std::make_shared<FakeControl>();
    auto control_two = std::make_shared<FakeControl>();
    auto hooks_one = std::make_shared<GateHooks>();
    auto hooks_two = std::make_shared<GateHooks>();
    hooks_one->arm(SessionState::Queued);
    hooks_two->arm(SessionState::Queued);
    pocketlm_session* session_one = nullptr;
    pocketlm_session* session_two = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(
                control_one, hooks_one, &session_one) == POCKETLM_OK);
    REQUIRE(pocketlm::testing::create_fake_session(
                control_two, hooks_two, &session_two) == POCKETLM_OK);

    EventCollector first;
    EventCollector second;
    pocketlm_params params = pocketlm::testing::short_params();
    const pocketlm_request_id first_id = pocketlm::testing::generate_user(
        session_one, "one", first, &params);
    const pocketlm_request_id second_id = pocketlm::testing::generate_user(
        session_two, "two", second, &params);
    REQUIRE(first_id == 1);
    REQUIRE(second_id == 1);
    hooks_one->wait_until_reached(SessionState::Queued);
    hooks_two->wait_until_reached(SessionState::Queued);

    pocketlm_cancel(session_two, first_id);
    hooks_one->release(SessionState::Queued);
    hooks_two->release(SessionState::Queued);
    first.wait_for_terminals(1U);
    second.wait_for_terminals(1U);

    CHECK(first.events().back().stats.reason == POCKETLM_FINISH_EOS);
    CHECK(second.events().back().stats.reason == POCKETLM_FINISH_CANCELLED);
    pocketlm_destroy(session_one);
    pocketlm_destroy(session_two);
}

TEST_CASE("destroy during generation joins after terminal and releases allocations",
          "[m1a][lifecycle][concurrency]") {
    const int session_baseline = pocketlm::testing::live_session_count();
    const int request_baseline = pocketlm::testing::live_request_count();

    auto control = std::make_shared<FakeControl>();
    control->gated_decode_call = 0;
    control->decode_gate.arm();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params();
    REQUIRE(pocketlm::testing::generate_user(
                session, "destroy", collector, &params) == 1);
    control->decode_gate.wait_until_reached();

    std::future<void> destroyed = std::async(
        std::launch::async, [session] { pocketlm_destroy(session); });
    {
        std::unique_lock<std::mutex> lock(session->mutex);
        session->worker_cv.wait(lock, [&] { return session->shutdown; });
    }
    control->decode_gate.release();
    destroyed.get();

    const auto events = collector.events();
    REQUIRE(events.size() == 1U);
    CHECK(events[0].type == POCKETLM_EVT_DONE);
    CHECK(events[0].stats.reason == POCKETLM_FINISH_CANCELLED);
    CHECK(collector.terminal_count() == 1U);
    CHECK(pocketlm::testing::live_session_count() == session_baseline);
    CHECK(pocketlm::testing::live_request_count() == request_baseline);
    {
        std::lock_guard<std::mutex> lock(control->mutex);
        CHECK(control->live_backends == 0);
    }
}

TEST_CASE("destroy at every worker stage terminates before releasing the session",
          "[m1a][lifecycle][concurrency]") {
    const std::array<SessionState, 4> states{
        SessionState::Queued,
        SessionState::Prefilling,
        SessionState::Decoding,
        SessionState::Finishing,
    };

    for (SessionState state : states) {
        DYNAMIC_SECTION("destroy state " << static_cast<int>(state)) {
            const int session_baseline = pocketlm::testing::live_session_count();
            const int request_baseline = pocketlm::testing::live_request_count();
            auto control = std::make_shared<FakeControl>();
            auto hooks = std::make_shared<GateHooks>();
            hooks->arm(state);
            pocketlm_session* session = nullptr;
            REQUIRE(pocketlm::testing::create_fake_session(
                        control, hooks, &session) == POCKETLM_OK);

            EventCollector collector;
            EventCollector rejected;
            pocketlm_params params = pocketlm::testing::short_params();
            REQUIRE(pocketlm::testing::generate_user(
                        session, "destroy", collector, &params) == 1);
            hooks->wait_until_reached(state);

            std::future<void> destroyed = std::async(
                std::launch::async, [session] { pocketlm_destroy(session); });
            {
                std::unique_lock<std::mutex> lock(session->mutex);
                session->worker_cv.wait(lock, [&] { return session->shutdown; });
            }
            CHECK(pocketlm::testing::generate_user(
                      session, "rejected", rejected, &params) ==
                  POCKETLM_GENERATE_SHUTTING_DOWN);
            CHECK(rejected.terminal_count() == 0U);

            hooks->release(state);
            destroyed.get();

            const auto events = collector.events();
            REQUIRE_FALSE(events.empty());
            CHECK(collector.terminal_count() == 1U);
            CHECK((events.back().type == POCKETLM_EVT_DONE ||
                   events.back().type == POCKETLM_EVT_ERROR));
            CHECK(pocketlm::testing::live_session_count() == session_baseline);
            CHECK(pocketlm::testing::live_request_count() == request_baseline);
            {
                std::lock_guard<std::mutex> lock(control->mutex);
                CHECK(control->live_backends == 0);
            }
        }
    }
}

TEST_CASE("destroy waits for API calls admitted before shutdown",
          "[m1a][lifecycle][concurrency]") {
    const int session_baseline = pocketlm::testing::live_session_count();
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    auto admitted = std::make_unique<pocketlm::ApiCallGuard>(session);
    REQUIRE(admitted->admitted());
    std::future<void> destroyed = std::async(
        std::launch::async, [session] { pocketlm_destroy(session); });
    {
        std::unique_lock<std::mutex> lock(session->mutex);
        session->api_cv.wait(lock, [&] { return !session->accepting_api_calls; });
    }
    CHECK(destroyed.wait_for(std::chrono::milliseconds(0)) ==
          std::future_status::timeout);

    admitted.reset();
    destroyed.get();
    CHECK(pocketlm::testing::live_session_count() == session_baseline);
}

TEST_CASE("errors and backend exceptions return to Idle for retry",
          "[m1a][lifecycle]") {
    enum class Failure { Template, Begin, Decode, Exception };
    const std::array<Failure, 4> failures{
        Failure::Template,
        Failure::Begin,
        Failure::Decode,
        Failure::Exception,
    };

    for (Failure failure : failures) {
        DYNAMIC_SECTION("failure " << static_cast<int>(failure)) {
            auto control = std::make_shared<FakeControl>();
            if (failure == Failure::Template) {
                control->format_failures = 1;
            } else if (failure == Failure::Begin) {
                control->begin_failures = 1;
            } else if (failure == Failure::Decode) {
                control->decode_failure_call = 0;
            } else {
                control->throw_format_count = 1;
            }
            auto hooks = std::make_shared<GateHooks>();
            pocketlm_session* session = nullptr;
            REQUIRE(pocketlm::testing::create_fake_session(
                        control, hooks, &session) == POCKETLM_OK);

            pocketlm_params params = pocketlm::testing::short_params();
            EventCollector failed;
            REQUIRE(pocketlm::testing::generate_user(
                        session, "fail", failed, &params) == 1);
            pocketlm::testing::wait_for_terminal_and_idle(
                session, failed);
            REQUIRE(failed.events().size() == 1U);
            CHECK(failed.events()[0].type == POCKETLM_EVT_ERROR);

            EventCollector retried;
            REQUIRE(pocketlm::testing::generate_user(
                        session, "retry", retried, &params) == 2);
            pocketlm::testing::wait_for_terminal_and_idle(
                session, retried);
            CHECK(retried.events().back().type == POCKETLM_EVT_DONE);
            pocketlm_destroy(session);
        }
    }
}

TEST_CASE("worker allocation failure remains armed through OOM callback and recovers",
          "[m1a][lifecycle]") {
    auto control = std::make_shared<FakeControl>();
    control->persistent_format_bad_alloc = true;
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    pocketlm_params params = pocketlm::testing::short_params();
    FixedOomTerminalCapture failed;
    const pocketlm_message message{POCKETLM_ROLE_USER, "oom"};
    REQUIRE(pocketlm_generate_v2(
                session,
                &message,
                1U,
                &params,
                FixedOomTerminalCapture::callback,
                &failed) == 1);
    failed.wait_for_callback();
    pocketlm::testing::wait_for_idle(session);

    CHECK(failed.allocation_failure_armed_at_entry.load(
        std::memory_order_acquire));
    CHECK(failed.callback_count == 1U);
    CHECK(failed.request_id == 1);
    CHECK(failed.type == POCKETLM_EVT_ERROR);
    CHECK(failed.error_code == POCKETLM_ERR_OOM);
    CHECK(failed.reported_message_length == failed.copied_message_length);
    CHECK(std::string(
              failed.message.data(), failed.copied_message_length) ==
          "out of memory during generation");

    {
        std::lock_guard<std::mutex> lock(control->mutex);
        control->persistent_format_bad_alloc = false;
    }
    EventCollector retried;
    REQUIRE(pocketlm::testing::generate_user(
                session, "retry", retried, &params) == 2);
    pocketlm::testing::wait_for_terminal_and_idle(session, retried);
    CHECK(retried.events().back().type == POCKETLM_EVT_DONE);
    pocketlm_destroy(session);
}
