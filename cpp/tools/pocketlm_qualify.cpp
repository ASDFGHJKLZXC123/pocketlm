// Model-backed qualification harness. This executable deliberately uses
// only pocketlm_core.h for inference so it exercises the public ABI used by
// platform integrations rather than any internal backend implementation.

#include "pocketlm_core.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#if defined(__APPLE__)
#include <mach/mach.h>
#elif defined(__linux__)
#include <unistd.h>
#endif

namespace {

constexpr int kSchemaVersion = 1;
constexpr int kReproducibilityRuns = 5;
constexpr int kUtf8Runs = 100;
constexpr int kCancellationRuns = 20;
constexpr int kMemoryRuns = 10;
constexpr int kBenchmarkPrompts = 5;
constexpr int kBenchmarkRunsPerPrompt = 3;
constexpr int64_t kDefaultTimeoutMs = 120000;
constexpr int64_t kDefaultCancelLimitMs = 200;
constexpr int64_t kTerminalGraceMs = 2000;
constexpr int32_t kQualificationThreads = 4;

enum class OutputFormat { Json, Jsonl };
enum class Mode { All, Reproducibility, Utf8, Cancellation, Memory, Benchmark };

struct Options {
    std::string model_path;
    OutputFormat format = OutputFormat::Json;
    Mode mode = Mode::All;
    int32_t seed = 424242;
    int64_t timeout_ms = kDefaultTimeoutMs;
    int64_t cancel_limit_ms = kDefaultCancelLimitMs;
    pocketlm_accelerator accelerator = POCKETLM_ACCELERATOR_CPU;
    bool self_test_fatal_timeout = false;
    bool self_test_timeout_predicate = false;
};

struct StatsSnapshot {
    int64_t prefill_ms = 0;
    int64_t decode_ms = 0;
    int32_t prompt_tokens = 0;
    int32_t generated_tokens = 0;
    int64_t peak_rss_bytes = 0;
    pocketlm_finish_reason reason = POCKETLM_FINISH_EOS;
};

struct GenerationCapture {
    std::mutex mutex;
    std::condition_variable cv;
    pocketlm_request_id expected_request_id = POCKETLM_REQUEST_ID_INVALID;
    std::string output;
    std::string error_message;
    pocketlm_error_code error_code = POCKETLM_OK;
    StatsSnapshot stats{};
    int32_t expected_index = 0;
    int32_t token_events = 0;
    int32_t terminal_events = 0;
    bool done = false;
    bool terminal_is_error = false;
    bool protocol_valid = true;
    std::string protocol_error;
    std::chrono::steady_clock::time_point terminal_at{};

    void invalidate(const char* message) {
        protocol_valid = false;
        if (protocol_error.empty()) {
            protocol_error = message;
        }
    }

    static bool valid_utf8(const char* bytes, size_t length) {
        if (bytes == nullptr) {
            return false;
        }
        size_t index = 0;
        while (index < length) {
            const unsigned char first = static_cast<unsigned char>(bytes[index]);
            if (first <= 0x7FU) {
                ++index;
                continue;
            }
            size_t continuation_count = 0;
            uint32_t code_point = 0;
            uint32_t minimum = 0;
            if (first >= 0xC2U && first <= 0xDFU) {
                continuation_count = 1U;
                code_point = first & 0x1FU;
                minimum = 0x80U;
            } else if (first >= 0xE0U && first <= 0xEFU) {
                continuation_count = 2U;
                code_point = first & 0x0FU;
                minimum = 0x800U;
            } else if (first >= 0xF0U && first <= 0xF4U) {
                continuation_count = 3U;
                code_point = first & 0x07U;
                minimum = 0x10000U;
            } else {
                return false;
            }
            if (continuation_count > length - index - 1U) {
                return false;
            }
            for (size_t offset = 1; offset <= continuation_count; ++offset) {
                const unsigned char next = static_cast<unsigned char>(bytes[index + offset]);
                if ((next & 0xC0U) != 0x80U) {
                    return false;
                }
                code_point = (code_point << 6U) | (next & 0x3FU);
            }
            if (code_point < minimum || code_point > 0x10FFFFU ||
                (code_point >= 0xD800U && code_point <= 0xDFFFU)) {
                return false;
            }
            index += continuation_count + 1U;
        }
        return true;
    }

    static bool valid_reason(pocketlm_finish_reason reason) {
        return reason == POCKETLM_FINISH_EOS ||
            reason == POCKETLM_FINISH_MAX_TOKENS ||
            reason == POCKETLM_FINISH_CANCELLED ||
            reason == POCKETLM_FINISH_CONTEXT_EXHAUSTED;
    }

