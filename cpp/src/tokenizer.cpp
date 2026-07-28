#include "tokenizer.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace pocketlm {
namespace {

constexpr char kReplacement[] = "\xEF\xBF\xBD";

struct ParseResult {
    std::string output;
    std::vector<uint8_t> incomplete;
    bool valid = true;
};

bool continuation(uint8_t byte) noexcept {
    return byte >= 0x80U && byte <= 0xBFU;
}

ParseResult parse_utf8(const uint8_t* bytes, size_t size, bool retain_incomplete) {
    ParseResult result;
    result.output.reserve(size);

    size_t index = 0;
    while (index < size) {
        const uint8_t lead = bytes[index];
        if (lead <= 0x7FU) {
            result.output.push_back(static_cast<char>(lead));
            ++index;
            continue;
        }

        size_t expected = 0;
        if (lead >= 0xC2U && lead <= 0xDFU) {
            expected = 2;
        } else if (lead >= 0xE0U && lead <= 0xEFU) {
            expected = 3;
        } else if (lead >= 0xF0U && lead <= 0xF4U) {
            expected = 4;
        } else {
            result.valid = false;
            result.output.append(kReplacement, 3U);
            ++index;
            continue;
        }

        if (size - index < expected) {
            bool could_be_valid = true;
            for (size_t offset = 1; offset < size - index; ++offset) {
                if (!continuation(bytes[index + offset])) {
                    could_be_valid = false;
                    break;
                }
            }
            if (could_be_valid && retain_incomplete) {
                result.incomplete.assign(bytes + index, bytes + size);
                break;
            }
            result.valid = false;
            if (!could_be_valid) {
                result.output.append(kReplacement, 3U);
                ++index;
                continue;
            }
            // A syntactically possible but incomplete terminal suffix is
            // discarded by contract.
            break;
        }

        bool sequence_valid = true;
        for (size_t offset = 1; offset < expected; ++offset) {
            if (!continuation(bytes[index + offset])) {
                sequence_valid = false;
                break;
            }
        }
        if (sequence_valid && expected == 3U) {
            const uint8_t second = bytes[index + 1U];
            if ((lead == 0xE0U && second < 0xA0U) ||
                (lead == 0xEDU && second > 0x9FU)) {
                sequence_valid = false;
            }
        }
        if (sequence_valid && expected == 4U) {
            const uint8_t second = bytes[index + 1U];
            if ((lead == 0xF0U && second < 0x90U) ||
                (lead == 0xF4U && second > 0x8FU)) {
                sequence_valid = false;
            }
        }

        if (!sequence_valid) {
            result.valid = false;
            result.output.append(kReplacement, 3U);
            ++index;
            continue;
        }

        result.output.append(
            reinterpret_cast<const char*>(bytes + index), expected);
        index += expected;
    }

    return result;
}

} // namespace

bool isValidUtf8(const std::string& text) noexcept {
    try {
        const auto* bytes = reinterpret_cast<const uint8_t*>(text.data());
        ParseResult parsed = parse_utf8(bytes, text.size(), true);
        return parsed.valid && parsed.incomplete.empty() &&
            parsed.output.size() == text.size();
    } catch (...) {
        return false;
    }
}

std::string sanitizeUtf8(const std::string& text) {
    const auto* bytes = reinterpret_cast<const uint8_t*>(text.data());
    return parse_utf8(bytes, text.size(), false).output;
}

std::string flushUtf8Safe(const std::vector<uint8_t>& bytes,
                          std::vector<uint8_t>& remainder) {
    if (bytes.empty()) {
        remainder.clear();
        return {};
    }
    ParseResult parsed = parse_utf8(bytes.data(), bytes.size(), true);
    remainder = std::move(parsed.incomplete);
    return std::move(parsed.output);
}

std::string Utf8Flusher::feed(const char* raw, int len) {
    if (raw == nullptr || len <= 0) {
        return {};
    }
    const auto* bytes = reinterpret_cast<const uint8_t*>(raw);
    buffer_.insert(buffer_.end(), bytes, bytes + len);

    std::vector<uint8_t> remainder;
    std::string output = flushUtf8Safe(buffer_, remainder);
    buffer_ = std::move(remainder);
    return output;
}

void Utf8Flusher::discard_incomplete() noexcept {
    buffer_.clear();
}

void Utf8Flusher::reset() noexcept {
    buffer_.clear();
}

} // namespace pocketlm
