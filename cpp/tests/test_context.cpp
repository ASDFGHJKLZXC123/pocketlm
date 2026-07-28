#include <catch2/catch_test_macros.hpp>

#include "fakes/fake_backend.h"
#include "test_support.h"
#include "tokenizer.h"

#include <memory>
#include <string>
#include <vector>

using pocketlm::testing::EventCollector;
using pocketlm::testing::FakeControl;
using pocketlm::testing::GateHooks;

TEST_CASE("context trimming removes oldest complete turns and preserves system",
          "[m1a][context]") {
    auto control = std::make_shared<FakeControl>();
    control->diagnostics.context_size = 12;
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    const pocketlm_message messages[] = {
        {POCKETLM_ROLE_SYSTEM, "ss"},
        {POCKETLM_ROLE_USER, "old"},
        {POCKETLM_ROLE_ASSISTANT, "answer"},
        {POCKETLM_ROLE_USER, "new"},
    };
    pocketlm_params params = pocketlm::testing::short_params(4);
    EventCollector collector;
    REQUIRE(pocketlm_generate_v2(
                session,
                messages,
                4U,
                &params,
                EventCollector::callback,
                &collector) == 1);
    collector.wait_for_terminals(1U);

    {
        std::lock_guard<std::mutex> lock(control->mutex);
        REQUIRE(control->last_formatted_messages.size() == 2U);
        CHECK(control->last_formatted_messages[0].role == POCKETLM_ROLE_SYSTEM);
        CHECK(control->last_formatted_messages[0].content == "ss");
        CHECK(control->last_formatted_messages[1].role == POCKETLM_ROLE_USER);
        CHECK(control->last_formatted_messages[1].content == "new");
        CHECK(control->format_calls == 2);
    }
    CHECK(collector.events().back().stats.prompt_tokens == 5);
    pocketlm_destroy(session);
}

TEST_CASE("oversized newest turn produces asynchronous PROMPT_TOO_LONG",
          "[m1a][context]") {
    auto control = std::make_shared<FakeControl>();
    control->diagnostics.context_size = 8;
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params(4);
    REQUIRE(pocketlm::testing::generate_user(
                session, "12345", collector, &params) == 1);
    collector.wait_for_terminals(1U);
    const auto events = collector.events();
    REQUIRE(events.size() == 1U);
    CHECK(events[0].type == POCKETLM_EVT_ERROR);
    CHECK(events[0].error_code == POCKETLM_ERR_PROMPT_TOO_LONG);
    pocketlm_destroy(session);
}

TEST_CASE("prefill uses actual backend batch size", "[m1a][context]") {
    auto control = std::make_shared<FakeControl>();
    control->diagnostics.context_size = 20;
    control->diagnostics.batch_size = 2;
    control->pieces.clear();
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params(1);
    REQUIRE(pocketlm::testing::generate_user(
                session, "12345", collector, &params) == 1);
    collector.wait_for_terminals(1U);
    {
        std::lock_guard<std::mutex> lock(control->mutex);
        CHECK(control->decode_calls == 3);
    }
    const auto terminal = collector.events().back();
    CHECK(terminal.stats.prompt_tokens == 5);
    CHECK(terminal.stats.generated_tokens == 0);
    CHECK(terminal.stats.reason == POCKETLM_FINISH_EOS);
    pocketlm_destroy(session);
}

TEST_CASE("runtime capacity exhaustion has its own DONE reason",
          "[m1a][context]") {
    auto control = std::make_shared<FakeControl>();
    control->diagnostics.context_size = 32;
    control->context_size_after_format = 5;
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params(4);
    REQUIRE(pocketlm::testing::generate_user(
                session, "12345", collector, &params) == 1);
    collector.wait_for_terminals(1U);
    const auto terminal = collector.events().back();
    REQUIRE(terminal.type == POCKETLM_EVT_DONE);
    CHECK(terminal.stats.reason == POCKETLM_FINISH_CONTEXT_EXHAUSTED);
    CHECK(terminal.stats.prompt_tokens == 5);
    CHECK(terminal.stats.generated_tokens == 0);
    pocketlm_destroy(session);
}

TEST_CASE("streamed fragments are valid contiguous and discard incomplete tail",
          "[m1a][context][utf8]") {
    auto control = std::make_shared<FakeControl>();
    control->pieces = {
        std::string("\xF0", 1),
        std::string("\x9F\x8E\x89", 3),
        std::string("\xE6", 1),
        std::string("\x97", 1),
        std::string("\xA5", 1),
        std::string("\xE6", 1),
        "a",
        std::string("\xD8\xA7\xD9\x84", 4),
        std::string("\xF0\x9F", 2),
    };
    auto hooks = std::make_shared<GateHooks>();
    pocketlm_session* session = nullptr;
    REQUIRE(pocketlm::testing::create_fake_session(control, hooks, &session) ==
            POCKETLM_OK);

    EventCollector collector;
    pocketlm_params params = pocketlm::testing::short_params(9);
    REQUIRE(pocketlm::testing::generate_user(
                session, "u", collector, &params) == 1);
    collector.wait_for_terminals(1U);

    std::vector<std::string> fragments;
    int32_t expected_index = 0;
    for (const auto& event : collector.events()) {
        if (event.type != POCKETLM_EVT_TOKEN) {
            continue;
        }
        CHECK(event.index == expected_index++);
        CHECK(pocketlm::isValidUtf8(event.text));
        fragments.push_back(event.text);
    }
    REQUIRE(fragments.size() == 4U);
    CHECK(fragments[0] == "\xF0\x9F\x8E\x89");
    CHECK(fragments[1] == "\xE6\x97\xA5");
    CHECK(fragments[2] == "\xEF\xBF\xBD" "a");
    CHECK(fragments[3] == "\xD8\xA7\xD9\x84");

    const auto terminal = collector.events().back();
    CHECK(terminal.type == POCKETLM_EVT_DONE);
    CHECK(terminal.stats.generated_tokens == 9);
    CHECK(terminal.stats.reason == POCKETLM_FINISH_MAX_TOKENS);
    pocketlm_destroy(session);
}