    static void callback(void* user_data,
                         pocketlm_request_id request_id,
                         pocketlm_event_type type,
                         const void* payload) {
        auto* capture = static_cast<GenerationCapture*>(user_data);
        if (capture == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lock(capture->mutex);
        // The worker may issue a callback before pocketlm_generate_v2 returns.
        // Bind that first event, then validate every later callback against it.
        if (capture->expected_request_id == POCKETLM_REQUEST_ID_INVALID) {
            capture->expected_request_id = request_id;
        } else if (request_id != capture->expected_request_id) {
            capture->invalidate("callback request ID did not match the accepted request");
        }
        if (capture->done) {
            capture->invalidate("callback arrived after a terminal event");
            return;
        }

        if (type == POCKETLM_EVT_TOKEN) {
            const auto* token = static_cast<const pocketlm_token_event*>(payload);
            if (token == nullptr || token->bytes == nullptr || token->length == 0U) {
                capture->invalidate("token payload was null or empty");
                return;
            }
            if (token->index != capture->expected_index) {
                capture->invalidate("token indexes were not contiguous from zero");
                return;
            }
            if (!valid_utf8(token->bytes, token->length)) {
                capture->invalidate("token payload was not a complete valid UTF-8 fragment");
                return;
            }
            capture->output.append(token->bytes, token->length);
            ++capture->expected_index;
            ++capture->token_events;
            capture->cv.notify_all();
            return;
        }

        ++capture->terminal_events;
        capture->done = true;
        capture->terminal_at = std::chrono::steady_clock::now();
        if (capture->terminal_events != 1) {
            capture->invalidate("request emitted more than one terminal event");
        }
        if (type == POCKETLM_EVT_DONE) {
            const auto* stats = static_cast<const pocketlm_stats*>(payload);
            if (stats == nullptr) {
                capture->invalidate("done event had no stats payload");
            } else {
                capture->stats = {stats->prefill_ms, stats->decode_ms,
                                  stats->prompt_tokens, stats->generated_tokens,
                                  stats->peak_rss_bytes, stats->reason};
                if (stats->prefill_ms < 0 || stats->decode_ms < 0 ||
                    stats->prompt_tokens < 0 || stats->generated_tokens < 0 ||
                    stats->peak_rss_bytes < 0 || !valid_reason(stats->reason)) {
                    capture->invalidate("done stats were outside the public ABI contract");
                }
            }
        } else if (type == POCKETLM_EVT_ERROR) {
            capture->terminal_is_error = true;
            const auto* error = static_cast<const pocketlm_error*>(payload);
            if (error == nullptr || error->message == nullptr || error->message_length == 0U ||
                !valid_utf8(error->message, error->message_length)) {
                capture->invalidate("error event had an invalid UTF-8 payload");
            } else {
                capture->error_code = error->code;
                capture->error_message.assign(error->message, error->message_length);
            }
        } else {
            capture->invalidate("callback event type was not token, done, or error");
        }
        capture->cv.notify_all();
    }
};

struct GenerationResult {
    pocketlm_request_id request_id = POCKETLM_REQUEST_ID_INVALID;
    bool accepted = false;
    bool completed = false;
    bool timed_out = false;
    bool protocol_valid = false;
    bool output_valid_utf8 = false;
    bool terminal_is_error = false;
    bool stream_observed = false;
    bool premature_terminal = false;
    bool cancel_requested = false;
    bool stream_wait_timed_out = false;
    std::string protocol_error;
    std::string output;
    std::string error_message;
    pocketlm_error_code error_code = POCKETLM_OK;
    int32_t token_events = 0;
    int32_t terminal_events = 0;
    StatsSnapshot stats{};
    int64_t elapsed_ms = 0;
    std::chrono::steady_clock::time_point terminal_at{};
};

bool completed_in_time(const GenerationResult& result) {
    return result.accepted && result.completed && !result.timed_out &&
        result.protocol_valid && result.output_valid_utf8;
}

struct SuiteResult {
    std::string name;
    bool passed = false;
    std::string payload_json;
};

std::string json_escape(const std::string& value) {
    std::ostringstream output;
    output << '"';
    static constexpr char kHex[] = "0123456789abcdef";
    for (const char character : value) {
        const unsigned char byte = static_cast<unsigned char>(character);
        switch (byte) {
        case '"': output << "\\\""; break;
        case '\\': output << "\\\\"; break;
        case '\b': output << "\\b"; break;
        case '\f': output << "\\f"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default:
            if (byte < 0x20U) {
                output << "\\u00" << kHex[(byte >> 4U) & 0x0FU]
                       << kHex[byte & 0x0FU];
            } else {
                output << static_cast<char>(byte);
            }
        }
    }
    output << '"';
    return output.str();
}

std::string json_bool(bool value) { return value ? "true" : "false"; }

const char* format_name(OutputFormat format) {
    return format == OutputFormat::Json ? "json" : "jsonl";
}

const char* mode_name(Mode mode) {
    switch (mode) {
    case Mode::All: return "all";
    case Mode::Reproducibility: return "reproducibility";
    case Mode::Utf8: return "utf8";
    case Mode::Cancellation: return "cancellation";
    case Mode::Memory: return "memory";
    case Mode::Benchmark: return "benchmark";
    }
    return "unknown";
}

const char* accelerator_name(pocketlm_accelerator accelerator) {
    switch (accelerator) {
    case POCKETLM_ACCELERATOR_AUTO: return "auto";
    case POCKETLM_ACCELERATOR_CPU: return "cpu";
    case POCKETLM_ACCELERATOR_METAL: return "metal";
    }
    return "unknown";
}

const char* finish_reason_name(pocketlm_finish_reason reason) {
    switch (reason) {
    case POCKETLM_FINISH_EOS: return "eos";
    case POCKETLM_FINISH_MAX_TOKENS: return "max_tokens";
    case POCKETLM_FINISH_CANCELLED: return "cancelled";
    case POCKETLM_FINISH_CONTEXT_EXHAUSTED: return "context_exhausted";
    }
    return "unknown";
}

bool parse_int32(const char* value, int32_t& output) {
    if (value == nullptr || value[0] == '\0') {
        return false;
    }
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < std::numeric_limits<int32_t>::min() ||
        parsed > std::numeric_limits<int32_t>::max()) {
        return false;
    }
    output = static_cast<int32_t>(parsed);
    return true;
}

bool parse_int64_positive(const char* value, int64_t& output) {
    if (value == nullptr || value[0] == '\0') {
        return false;
    }
    char* end = nullptr;
    const long long parsed = std::strtoll(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 0) {
        return false;
    }
    output = static_cast<int64_t>(parsed);
    return true;
}

bool parse_mode(const char* value, Mode& output) {
    if (std::strcmp(value, "all") == 0) output = Mode::All;
    else if (std::strcmp(value, "reproducibility") == 0) output = Mode::Reproducibility;
    else if (std::strcmp(value, "utf8") == 0) output = Mode::Utf8;
    else if (std::strcmp(value, "cancellation") == 0) output = Mode::Cancellation;
    else if (std::strcmp(value, "memory") == 0) output = Mode::Memory;
    else if (std::strcmp(value, "benchmark") == 0) output = Mode::Benchmark;
    else return false;
    return true;
}

bool parse_accelerator(const char* value, pocketlm_accelerator& output) {
    if (std::strcmp(value, "auto") == 0) output = POCKETLM_ACCELERATOR_AUTO;
    else if (std::strcmp(value, "cpu") == 0) output = POCKETLM_ACCELERATOR_CPU;
    else if (std::strcmp(value, "metal") == 0) output = POCKETLM_ACCELERATOR_METAL;
    else return false;
    return true;
}

void print_usage(const char* executable) {
    std::fprintf(stderr,
                 "Usage: %s --model <path> [--mode all|reproducibility|utf8|cancellation|memory|benchmark]\n"
                 "       [--format json|jsonl] [--seed N] [--timeout-ms N]\n"
                 "       [--cancel-latency-ms N] [--accelerator auto|cpu|metal]\n"
                 "       [--self-test-fatal-timeout|--self-test-timeout-predicate]\n"
                 "Writes evidence to stdout only; redirect stdout to a temporary file and rename it atomically.\n",
                 executable);
}

bool parse_options(int argc, char** argv, Options& options) {
    for (int index = 1; index < argc; ++index) {
        const char* flag = argv[index];
        if (std::strcmp(flag, "--help") == 0 || std::strcmp(flag, "-h") == 0) {
            print_usage(argv[0]);
            std::exit(0);
        }
        if (std::strcmp(flag, "--self-test-fatal-timeout") == 0) {
            options.self_test_fatal_timeout = true;
            continue;
        }
        if (std::strcmp(flag, "--self-test-timeout-predicate") == 0) {
            options.self_test_timeout_predicate = true;
            continue;
        }
        if (index + 1 >= argc) {
            std::fprintf(stderr, "Missing value for %s\n", flag);
            return false;
        }
        const char* value = argv[++index];
        if (std::strcmp(flag, "--model") == 0) {
            options.model_path = value;
        } else if (std::strcmp(flag, "--mode") == 0) {
            if (!parse_mode(value, options.mode)) {
                std::fprintf(stderr, "Unknown mode: %s\n", value);
                return false;
            }
        } else if (std::strcmp(flag, "--format") == 0) {
            if (std::strcmp(value, "json") == 0) options.format = OutputFormat::Json;
            else if (std::strcmp(value, "jsonl") == 0) options.format = OutputFormat::Jsonl;
            else {
                std::fprintf(stderr, "Unknown format: %s\n", value);
                return false;
            }
        } else if (std::strcmp(flag, "--seed") == 0) {
            if (!parse_int32(value, options.seed)) return false;
        } else if (std::strcmp(flag, "--timeout-ms") == 0) {
            if (!parse_int64_positive(value, options.timeout_ms)) return false;
        } else if (std::strcmp(flag, "--cancel-latency-ms") == 0) {
            if (!parse_int64_positive(value, options.cancel_limit_ms)) return false;
        } else if (std::strcmp(flag, "--accelerator") == 0) {
            if (!parse_accelerator(value, options.accelerator)) return false;
        } else {
            std::fprintf(stderr, "Unknown flag: %s\n", flag);
            return false;
        }
    }
    if (options.model_path.empty() && !options.self_test_fatal_timeout &&
        !options.self_test_timeout_predicate) {
        std::fprintf(stderr, "--model is required\n");
        return false;
    }
    if (options.cancel_limit_ms > std::numeric_limits<int64_t>::max() / 1000) {
        std::fprintf(stderr, "--cancel-latency-ms is too large\n");
        return false;
    }
    return true;
}

bool current_rss_bytes(int64_t& output) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info{};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
        return false;
    }
    output = static_cast<int64_t>(info.resident_size);
    return true;
