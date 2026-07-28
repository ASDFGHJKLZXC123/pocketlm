#pragma once

#include "pocketlm_core.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace pocketlm {

struct OwnedMessage {
    pocketlm_role role = POCKETLM_ROLE_USER;
    std::string content;
};

struct BackendResult {
    pocketlm_error_code code = POCKETLM_OK;
    bool aborted = false;
    std::string message;

    static BackendResult success() { return {}; }

    static BackendResult failure(pocketlm_error_code error_code,
                                 std::string error_message) {
        BackendResult result;
        result.code = error_code;
        result.message = std::move(error_message);
        return result;
    }

    static BackendResult cancelled() {
        BackendResult result;
        result.aborted = true;
        return result;
    }

    explicit operator bool() const noexcept {
        return code == POCKETLM_OK && !aborted;
    }
};

struct SampleResult {
    BackendResult result;
    int32_t token = 0;
    bool eog = false;
    std::string bytes;
};

class Backend {
public:
    virtual ~Backend() = default;

    virtual pocketlm_session_diagnostics diagnostics() const noexcept = 0;

    virtual BackendResult format_and_tokenize(
        const std::vector<OwnedMessage>& messages,
        std::vector<int32_t>& tokens) = 0;

    virtual BackendResult begin_request(const pocketlm_params& params) = 0;

    virtual BackendResult decode(const int32_t* tokens, size_t count) = 0;

    virtual SampleResult sample() = 0;

    virtual void set_abort_probe(
        const std::atomic<pocketlm_request_id>* cancellation_id,
        pocketlm_request_id request_id) noexcept = 0;

    virtual void clear_request() noexcept = 0;
};

class Clock {
public:
    virtual ~Clock() = default;
    virtual int64_t now_ms() const noexcept = 0;
};

std::shared_ptr<Clock> make_system_clock();

} // namespace pocketlm
