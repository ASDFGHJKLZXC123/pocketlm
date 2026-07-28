#include <catch2/catch_test_macros.hpp>

#include "fakes/fake_backend.h"
#include "test_support.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <limits>
#include <string>
#include <thread>
#include <vector>

using pocketlm::SessionState;
using pocketlm::testing::CapturedEvent;
using pocketlm::testing::EventCollector;
using pocketlm::testing::FakeControl;
using pocketlm::testing::GateHooks;

TEST_CASE("invalid requests and exhausted IDs reject without callbacks",
          "[m1a][async]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);
    EventCollector collector;

    const pocketlm_message valid{POCKETLM_ROLE_USER, "u"};
    CHECK(pocketlm_generate_v2(
              session,
              nullptr,
              0U,
              nullptr,
              EventCollector::callback,
              &collector) == POCKETLM_GENERATE_INVALID_ARGUMENT);
    CHECK(pocketlm_generate_v2(
              session,
              &valid,
              1U,
              nullptr,
              nullptr,
              &collector) == POCKETLM_GENERATE_INVALID_ARGUMENT);

    const pocketlm_message doubled_user[] = {
        {POCKETLM_ROLE_USER, "u"},
        {POCKETLM_ROLE_USER, "u2"},
    };
    CHECK(pocketlm_generate_v2(
              session,
              doubled_user,
              2U,
              nullptr,
              EventCollector::callback,
              &collector) == POCKETLM_GENERATE_INVALID_ARGUMENT);
    const pocketlm_message system_only{POCKETLM_ROLE_SYSTEM, "s"};
    const pocketlm_message assistant_only{POCKETLM_ROLE_ASSISTANT, "a"};
    const pocketlm_message completed_turn[] = {
        {POCKETLM_ROLE_USER, "u"},
        {POCKETLM_ROLE_ASSISTANT, "a"},
    };
    const pocketlm_message null_content{POCKETLM_ROLE_USER, nullptr};
    const pocketlm_message empty{POCKETLM_ROLE_USER, ""};
    const char invalid_utf8[] = {static_cast<char>(0xFF), '\0'};
    const pocketlm_message malformed_utf8{POCKETLM_ROLE_USER, invalid_utf8};
    const std::array<pocketlm_message, 5> invalid_messages{
        system_only,
        assistant_only,
        null_content,
        empty,
        malformed_utf8,
    };
    for (const pocketlm_message& message : invalid_messages) {
        CHECK(pocketlm_generate_v2(
                  session,
                  &message,
                  1U,
                  nullptr,
                  EventCollector::callback,
                  &collector) == POCKETLM_GENERATE_INVALID_ARGUMENT);
    }
    CHECK(pocketlm_generate_v2(
              session,
              completed_turn,
              2U,
              nullptr,
              EventCollector::callback,
              &collector) == POCKETLM_GENERATE_INVALID_ARGUMENT);

    const pocketlm_params valid_params = pocketlm::testing::short_params();
    std::array<pocketlm_params, 8> invalid_params{};
    invalid_params.fill(valid_params);
    invalid_params[0].max_tokens = 0;
    invalid_params[1].temperature = -1.0F;
    invalid_params[2].temperature =
        std::numeric_limits<float>::infinity();
    invalid_params[3].top_k = -1;
    invalid_params[4].top_p = 0.0F;
    invalid_params[5].top_p = 1.1F;
    invalid_params[6].top_p = std::numeric_limits<float>::quiet_NaN();
    invalid_params[7].n_threads = -1;
    for (const pocketlm_params& params : invalid_params) {
        CHECK(pocketlm::testing::generate_user(
                  session, "u", collector, &params) ==
              POCKETLM_GENERATE_INVALID_ARGUMENT);
    }

    {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->next_request_id =
            static_cast<int64_t>(std::numeric_limits<pocketlm_request_id>::max()) + 1;
    }
    CHECK(pocketlm::testing::generate_user(
              session, "u", collector, &valid_params) ==
          POCKETLM_GENERATE_ID_EXHAUSTED);
    CHECK(collector.terminal_count() == 0U);

    pocketlm_session_diagnostics diagnostics{};
    CHECK(pocketlm_get_diagnostics(session, &diagnostics) == POCKETLM_OK);
    CHECK(diagnostics.selected_accelerator == POCKETLM_ACCELERATOR_CPU);
    CHECK(diagnostics.batch_size == control->diagnostics.batch_size);
    pocketlm_destroy(session);
}

TEST_CASE("request-copy allocation failure is synchronous and callback-free",
          "[m1a][async]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params();
    hooks->fail_next_request_copy();
    CHECK(pocketlm::testing::generate_user(
              session, "oom", collector, &params) ==
          POCKETLM_GENERATE_OOM);
    CHECK(hooks->request_copy_attempts() == 1);
    CHECK_FALSE(hooks->request_copy_failure_pending());
    CHECK(collector.terminal_count() == 0U);

    REQUIRE(pocketlm::testing::generate_user(
                session, "retry", collector, &params) == 1);
    pocketlm::testing::wait_for_terminal_and_idle(session, collector);
    pocketlm_destroy(session);
}