#elif defined(__linux__)
    FILE* status = std::fopen("/proc/self/status", "r");
    if (status == nullptr) {
        return false;
    }
    char line[256]{};
    long kilobytes = -1;
    while (std::fgets(line, sizeof(line), status) != nullptr) {
        if (std::strncmp(line, "VmRSS:", 6U) == 0) {
            (void)std::sscanf(line + 6, " %ld", &kilobytes);
            break;
        }
    }
    std::fclose(status);
    if (kilobytes < 0 || kilobytes > std::numeric_limits<int64_t>::max() / 1024) {
        return false;
    }
    output = static_cast<int64_t>(kilobytes) * 1024;
    return true;
#else
    (void)output;
    return false;
#endif
}

std::string stats_json(const StatsSnapshot& stats) {
    std::ostringstream output;
    output << "{\"prefill_ms\":" << stats.prefill_ms
           << ",\"decode_ms\":" << stats.decode_ms
           << ",\"prompt_tokens\":" << stats.prompt_tokens
           << ",\"generated_tokens\":" << stats.generated_tokens
           << ",\"peak_rss_bytes\":" << stats.peak_rss_bytes
           << ",\"reason\":" << json_escape(finish_reason_name(stats.reason))
           << ",\"reason_code\":" << static_cast<int>(stats.reason) << '}';
    return output.str();
}

std::string generation_json(const GenerationResult& result) {
    std::ostringstream output;
    output << "{\"request_id\":" << result.request_id
           << ",\"accepted\":" << json_bool(result.accepted)
           << ",\"completed\":" << json_bool(result.completed)
           << ",\"timed_out\":" << json_bool(result.timed_out)
           << ",\"protocol_valid\":" << json_bool(result.protocol_valid)
           << ",\"output_valid_utf8\":" << json_bool(result.output_valid_utf8)
           << ",\"terminal\":" << json_escape(result.terminal_is_error ? "error" : "done")
           << ",\"stream_observed\":" << json_bool(result.stream_observed)
           << ",\"premature_terminal\":" << json_bool(result.premature_terminal)
           << ",\"cancel_requested\":" << json_bool(result.cancel_requested)
           << ",\"stream_wait_timed_out\":" << json_bool(result.stream_wait_timed_out)
           << ",\"token_events\":" << result.token_events
           << ",\"terminal_events\":" << result.terminal_events
           << ",\"elapsed_ms\":" << result.elapsed_ms
           << ",\"output\":" << json_escape(result.output)
           << ",\"error_code\":" << static_cast<int>(result.error_code)
           << ",\"error\":";
    if (result.error_message.empty()) output << "null";
    else output << json_escape(result.error_message);
    output << ",\"protocol_error\":";
    if (result.protocol_error.empty()) output << "null";
    else output << json_escape(result.protocol_error);
    output << ",\"stats\":" << stats_json(result.stats) << '}';
    return output.str();
}

