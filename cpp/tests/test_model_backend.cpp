#include <catch2/catch_test_macros.hpp>

#include "backend.h"
#include "llama_backend.h"
#include "pocketlm_core.h"

#include "llama.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr uintmax_t kExpectedModelBytes = 491400032U;

std::string required_model_path() {
    const char* value = std::getenv("POCKETLM_TEST_MODEL");
    if (value == nullptr || value[0] == '\0') {
        SKIP("POCKETLM_TEST_MODEL is not set; model-backed qualification is opt-in");
    }
    return value;
}

std::string model_metadata_string(const llama_model* model, const char* key) {
    const int32_t required = llama_model_meta_val_str(model, key, nullptr, 0U);
    REQUIRE(required >= 0);
    std::vector<char> buffer(static_cast<size_t>(required) + 1U);
    const int32_t written = llama_model_meta_val_str(
        model, key, buffer.data(), buffer.size());
    REQUIRE(written == required);
    return std::string(buffer.data(), static_cast<size_t>(written));
}

std::string apply_chat_template(const char* chat_template,
                                const std::vector<llama_chat_message>& messages) {
    const int32_t required = llama_chat_apply_template(
        chat_template, messages.data(), messages.size(), true, nullptr, 0);
    REQUIRE(required > 0);
    std::vector<char> buffer(static_cast<size_t>(required) + 1U);
    const int32_t written = llama_chat_apply_template(
        chat_template,
        messages.data(),
        messages.size(),
        true,
        buffer.data(),
        static_cast<int32_t>(buffer.size()));
    REQUIRE(written == required);
    return std::string(buffer.data(), static_cast<size_t>(written));
}

std::vector<llama_token> tokenize(const llama_vocab* vocab,
                                  const std::string& text,
                                  bool add_special,
                                  bool parse_special) {
    int32_t required = llama_tokenize(
        vocab,
        text.data(),
        static_cast<int32_t>(text.size()),
        nullptr,
        0,
        add_special,
        parse_special);
    REQUIRE(required != std::numeric_limits<int32_t>::min());
    if (required < 0) {
        required = -required;
    }
    REQUIRE(required > 0);

    std::vector<llama_token> tokens(static_cast<size_t>(required));
    const int32_t actual = llama_tokenize(
        vocab,
        text.data(),
        static_cast<int32_t>(text.size()),
        tokens.data(),
        required,
        add_special,
        parse_special);
    REQUIRE(actual > 0);
    tokens.resize(static_cast<size_t>(actual));
    return tokens;
}

struct ModelDeleter {
    void operator()(llama_model* model) const noexcept {
        llama_model_free(model);
    }
};

struct GenerationCapture {
    std::mutex mutex;
    std::condition_variable cv;
    std::string text;
    int32_t next_index = 0;
    int token_events = 0;
    int terminal_events = 0;
    bool had_error = false;
    pocketlm_error_code error_code = POCKETLM_OK;
    pocketlm_stats stats{};

    static void callback(void* user_data,
                         pocketlm_request_id,
                         pocketlm_event_type type,
                         const void* payload) {
        auto* capture = static_cast<GenerationCapture*>(user_data);
        std::lock_guard<std::mutex> lock(capture->mutex);
        if (type == POCKETLM_EVT_TOKEN) {
            const auto* token = static_cast<const pocketlm_token_event*>(payload);
            if (token == nullptr || token->bytes == nullptr || token->length == 0U ||
                token->index != capture->next_index) {
                capture->had_error = true;
                capture->error_code = POCKETLM_ERR_INTERNAL;
                return;
            }
            capture->text.append(token->bytes, token->length);
            ++capture->next_index;
            ++capture->token_events;
            return;
        }

        ++capture->terminal_events;
        if (type == POCKETLM_EVT_DONE) {
            const auto* stats = static_cast<const pocketlm_stats*>(payload);
            if (stats == nullptr) {
                capture->had_error = true;
                capture->error_code = POCKETLM_ERR_INTERNAL;
            } else {
                capture->stats = *stats;
            }
        } else if (type == POCKETLM_EVT_ERROR) {
            const auto* error = static_cast<const pocketlm_error*>(payload);
            capture->had_error = true;
            capture->error_code = error == nullptr
                ? POCKETLM_ERR_INTERNAL
                : error->code;
        } else {
            capture->had_error = true;
            capture->error_code = POCKETLM_ERR_INTERNAL;
        }
        capture->cv.notify_all();
    }

