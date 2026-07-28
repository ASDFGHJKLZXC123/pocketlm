#include <catch2/catch_test_macros.hpp>

#include "pocketlm_core.h"

#include <cmath>
#include <cstdint>
#include <cstring>

TEST_CASE("frozen defaults and version helpers are stable", "[m1a][api]") {
    const pocketlm_session_config config = pocketlm_default_session_config();
    CHECK(config.context_size == 2048);
    CHECK(config.accelerator == POCKETLM_ACCELERATOR_AUTO);
    CHECK(config.gpu_layers == 0);

    const pocketlm_params params = pocketlm_default_params();
    CHECK(params.max_tokens == 256);
    CHECK(params.temperature == 0.7F);
    CHECK(params.top_k == 40);
    CHECK(params.top_p == 0.9F);
    CHECK(params.seed == -1);
    CHECK(params.n_threads == 0);

    CHECK(pocketlm_abi_version() == POCKETLM_ABI_VERSION);
    REQUIRE(pocketlm_version() != nullptr);
    CHECK(std::strlen(pocketlm_version()) > 0U);
}

TEST_CASE("public null handling follows the v2 contract", "[m1a][api]") {
    pocketlm_session* session = reinterpret_cast<pocketlm_session*>(0x1);
    CHECK(pocketlm_create_v2(nullptr, nullptr, &session) ==
          POCKETLM_ERR_INVALID_ARGUMENT);
    CHECK(session == nullptr);
    CHECK(pocketlm_create_v2("model.gguf", nullptr, nullptr) ==
          POCKETLM_ERR_INVALID_ARGUMENT);
    CHECK(pocketlm_generate_v2(nullptr, nullptr, 0, nullptr, nullptr, nullptr) ==
          POCKETLM_GENERATE_INVALID_ARGUMENT);
    CHECK(pocketlm_get_diagnostics(nullptr, nullptr) ==
          POCKETLM_ERR_INVALID_ARGUMENT);
    CHECK(pocketlm_peak_rss_bytes(nullptr) == 0);
    REQUIRE_NOTHROW(pocketlm_cancel(nullptr, 1));
    REQUIRE_NOTHROW(pocketlm_destroy(nullptr));
}

TEST_CASE("invalid session configuration fails before model loading", "[m1a][api]") {
    pocketlm_session_config config = pocketlm_default_session_config();
    pocketlm_session* session = nullptr;

    config.context_size = 0;
    CHECK(pocketlm_create_v2("model.gguf", &config, &session) ==
          POCKETLM_ERR_INVALID_ARGUMENT);
    CHECK(session == nullptr);

    config = pocketlm_default_session_config();
    config.gpu_layers = -1;
    CHECK(pocketlm_create_v2("model.gguf", &config, &session) ==
          POCKETLM_ERR_INVALID_ARGUMENT);
    CHECK(session == nullptr);

    config = pocketlm_default_session_config();
    config.accelerator = static_cast<pocketlm_accelerator>(99);
    CHECK(pocketlm_create_v2("model.gguf", &config, &session) ==
          POCKETLM_ERR_INVALID_ARGUMENT);
    CHECK(session == nullptr);

    const char invalid_utf8_path[] = {
        'm', static_cast<char>(0xFF), '\0',
    };
    config = pocketlm_default_session_config();
    CHECK(pocketlm_create_v2(invalid_utf8_path, &config, &session) ==
          POCKETLM_ERR_INVALID_ARGUMENT);
    CHECK(session == nullptr);
}

TEST_CASE("error-code strings cover the frozen enum", "[m1a][api]") {
    for (int32_t raw = POCKETLM_OK; raw <= POCKETLM_ERR_INTERNAL; ++raw) {
        const char* name = pocketlm_error_code_string(
            static_cast<pocketlm_error_code>(raw));
        REQUIRE(name != nullptr);
        CHECK(std::strcmp(name, "UNKNOWN") != 0);
    }
    CHECK(std::strcmp(
        pocketlm_error_code_string(static_cast<pocketlm_error_code>(999)),
        "UNKNOWN") == 0);
}