pocketlm_params qualification_params(int32_t seed, int32_t max_tokens) {
    pocketlm_params params = pocketlm_default_params();
    params.temperature = 0.2F;
    params.top_k = 20;
    params.top_p = 0.8F;
    params.seed = seed;
    params.max_tokens = max_tokens;
    params.n_threads = kQualificationThreads;
    return params;
}

[[noreturn]] void fatal_terminal_timeout(pocketlm_request_id request_id,
                                         int64_t generation_timeout_ms,
                                         int64_t terminal_grace_ms) {
    std::fprintf(
        stderr,
        "{\"schema_version\":1,\"tool\":\"pocketlm_qualify\","
        "\"record_type\":\"fatal_timeout\",\"request_id\":%d,"
        "\"generation_timeout_ms\":%lld,\"terminal_grace_ms\":%lld,"
        "\"exit_code\":124,\"reason\":\"terminal_missing_after_cancel\"}\n",
        static_cast<int>(request_id),
        static_cast<long long>(generation_timeout_ms),
        static_cast<long long>(terminal_grace_ms));
    std::fflush(nullptr);
    // The callback owns a pointer to stack state. If the core violates its
    // terminal contract, unwinding would make that pointer dangling. Exit the
    // process without destructors after preserving the machine-readable fault.
    std::_Exit(124);
}

GenerationResult generate(pocketlm_session* session,
                          const std::string& prompt,
                          const pocketlm_params& params,
                          int64_t timeout_ms,
                          bool cancel_after_first_token,
                          int64_t* cancel_latency_us = nullptr) {
    GenerationCapture capture;
    const pocketlm_message message{POCKETLM_ROLE_USER, prompt.c_str()};
    const auto started = std::chrono::steady_clock::now();
    const pocketlm_request_id request_id = pocketlm_generate_v2(
        session, &message, 1U, &params, GenerationCapture::callback, &capture);

    GenerationResult result;
    result.request_id = request_id;
    result.accepted = request_id > POCKETLM_REQUEST_ID_INVALID;
    if (!result.accepted) {
        result.protocol_error = "generation was synchronously rejected";
        return result;
    }
    {
        std::lock_guard<std::mutex> lock(capture.mutex);
        if (capture.expected_request_id == POCKETLM_REQUEST_ID_INVALID) {
            capture.expected_request_id = request_id;
        } else if (capture.expected_request_id != request_id) {
            capture.invalidate("callback request ID did not match the accepted request");
        }
    }

    bool stream_observed_before_cancel = false;
    bool premature_terminal = false;
    bool stream_wait_timed_out = false;
    bool cancel_requested = false;
    std::chrono::steady_clock::time_point cancel_started{};
    if (cancel_after_first_token) {
        std::unique_lock<std::mutex> lock(capture.mutex);
        const bool stream_or_terminal = capture.cv.wait_for(
            lock, std::chrono::milliseconds(timeout_ms), [&capture] {
                return capture.token_events > 0 || capture.done;
            });
        stream_observed_before_cancel = capture.token_events > 0;
        premature_terminal = capture.done && !stream_observed_before_cancel;
        stream_wait_timed_out = !stream_or_terminal;
        lock.unlock();
        if (stream_observed_before_cancel) {
            // This is intentionally immediately adjacent to the ABI call: the
            // measurement is cancel-call-start through terminal callback.
            cancel_started = std::chrono::steady_clock::now();
            pocketlm_cancel(session, request_id);
            cancel_requested = true;
        }
    }

    bool completed = false;
    {
        std::unique_lock<std::mutex> lock(capture.mutex);
        completed = capture.cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&capture] {
            return capture.done;
        });
    }
    if (!completed) {
        pocketlm_cancel(session, request_id);
        std::unique_lock<std::mutex> lock(capture.mutex);
        // The C ABI borrows callback/user_data through terminal return. Do not
        // return with stack-owned capture still reachable from the worker. A
        // finite grace preserves the failure instead of hanging forever; if
        // the terminal is still missing, _Exit avoids unsafe stack unwinding.
        const bool terminal_after_cancel = capture.cv.wait_for(
            lock, std::chrono::milliseconds(kTerminalGraceMs), [&capture] {
            return capture.done;
        });
        if (!terminal_after_cancel) {
            lock.unlock();
            fatal_terminal_timeout(request_id, timeout_ms, kTerminalGraceMs);
        }
    }

    const auto finished = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lock(capture.mutex);
        result.completed = capture.done;
        result.timed_out = !completed;
        result.protocol_valid = capture.protocol_valid && capture.done &&
            capture.terminal_events == 1 && !capture.terminal_is_error;
        result.output_valid_utf8 = GenerationCapture::valid_utf8(
            capture.output.data(), capture.output.size());
        result.terminal_is_error = capture.terminal_is_error;
        result.stream_observed = cancel_after_first_token
            ? stream_observed_before_cancel
            : capture.token_events > 0;
        result.premature_terminal = premature_terminal;
        result.cancel_requested = cancel_requested;
        result.stream_wait_timed_out = stream_wait_timed_out;
        result.protocol_error = capture.protocol_error;
        result.output = capture.output;
        result.error_message = capture.error_message;
        result.error_code = capture.error_code;
        result.token_events = capture.token_events;
        result.terminal_events = capture.terminal_events;
        result.stats = capture.stats;
        result.terminal_at = capture.terminal_at;
        if (cancel_requested && capture.done && cancel_latency_us != nullptr) {
            const auto latency = std::chrono::duration_cast<std::chrono::microseconds>(
                capture.terminal_at - cancel_started).count();
            *cancel_latency_us = static_cast<int64_t>(latency);
        }
    }
    result.elapsed_ms = static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(finished - started).count());
    if (!result.output_valid_utf8 && result.protocol_error.empty()) {
        result.protocol_error = "joined token output was not valid UTF-8";
    }
    return result;
}

