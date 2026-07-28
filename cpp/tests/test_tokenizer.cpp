#include <catch2/catch_test_macros.hpp>

#include "tokenizer.h"

#include <string>

TEST_CASE("complete multilingual corpus remains unchanged", "[m1a][utf8]") {
    const std::string corpus =
        "ASCII | \xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E | "
        "\xF0\x9F\x8E\x89\xF0\x9F\xA4\x96 | "
        "\xD8\xA7\xD9\x84\xD8\xB3\xD9\x84\xD8\xA7\xD9\x85";
    REQUIRE(pocketlm::isValidUtf8(corpus));
    CHECK(pocketlm::sanitizeUtf8(corpus) == corpus);
}

TEST_CASE("empty UTF-8 is valid for utility callers", "[m1a][utf8]") {
    CHECK(pocketlm::isValidUtf8(""));
    CHECK(pocketlm::sanitizeUtf8("").empty());
}
