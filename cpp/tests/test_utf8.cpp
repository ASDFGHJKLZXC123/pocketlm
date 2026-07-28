#include <catch2/catch_test_macros.hpp>

#include "tokenizer.h"

#include <cstdint>
#include <string>
#include <vector>

namespace {

std::string feed_byte(pocketlm::Utf8Flusher& flusher, uint8_t byte) {
    const char value = static_cast<char>(byte);
    return flusher.feed(&value, 1);
}

} // namespace

TEST_CASE("split CJK emoji and RTL emit only when complete", "[m1a][utf8]") {
    pocketlm::Utf8Flusher flusher;
    CHECK(feed_byte(flusher, 0xE6).empty());
    CHECK(feed_byte(flusher, 0x97).empty());
    CHECK(feed_byte(flusher, 0xA5) == "\xE6\x97\xA5");

    CHECK(feed_byte(flusher, 0xF0).empty());
    CHECK(feed_byte(flusher, 0x9F).empty());
    CHECK(feed_byte(flusher, 0x8E).empty());
    CHECK(feed_byte(flusher, 0x89) == "\xF0\x9F\x8E\x89");

    CHECK(feed_byte(flusher, 0xD8).empty());
    CHECK(feed_byte(flusher, 0xA7) == "\xD8\xA7");
}

TEST_CASE("malformed bytes become replacement and preserve following text",
          "[m1a][utf8]") {
    pocketlm::Utf8Flusher flusher;
    CHECK(feed_byte(flusher, 0xE6).empty());
    CHECK(flusher.feed("a", 1) == "\xEF\xBF\xBD" "a");

    const std::string malformed("\x80\xC0\xAFz", 4);
    const std::string sanitized = pocketlm::sanitizeUtf8(malformed);
    CHECK(sanitized == "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBDz");
    CHECK(pocketlm::isValidUtf8(sanitized));
}

TEST_CASE("overlong surrogate and out-of-range sequences are rejected",
          "[m1a][utf8]") {
    CHECK_FALSE(pocketlm::isValidUtf8(std::string("\xC0\xAF", 2)));
    CHECK_FALSE(pocketlm::isValidUtf8(std::string("\xED\xA0\x80", 3)));
    CHECK_FALSE(pocketlm::isValidUtf8(std::string("\xF4\x90\x80\x80", 4)));
    CHECK(pocketlm::isValidUtf8("ASCII \xE6\x97\xA5 \xF0\x9F\x8E\x89"));
}

TEST_CASE("incomplete terminal suffix is retained then discarded", "[m1a][utf8]") {
    std::vector<uint8_t> input{'a', 0xF0, 0x9F};
    std::vector<uint8_t> remainder;
    CHECK(pocketlm::flushUtf8Safe(input, remainder) == "a");
    REQUIRE(remainder.size() == 2U);
    CHECK(remainder[0] == 0xF0);
    CHECK(remainder[1] == 0x9F);

    pocketlm::Utf8Flusher flusher;
    CHECK(flusher.feed("\xF0\x9F", 2).empty());
    flusher.discard_incomplete();
    CHECK(flusher.feed("z", 1) == "z");
}