bool create_session(const Options& options, pocketlm_session** out_session,
                    pocketlm_session_diagnostics* diagnostics, std::string& error) {
    *out_session = nullptr;
    pocketlm_session_config config = pocketlm_default_session_config();
    config.accelerator = options.accelerator;
    const pocketlm_error_code create = pocketlm_create_v2(
        options.model_path.c_str(), &config, out_session);
    if (create != POCKETLM_OK || *out_session == nullptr) {
        error = pocketlm_error_code_string(create);
        return false;
    }
    if (pocketlm_get_diagnostics(*out_session, diagnostics) != POCKETLM_OK) {
        error = "pocketlm_get_diagnostics failed";
        pocketlm_destroy(*out_session);
        *out_session = nullptr;
        return false;
    }
    return true;
}

std::string diagnostics_json(const pocketlm_session_diagnostics& diagnostics) {
    std::ostringstream output;
    output << "{\"requested_accelerator\":"
           << json_escape(accelerator_name(diagnostics.requested_accelerator))
           << ",\"selected_accelerator\":"
           << json_escape(accelerator_name(diagnostics.selected_accelerator))
           << ",\"context_size\":" << diagnostics.context_size
           << ",\"batch_size\":" << diagnostics.batch_size
           << ",\"model_layers\":" << diagnostics.model_layers
           << ",\"offloaded_layers\":" << diagnostics.offloaded_layers
           << ",\"kqv_offloaded\":" << diagnostics.kqv_offloaded
           << ",\"peak_rss_bytes\":" << diagnostics.peak_rss_bytes << '}';
    return output.str();
}

SuiteResult run_reproducibility(const Options& options) {
    SuiteResult suite{"reproducibility", false, ""};
    pocketlm_session* session = nullptr;
    pocketlm_session_diagnostics diagnostics{};
    std::string error;
    std::vector<GenerationResult> runs;
    if (create_session(options, &session, &diagnostics, error)) {
        const std::string prompt =
            "Return exactly one short sentence explaining why deterministic seeds are useful.";
        const pocketlm_params params = qualification_params(options.seed, 64);
        runs.reserve(kReproducibilityRuns);
        for (int run = 0; run < kReproducibilityRuns; ++run) {
            runs.push_back(generate(session, prompt, params, options.timeout_ms, false));
        }
        pocketlm_destroy(session);
    }
    bool output_bytes_identical = !runs.empty();
    bool generated_tokens_identical = !runs.empty();
    bool finish_reason_identical = !runs.empty();
    bool valid = runs.size() == static_cast<size_t>(kReproducibilityRuns);
    const std::string baseline_output = runs.empty() ? "" : runs.front().output;
    const int32_t baseline_generated_tokens = runs.empty() ? 0 : runs.front().stats.generated_tokens;
    const pocketlm_finish_reason baseline_reason = runs.empty()
        ? POCKETLM_FINISH_EOS : runs.front().stats.reason;
    for (const GenerationResult& run : runs) {
        valid = valid && completed_in_time(run) && !run.output.empty() &&
            run.stats.generated_tokens > 0;
        output_bytes_identical = output_bytes_identical && run.output == baseline_output;
        generated_tokens_identical = generated_tokens_identical &&
            run.stats.generated_tokens == baseline_generated_tokens;
        finish_reason_identical = finish_reason_identical && run.stats.reason == baseline_reason;
    }
    suite.passed = error.empty() && valid && output_bytes_identical &&
        generated_tokens_identical && finish_reason_identical;
    std::ostringstream payload;
    payload << "{\"suite\":\"reproducibility\",\"passed\":" << json_bool(suite.passed)
            << ",\"seed\":" << options.seed
            << ",\"output_bytes_identical\":" << json_bool(output_bytes_identical)
            << ",\"generated_tokens_identical\":" << json_bool(generated_tokens_identical)
            << ",\"finish_reason_identical\":" << json_bool(finish_reason_identical)
            << ",\"diagnostics\":" << diagnostics_json(diagnostics)
            << ",\"create_error\":" << (error.empty() ? "null" : json_escape(error))
            << ",\"runs\":[";
    for (size_t index = 0; index < runs.size(); ++index) {
        if (index != 0U) payload << ',';
        const GenerationResult& run = runs[index];
        payload << "{\"run\":" << index + 1U
                << ",\"output_bytes_match_baseline\":"
                << json_bool(run.output == baseline_output)
                << ",\"generated_tokens_match_baseline\":"
                << json_bool(run.stats.generated_tokens == baseline_generated_tokens)
                << ",\"finish_reason_match_baseline\":"
                << json_bool(run.stats.reason == baseline_reason)
                << ",\"result\":" << generation_json(run) << '}';
    }
    payload << "]}";
    suite.payload_json = payload.str();
    return suite;
}

