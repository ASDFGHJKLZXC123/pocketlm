#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace pocketlm {

bool isValidUtf8(const std::string& text) noexcept;

// Replaces complete malformed subsequences with U+FFFD and discards an
// incomplete suffix. The result is always valid UTF-8.
std::string sanitizeUtf8(const std::string& text);

// Emits the longest valid, sanitized prefix and retains only an incomplete
// suffix in remainder.
std::string flushUtf8Safe(const std::vector<uint8_t>& bytes,
                          std::vector<uint8_t>& remainder);

class Utf8Flusher {
public:
    std::string feed(const char* raw, int len);
    void discard_incomplete() noexcept;
    void reset() noexcept;

private:
    std::vector<uint8_t> buffer_;
};

} // namespace pocketlm