    bool wait_for_terminal() {
        std::unique_lock<std::mutex> lock(mutex);
        return cv.wait_for(lock, std::chrono::seconds(120), [&] {
            return terminal_events > 0;
        });
    }
};

} // namespace

TEST_CASE("pinned Qwen backend qualifies chat, accelerators, and generation",
          "[m2-model][model-backed]") {
    const std::string model_path = required_model_path();
    REQUIRE(std::filesystem::is_regular_file(model_path));
    REQUIRE(std::filesystem::file_size(model_path) == kExpectedModelBytes);

    const std::vector<pocketlm::OwnedMessage> owned_messages = {
        {POCKETLM_ROLE_SYSTEM, "Answer briefly."},
        {POCKETLM_ROLE_USER, "Remember the word amber."},
        {POCKETLM_ROLE_ASSISTANT, "I will remember amber."},
        {POCKETLM_ROLE_USER, "What word should you remember?"},
    };

    pocketlm_session_config cpu_config = pocketlm_default_session_config();
    cpu_config.accelerator = POCKETLM_ACCELERATOR_CPU;

    std::vector<int32_t> backend_tokens;
    {
        std::unique_ptr<pocketlm::Backend> backend;
        const pocketlm::BackendResult create_result =
            pocketlm::create_llama_backend(model_path.c_str(), cpu_config, backend);
        REQUIRE(create_result);
        REQUIRE(backend != nullptr);
        const pocketlm::BackendResult format_result =
            backend->format_and_tokenize(owned_messages, backend_tokens);
        REQUIRE(format_result);
        REQUIRE_FALSE(backend_tokens.empty());
    }

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;
    std::unique_ptr<llama_model, ModelDeleter> model(
        llama_model_load_from_file(model_path.c_str(), model_params));
    REQUIRE(model != nullptr);
    CHECK(model_metadata_string(model.get(), "general.architecture") == "qwen2");

    const char* chat_template = llama_model_chat_template(model.get(), nullptr);
    REQUIRE(chat_template != nullptr);
    const std::string template_text(chat_template);
    REQUIRE_FALSE(template_text.empty());
    CHECK(template_text.find("<|im_start|>") != std::string::npos);
    CHECK(template_text.find("<|im_end|>") != std::string::npos);

    const std::vector<llama_chat_message> chat = {
        {"system", owned_messages[0].content.c_str()},
        {"user", owned_messages[1].content.c_str()},
        {"assistant", owned_messages[2].content.c_str()},
        {"user", owned_messages[3].content.c_str()},
    };
    const std::string formatted = apply_chat_template(chat_template, chat);
    const size_t system_position = formatted.find(owned_messages[0].content);
    const size_t first_user_position = formatted.find(owned_messages[1].content);
    const size_t assistant_position = formatted.find(owned_messages[2].content);
    const size_t newest_user_position = formatted.find(owned_messages[3].content);
    REQUIRE(system_position != std::string::npos);
    REQUIRE(first_user_position > system_position);
    REQUIRE(assistant_position > first_user_position);
    REQUIRE(newest_user_position > assistant_position);
    CHECK(formatted.find("<|im_start|>assistant", newest_user_position) !=
          std::string::npos);

    const llama_vocab* vocab = llama_model_get_vocab(model.get());
    REQUIRE(vocab != nullptr);
    const std::vector<llama_token> parsed_tokens =
        tokenize(vocab, formatted, true, true);
    const std::vector<llama_token> literal_tokens =
        tokenize(vocab, formatted, true, false);
    CHECK(parsed_tokens != literal_tokens);
    REQUIRE(parsed_tokens.size() == backend_tokens.size());
    CHECK(std::equal(parsed_tokens.begin(), parsed_tokens.end(), backend_tokens.begin()));

    const std::vector<llama_token> parsed_marker =
        tokenize(vocab, "<|im_start|>", false, true);
    const std::vector<llama_token> literal_marker =
        tokenize(vocab, "<|im_start|>", false, false);
    CHECK(parsed_marker.size() == 1U);
    CHECK(literal_marker.size() > parsed_marker.size());
    model.reset();

    pocketlm_session* cpu_session = nullptr;
    REQUIRE(pocketlm_create_v2(
                model_path.c_str(), &cpu_config, &cpu_session) == POCKETLM_OK);
    REQUIRE(cpu_session != nullptr);
    pocketlm_session_diagnostics diagnostics{};
    REQUIRE(pocketlm_get_diagnostics(cpu_session, &diagnostics) == POCKETLM_OK);
    CHECK(diagnostics.requested_accelerator == POCKETLM_ACCELERATOR_CPU);
    CHECK(diagnostics.selected_accelerator == POCKETLM_ACCELERATOR_CPU);
    CHECK(diagnostics.context_size == cpu_config.context_size);
    CHECK(diagnostics.model_layers > 0);
    CHECK(diagnostics.offloaded_layers == 0);
    CHECK(diagnostics.kqv_offloaded == 0);

    const pocketlm_message generation_messages[] = {
        {POCKETLM_ROLE_SYSTEM, "Answer briefly."},
        {POCKETLM_ROLE_USER, "Remember the word amber."},
        {POCKETLM_ROLE_ASSISTANT, "I will remember amber."},
        {POCKETLM_ROLE_USER, "Reply with the remembered word."},
    };
    pocketlm_params params = pocketlm_default_params();
    params.max_tokens = 8;
    params.temperature = 0.7F;
    params.top_k = 40;
    params.top_p = 0.9F;
    params.seed = 1234;
    GenerationCapture capture;
    REQUIRE(pocketlm_generate_v2(
                cpu_session,
                generation_messages,
                4U,
                &params,
                GenerationCapture::callback,
                &capture) == 1);
    REQUIRE(capture.wait_for_terminal());
    {
        std::lock_guard<std::mutex> lock(capture.mutex);
        CHECK_FALSE(capture.had_error);
        CHECK(capture.error_code == POCKETLM_OK);
        CHECK(capture.terminal_events == 1);
        CHECK(capture.token_events > 0);
        CHECK_FALSE(capture.text.empty());
        std::string normalized = capture.text;
        std::transform(
            normalized.begin(),
            normalized.end(),
            normalized.begin(),
            [](unsigned char value) {
                return static_cast<char>(std::tolower(value));
            });
        INFO("deterministic model output: " << capture.text);
        CHECK(normalized.find("amber") != std::string::npos);
        CHECK(capture.stats.prompt_tokens > 0);
        CHECK(capture.stats.generated_tokens > 0);
    }
    pocketlm_destroy(cpu_session);

    pocketlm_session_config auto_config = pocketlm_default_session_config();
    auto_config.accelerator = POCKETLM_ACCELERATOR_AUTO;
    pocketlm_session* auto_session = nullptr;
    REQUIRE(pocketlm_create_v2(
                model_path.c_str(), &auto_config, &auto_session) == POCKETLM_OK);
    REQUIRE(auto_session != nullptr);
    REQUIRE(pocketlm_get_diagnostics(auto_session, &diagnostics) == POCKETLM_OK);
    CHECK(diagnostics.requested_accelerator == POCKETLM_ACCELERATOR_AUTO);
    CHECK(diagnostics.selected_accelerator == POCKETLM_ACCELERATOR_CPU);
    CHECK(diagnostics.offloaded_layers == 0);
    CHECK(diagnostics.kqv_offloaded == 0);
    pocketlm_destroy(auto_session);

    pocketlm_session_config metal_config = pocketlm_default_session_config();
    metal_config.accelerator = POCKETLM_ACCELERATOR_METAL;
    pocketlm_session* metal_session = reinterpret_cast<pocketlm_session*>(0x1);
    CHECK(pocketlm_create_v2(
              model_path.c_str(), &metal_config, &metal_session) ==
          POCKETLM_ERR_METAL_UNAVAILABLE);
    CHECK(metal_session == nullptr);
}