SuiteResult run_utf8(const Options& options) {
    SuiteResult suite{"utf8", false, ""};
    struct Utf8Case { std::string id; std::string category; std::string prompt; };
    static const std::vector<Utf8Case> corpus = [] {
        const std::vector<std::string> sources = {
            "🌍 你好世界 — مرحبا بالعالم",
            "🚀 今日は — שלום עולם",
            "🧠 学习与推理 — التعلم والاستدلال",
            "🌱 可持续未来 — עתיד בר־קיימא",
            "🎨 色彩と形 — اللون والشكل",
        };
        const std::vector<std::string> instructions = {
            "Repeat the line exactly, then add one English word:",
            "Summarize the meaning in one short English sentence:",
            "List the scripts and emoji you can identify in this line:",
            "Respond with a friendly acknowledgement that preserves the line:",
            "Write a five-word English caption for this line:",
        };
        std::vector<Utf8Case> cases;
        cases.reserve(25U);
        for (size_t instruction = 0; instruction < instructions.size(); ++instruction) {
            for (size_t source = 0; source < sources.size(); ++source) {
                std::ostringstream id;
                id << "utf8-" << std::setw(2) << std::setfill('0') << instruction + 1U
                   << '-' << std::setw(2) << std::setfill('0') << source + 1U;
                cases.push_back({id.str(), "emoji-cjk-rtl",
                                 instructions[instruction] + " " + sources[source]});
            }
        }
        return cases;
    }();
    pocketlm_session* session = nullptr;
    pocketlm_session_diagnostics diagnostics{};
    std::string error;
    std::vector<GenerationResult> runs;
    if (create_session(options, &session, &diagnostics, error)) {
        runs.reserve(kUtf8Runs);
        for (int run = 0; run < kUtf8Runs; ++run) {
            const size_t case_index = static_cast<size_t>(run) % corpus.size();
            runs.push_back(generate(session, corpus[case_index].prompt,
                                    qualification_params(options.seed, 16),
                                    options.timeout_ms, false));
        }
        pocketlm_destroy(session);
    }
    bool valid = runs.size() == static_cast<size_t>(kUtf8Runs);
    for (const GenerationResult& run : runs) {
        valid = valid && completed_in_time(run) && !run.output.empty() &&
            run.stats.generated_tokens > 0;
    }
    suite.passed = error.empty() && valid;
    std::ostringstream payload;
    payload << "{\"suite\":\"utf8\",\"passed\":" << json_bool(suite.passed)
            << ",\"required_runs\":" << kUtf8Runs
            << ",\"corpus_case_count\":" << corpus.size()
            << ",\"repetitions_per_case\":4"
            << ",\"diagnostics\":" << diagnostics_json(diagnostics)
            << ",\"create_error\":" << (error.empty() ? "null" : json_escape(error))
            << ",\"runs\":[";
    for (size_t index = 0; index < runs.size(); ++index) {
        if (index != 0U) payload << ',';
        const Utf8Case& corpus_case = corpus[index % corpus.size()];
        payload << "{\"trial\":" << index + 1U
                << ",\"case_id\":" << json_escape(corpus_case.id)
                << ",\"category\":" << json_escape(corpus_case.category)
                << ",\"prompt\":" << json_escape(corpus_case.prompt)
                << ",\"result\":" << generation_json(runs[index]) << '}';
    }
    payload << "]}";
    suite.payload_json = payload.str();
    return suite;
}

SuiteResult run_cancellation(const Options& options) {
    SuiteResult suite{"cancellation", false, ""};
    pocketlm_session* session = nullptr;
    pocketlm_session_diagnostics diagnostics{};
    std::string error;
    std::vector<GenerationResult> runs;
    std::vector<int64_t> latencies;
    if (create_session(options, &session, &diagnostics, error)) {
        runs.reserve(kCancellationRuns);
        latencies.reserve(kCancellationRuns);
        const std::string prompt =
            "Write a detailed numbered list of 200 distinct ways to organize a personal library. "
            "Keep generating until the list is complete.";
        for (int run = 0; run < kCancellationRuns; ++run) {
            int64_t latency_us = -1;
            runs.push_back(generate(session, prompt,
                                    qualification_params(options.seed, 256),
                                    options.timeout_ms, true, &latency_us));
            latencies.push_back(latency_us);
        }
        pocketlm_destroy(session);
    }
    bool valid = runs.size() == static_cast<size_t>(kCancellationRuns);
    const int64_t latency_limit_us = options.cancel_limit_ms * 1000;
    for (size_t index = 0; index < runs.size(); ++index) {
        const GenerationResult& run = runs[index];
        valid = valid && completed_in_time(run) && run.stream_observed &&
            run.cancel_requested &&
            !run.premature_terminal && !run.stream_wait_timed_out &&
            run.stats.reason == POCKETLM_FINISH_CANCELLED &&
            latencies[index] >= 0 && latencies[index] < latency_limit_us;
    }
    suite.passed = error.empty() && valid;
    std::ostringstream payload;
    payload << "{\"suite\":\"cancellation\",\"passed\":" << json_bool(suite.passed)
            << ",\"required_runs\":" << kCancellationRuns
            << ",\"latency_limit_ms\":" << options.cancel_limit_ms
            << ",\"diagnostics\":" << diagnostics_json(diagnostics)
            << ",\"create_error\":" << (error.empty() ? "null" : json_escape(error))
            << ",\"runs\":[";
    for (size_t index = 0; index < runs.size(); ++index) {
        if (index != 0U) payload << ',';
        const bool latency_passed = latencies[index] >= 0 && latencies[index] < latency_limit_us;
        payload << "{\"trial\":" << index + 1U
                << ",\"stream_observed_before_cancel\":"
                << json_bool(runs[index].stream_observed)
                << ",\"cancel_call_to_terminal_us\":" << latencies[index]
                << ",\"latency_passed\":" << json_bool(latency_passed)
                << ",\"result\":" << generation_json(runs[index]) << '}';
    }
    payload << "]}";
    suite.payload_json = payload.str();
    return suite;
}