TEST_CASE("generate returns while queued and deep-copies the request",
          "[m1a][async]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    hooks->arm(SessionState::Queued);

    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    char mutable_text[] = "hello";
    pocketlm_message message{POCKETLM_ROLE_USER, mutable_text};
    pocketlm_params params = pocketlm::testing::short_params(2);
    EventCollector collector;
    const pocketlm_request_id request_id = pocketlm_generate_v2(
        session,
        &message,
        1U,
        &params,
        EventCollector::callback,
        &collector);
    REQUIRE(request_id == 1);

    hooks->wait_until_reached(SessionState::Queued);
    std::fill(std::begin(mutable_text), std::end(mutable_text) - 1, 'x');
    params.max_tokens = 99;

    EventCollector rejected_collector;
    CHECK(pocketlm::testing::generate_user(
              session, "second", rejected_collector, &params) ==
          POCKETLM_GENERATE_BUSY);
    CHECK(rejected_collector.terminal_count() == 0U);

    hooks->release(SessionState::Queued);
    collector.wait_for_terminals(1U);

    {
        std::lock_guard<std::mutex> lock(control->mutex);
        REQUIRE(control->last_formatted_messages.size() == 1U);
        CHECK(control->last_formatted_messages[0].content == "hello");
        CHECK(control->last_params.max_tokens == 2);
    }

    const std::vector<CapturedEvent> events = collector.events();
    REQUIRE(events.size() == 2U);
    CHECK(events[0].request_id == request_id);
    CHECK(events[0].type == POCKETLM_EVT_TOKEN);
    CHECK(events[0].index == 0);
    CHECK(events[1].request_id == request_id);
    CHECK(events[1].type == POCKETLM_EVT_DONE);
    pocketlm_destroy(session);
}

TEST_CASE("BUSY is synchronous in every non-idle worker phase",
          "[m1a][async]") {
    const std::array<SessionState, 4> states{
        SessionState::Queued,
        SessionState::Prefilling,
        SessionState::Decoding,
        SessionState::Finishing,
    };

    for (SessionState state : states) {
        DYNAMIC_SECTION("state " << static_cast<int>(state)) {
            auto control = std::make_shared<FakeControl>();
            auto hooks = std::make_shared<GateHooks>();
            hooks->arm(state);
            pocketlm_session* session = nullptr;
            REQUIRE(pocketlm::testing::create_fake_session(
                        control, hooks, &session) == POCKETLM_OK);

            EventCollector accepted;
            pocketlm_params params = pocketlm::testing::short_params();
            REQUIRE(pocketlm::testing::generate_user(
                        session, "one", accepted, &params) == 1);
            hooks->wait_until_reached(state);

            const int copy_attempts = hooks->request_copy_attempts();
            CHECK(pocketlm_generate_v2(
                      session, nullptr, 0U, nullptr, nullptr, nullptr) ==
                  POCKETLM_GENERATE_BUSY);
            CHECK(hooks->request_copy_attempts() == copy_attempts);

            EventCollector rejected;
            hooks->fail_next_request_copy();
            CHECK(pocketlm::testing::generate_user(
                      session, "two", rejected, &params) ==
                  POCKETLM_GENERATE_BUSY);
            CHECK(hooks->request_copy_attempts() == copy_attempts);
            CHECK(hooks->request_copy_failure_pending());
            CHECK(rejected.terminal_count() == 0U);
            hooks->clear_request_copy_failure();

            hooks->release(state);
            pocketlm::testing::wait_for_terminal_and_idle(
                session, accepted);
            pocketlm_destroy(session);
        }
    }
}

TEST_CASE("twenty sequential requests preserve IDs indices and terminals",
          "[m1a][async]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params();
    for (int32_t expected_id = 1; expected_id <= 20; ++expected_id) {
        const pocketlm_request_id request_id = pocketlm::testing::generate_user(
            session, "u", collector, &params);
        REQUIRE(request_id == expected_id);
        pocketlm::testing::wait_for_terminal_and_idle(
            session, collector, static_cast<size_t>(expected_id));
    }

    std::map<int32_t, int> terminals;
    std::map<int32_t, std::vector<int32_t>> indices;
    for (const CapturedEvent& event : collector.events()) {
        if (event.type == POCKETLM_EVT_TOKEN) {
            indices[event.request_id].push_back(event.index);
        } else {
            ++terminals[event.request_id];
        }
    }
    for (int32_t request_id = 1; request_id <= 20; ++request_id) {
        CHECK(terminals[request_id] == 1);
        REQUIRE(indices[request_id].size() == 1U);
        CHECK(indices[request_id][0] == 0);
    }

    pocketlm_destroy(session);
}

TEST_CASE("concurrent generate and cancel retain one accepted owner",
          "[m1a][async][concurrency]") {
    auto control = std::make_shared<FakeControl>();
    auto hooks = std::make_shared<GateHooks>();
    hooks->arm(SessionState::Queued);
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params();
    REQUIRE(pocketlm::testing::generate_user(
                session, "owner", collector, &params) == 1);
    hooks->wait_until_reached(SessionState::Queued);

    std::array<pocketlm_request_id, 8> results{};
    std::vector<std::thread> callers;
    for (size_t index = 0; index < results.size(); ++index) {
        callers.emplace_back([&, index] {
            results[index] = pocketlm::testing::generate_user(
                session, "contender", collector, &params);
        });
    }
    for (std::thread& caller : callers) {
        caller.join();
    }
    for (pocketlm_request_id result : results) {
        CHECK(result == POCKETLM_GENERATE_BUSY);
    }

    std::thread stale([&] { pocketlm_cancel(session, 99); });
    std::thread matching([&] { pocketlm_cancel(session, 1); });
    stale.join();
    matching.join();
    hooks->release(SessionState::Queued);
    collector.wait_for_terminals(1U);

    const auto events = collector.events();
    REQUIRE(events.size() == 1U);
    CHECK(events[0].type == POCKETLM_EVT_DONE);
    CHECK(events[0].stats.reason == POCKETLM_FINISH_CANCELLED);
    pocketlm_destroy(session);
}