SuiteResult run_memory(const Options& options) {
    SuiteResult suite{"memory", false, ""};
    std::ostringstream payload;
    bool measured_cycles_passed = true;
    bool priming_passed = false;
    int64_t current_rss = 0;
    const bool rss_supported = current_rss_bytes(current_rss);
    payload << "{\"suite\":\"memory\",\"passed\":";
    std::ostringstream cycles;
    cycles << '[';
    for (int cycle = -1; cycle < kMemoryRuns; ++cycle) {
        const bool included_in_measurement = cycle >= 0;
        pocketlm_session* session = nullptr;
        pocketlm_session_diagnostics diagnostics{};
        std::string create_error;
        int64_t rss_before_load = 0;
        int64_t rss_after_load = 0;
        int64_t rss_after_generate = 0;
        int64_t rss_after_unload = 0;
        int64_t session_peak_rss = 0;
        const bool before_known = current_rss_bytes(rss_before_load);
        GenerationResult generation;
        bool created = create_session(options, &session, &diagnostics, create_error);
        const bool loaded_known = current_rss_bytes(rss_after_load);
        bool generated_known = false;
        if (created) {
            generation = generate(session,
                                  "In two short sentences, explain what model unloading should release.",
                                  qualification_params(options.seed, 32),
                                  options.timeout_ms, false);
            generated_known = current_rss_bytes(rss_after_generate);
            session_peak_rss = pocketlm_peak_rss_bytes(session);
            pocketlm_destroy(session);
        }
        const bool unloaded_known = current_rss_bytes(rss_after_unload);
        const bool lifecycle_passed = created && completed_in_time(generation) &&
            !generation.output.empty() && generation.stats.generated_tokens > 0;
        if (included_in_measurement) {
            measured_cycles_passed = measured_cycles_passed && lifecycle_passed;
        } else {
            priming_passed = lifecycle_passed;
        }
        if (cycle != -1) cycles << ',';
        cycles << "{\"phase\":"
               << json_escape(included_in_measurement ? "measured" : "priming")
               << ",\"included_in_measurement\":" << json_bool(included_in_measurement)
               << ",\"cycle\":" << (included_in_measurement ? cycle + 1 : 0)
               << ",\"lifecycle_passed\":" << json_bool(lifecycle_passed)
               << ",\"rss_before_load_bytes\":"
               << (before_known ? std::to_string(rss_before_load) : "null")
               << ",\"rss_after_load_bytes\":"
               << (loaded_known ? std::to_string(rss_after_load) : "null")
               << ",\"rss_after_generate_bytes\":"
               << (generated_known ? std::to_string(rss_after_generate) : "null")
               << ",\"rss_after_unload_bytes\":"
               << (unloaded_known ? std::to_string(rss_after_unload) : "null")
               << ",\"session_peak_rss_bytes\":"
               << (created ? std::to_string(session_peak_rss) : "null")
               << ",\"diagnostics\":" << diagnostics_json(diagnostics)
               << ",\"create_error\":"
               << (create_error.empty() ? "null" : json_escape(create_error))
               << ",\"result\":" << generation_json(generation) << '}';
    }
    cycles << ']';
    suite.passed = priming_passed && measured_cycles_passed;
    payload << json_bool(suite.passed)
            << ",\"measured_cycles\":" << kMemoryRuns
            << ",\"priming_cycle_excluded\":true"
            << ",\"priming_cycle_passed\":" << json_bool(priming_passed)
            << ",\"measured_lifecycle_cycles_passed\":" << json_bool(measured_cycles_passed)
            << ",\"bounded_memory_claim_status\":\"observational\""
            << ",\"host_rss_role\":\"supplemental_host_process_measurement\""
            << ",\"current_rss_supported\":" << json_bool(rss_supported)
            << ",\"cycles\":" << cycles.str() << '}';
    suite.payload_json = payload.str();
    return suite;
}

SuiteResult run_benchmark(const Options& options) {
    SuiteResult suite{"benchmark", false, ""};
    struct BenchmarkPrompt { std::string id; std::string quality_dimension; std::string prompt; };
    const std::vector<BenchmarkPrompt> prompts = {
        {"bench-summary", "instruction following and factual compression",
         "In three bullet points, explain why on-device language models can improve privacy. "
         "Mention one limitation."},
        {"bench-reasoning", "basic reasoning and explanation",
         "A notebook costs $8 and a pen costs $3. Explain the total cost of two notebooks "
         "and three pens, showing the arithmetic."},
        {"bench-code", "small code generation",
         "Write a TypeScript function named clamp that constrains a number between min and max. "
         "Return only one fenced code block."},
        {"bench-rewrite", "concise rewriting",
         "Rewrite this sentence to be concise and professional: \"I just wanted to reach out "
         "and let you know that the meeting has been moved to tomorrow morning.\""},
        {"bench-multilingual", "Unicode and multilingual response",
         "Answer in one line containing all three: a friendly greeting in Chinese, Arabic, "
         "and Hebrew, followed by one smiling emoji."},
    };
    const std::vector<std::vector<int>> pass_order = {
        {0, 1, 2, 3, 4},
        {2, 3, 4, 0, 1},
        {4, 0, 1, 2, 3},
    };
    pocketlm_session* session = nullptr;
    pocketlm_session_diagnostics diagnostics{};
    std::string error;
    GenerationResult warmup;
    std::vector<GenerationResult> runs;
    std::vector<int> prompt_indexes;
    std::vector<int> pass_indexes;
    std::vector<int> order_positions;
    if (create_session(options, &session, &diagnostics, error)) {
        runs.reserve(static_cast<size_t>(kBenchmarkPrompts * kBenchmarkRunsPerPrompt));
        warmup = generate(session, prompts.front().prompt,
                          qualification_params(options.seed, 128),
                          options.timeout_ms, false);
        for (int pass = 0; pass < kBenchmarkRunsPerPrompt; ++pass) {
            for (int position = 0; position < kBenchmarkPrompts; ++position) {
                const int prompt_index = pass_order[static_cast<size_t>(pass)]
                                                   [static_cast<size_t>(position)];
                runs.push_back(generate(session, prompts[static_cast<size_t>(prompt_index)].prompt,
                                        qualification_params(options.seed, 128),
                                        options.timeout_ms, false));
                prompt_indexes.push_back(prompt_index);
                pass_indexes.push_back(pass);
                order_positions.push_back(position);
            }
        }
        pocketlm_destroy(session);
    }
    bool valid = completed_in_time(warmup) && !warmup.output.empty() &&
        warmup.stats.generated_tokens > 0 && runs.size() ==
            static_cast<size_t>(kBenchmarkPrompts * kBenchmarkRunsPerPrompt);
    for (const GenerationResult& run : runs) {
        valid = valid && completed_in_time(run) && !run.output.empty() &&
            run.stats.generated_tokens > 0;
    }
    suite.passed = error.empty() && valid;
    std::ostringstream payload;
    payload << "{\"suite\":\"benchmark\",\"passed\":" << json_bool(suite.passed)
            << ",\"prompt_count\":" << kBenchmarkPrompts
            << ",\"runs_per_prompt\":" << kBenchmarkRunsPerPrompt
            << ",\"execution_order\":\"balanced_pass_major\""
            << ",\"sampling_seed\":" << options.seed
            << ",\"warmup_included_in_metrics\":false"
            << ",\"warmup\":{\"prompt_id\":" << json_escape(prompts.front().id)
            << ",\"result\":" << generation_json(warmup) << '}'
            << ",\"diagnostics\":" << diagnostics_json(diagnostics)
            << ",\"create_error\":" << (error.empty() ? "null" : json_escape(error))
            << ",\"runs\":[";
    for (size_t index = 0; index < runs.size(); ++index) {
        if (index != 0U) payload << ',';
        const int prompt_index = prompt_indexes[index];
        const BenchmarkPrompt& prompt = prompts[static_cast<size_t>(prompt_index)];
        payload << "{\"pass_index\":" << pass_indexes[index] + 1
                << ",\"order_position\":" << order_positions[index] + 1
                << ",\"prompt_index\":" << prompt_index + 1
                << ",\"prompt_id\":" << json_escape(prompt.id)
                << ",\"quality_dimension\":" << json_escape(prompt.quality_dimension)
                << ",\"seed\":" << options.seed
                << ",\"prompt\":" << json_escape(prompt.prompt)
                << ",\"result\":" << generation_json(runs[index]) << '}';
    }
    payload << "]}";
    suite.payload_json = payload.str();
    return suite;
}

bool includes(Mode selected, Mode candidate) {
    return selected == Mode::All || selected == candidate;
}

std::string config_json(const Options& options) {
    size_t separator = options.model_path.find_last_of('/');
    const size_t backward_separator =
        options.model_path.find_last_of(static_cast<char>(92));
    if (separator == std::string::npos ||
        (backward_separator != std::string::npos && backward_separator > separator)) {
        separator = backward_separator;
    }
    const std::string model_file = separator == std::string::npos
        ? options.model_path
        : options.model_path.substr(separator + 1U);
    std::ostringstream output;
    output << "{\"model_file\":" << json_escape(model_file)
           << ",\"accelerator\":" << json_escape(accelerator_name(options.accelerator))
           << ",\"seed\":" << options.seed
           << ",\"n_threads\":" << kQualificationThreads
           << ",\"timeout_ms\":" << options.timeout_ms
           << ",\"cancel_latency_limit_ms\":" << options.cancel_limit_ms << '}';
    return output.str();
}

} // namespace

int main(int argc, char** argv) {
    Options options;
    if (!parse_options(argc, argv, options)) {
        print_usage(argv[0]);
        return 2;
    }
    if (options.self_test_fatal_timeout) {
        fatal_terminal_timeout(7, 1, 1);
    }
    if (options.self_test_timeout_predicate) {
        GenerationResult synthetic;
        synthetic.request_id = 7;
        synthetic.accepted = true;
        synthetic.completed = true;
        synthetic.timed_out = true;
        synthetic.protocol_valid = true;
        synthetic.output_valid_utf8 = true;
        synthetic.output = "otherwise-valid";
        synthetic.token_events = 1;
        synthetic.terminal_events = 1;
        synthetic.stats.generated_tokens = 1;
        synthetic.stats.reason = POCKETLM_FINISH_EOS;
        const bool predicate_accepted = completed_in_time(synthetic);
        std::cout << "{\"schema_version\":1,\"tool\":\"pocketlm_qualify\","
                  << "\"record_type\":\"timeout_predicate_self_test\","
                  << "\"synthetic_timed_out\":true,\"predicate_accepted\":"
                  << json_bool(predicate_accepted) << ",\"passed\":"
                  << json_bool(!predicate_accepted) << "}" << '\n';
        return predicate_accepted ? 1 : 0;
    }
    if (pocketlm_abi_version() != POCKETLM_ABI_VERSION) {
        std::fprintf(stderr, "pocketlm ABI version mismatch: header=%u library=%u\n",
                     POCKETLM_ABI_VERSION, pocketlm_abi_version());
        return 2;
    }

    std::vector<SuiteResult> suites;
    if (includes(options.mode, Mode::Reproducibility)) suites.push_back(run_reproducibility(options));
    if (includes(options.mode, Mode::Utf8)) suites.push_back(run_utf8(options));
    if (includes(options.mode, Mode::Cancellation)) suites.push_back(run_cancellation(options));
    if (includes(options.mode, Mode::Memory)) suites.push_back(run_memory(options));
    if (includes(options.mode, Mode::Benchmark)) suites.push_back(run_benchmark(options));

    bool passed = !suites.empty();
    for (const SuiteResult& suite : suites) passed = passed && suite.passed;

    const std::string metadata = "{\"schema_version\":" + std::to_string(kSchemaVersion) +
        ",\"tool\":\"pocketlm_qualify\",\"format\":" +
        json_escape(format_name(options.format)) + ",\"mode\":" +
        json_escape(mode_name(options.mode)) + ",\"abi_version\":" +
        std::to_string(pocketlm_abi_version()) + ",\"core_version\":" +
        json_escape(pocketlm_version()) + ",\"config\":" + config_json(options);

    if (options.format == OutputFormat::Jsonl) {
        std::cout << metadata << ",\"record_type\":\"header\"}" << '\n';
        for (const SuiteResult& suite : suites) {
            std::cout << "{\"record_type\":\"suite\",\"name\":" << json_escape(suite.name)
                      << ",\"result\":" << suite.payload_json << "}" << '\n';
        }
        std::cout << "{\"record_type\":\"summary\",\"passed\":" << json_bool(passed)
                  << ",\"suite_count\":" << suites.size() << "}" << '\n';
    } else {
        std::cout << metadata << ",\"passed\":" << json_bool(passed)
                  << ",\"suites\":[";
        for (size_t index = 0; index < suites.size(); ++index) {
            if (index != 0U) std::cout << ',';
            std::cout << suites[index].payload_json;
        }
        std::cout << "]}" << '\n';
    }
    return passed ? 0 : 1;
}
