#include "pocketlm_core.h"

#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

namespace {

struct CallbackState {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    bool had_error = false;
};

void event_callback(void* user_data,
                    pocketlm_request_id request_id,
                    pocketlm_event_type type,
                    const void* payload) {
    auto* state = static_cast<CallbackState*>(user_data);
    if (type == POCKETLM_EVT_TOKEN) {
        const auto* token = static_cast<const pocketlm_token_event*>(payload);
        std::fwrite(token->bytes, 1U, token->length, stdout);
        std::fflush(stdout);
        return;
    }

    std::lock_guard<std::mutex> lock(state->mutex);
    if (type == POCKETLM_EVT_DONE) {
        const auto* stats = static_cast<const pocketlm_stats*>(payload);
        std::fprintf(
            stderr,
            "\n[pocketlm_smoke] request=%d reason=%d prompt=%d generated=%d "
            "prefill=%lldms decode=%lldms rss=%lldMB\n",
            request_id,
            static_cast<int>(stats->reason),
            stats->prompt_tokens,
            stats->generated_tokens,
            static_cast<long long>(stats->prefill_ms),
            static_cast<long long>(stats->decode_ms),
            static_cast<long long>(stats->peak_rss_bytes / (1024LL * 1024LL)));
    } else if (type == POCKETLM_EVT_ERROR) {
        const auto* error = static_cast<const pocketlm_error*>(payload);
        std::fprintf(
            stderr,
            "\n[pocketlm_smoke] request=%d error=%s message=%.*s\n",
            request_id,
            pocketlm_error_code_string(error->code),
            static_cast<int>(error->message_length),
            error->message);
        state->had_error = true;
    }
    state->done = true;
    state->cv.notify_all();
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(
            stderr,
            "Usage: %s <model_path> <prompt> [--seed N] [--max-tokens N]\n",
            argv[0]);
        return 1;
    }

    pocketlm_params params = pocketlm_default_params();
    params.temperature = 0.0F;
    params.top_k = 0;
    params.top_p = 1.0F;
    params.seed = 42;
    params.max_tokens = 10;
    for (int index = 3; index < argc; ++index) {
        if (std::strcmp(argv[index], "--seed") == 0 && index + 1 < argc) {
            params.seed = std::atoi(argv[++index]);
        } else if (std::strcmp(argv[index], "--max-tokens") == 0 &&
                   index + 1 < argc) {
            params.max_tokens = std::atoi(argv[++index]);
        } else {
            std::fprintf(stderr, "Unknown flag: %s\n", argv[index]);
            return 1;
        }
    }

    pocketlm_session_config config = pocketlm_default_session_config();
    config.accelerator = POCKETLM_ACCELERATOR_CPU;
    pocketlm_session* session = nullptr;
    const pocketlm_error_code create_result = pocketlm_create_v2(
        argv[1], &config, &session);
    if (create_result != POCKETLM_OK) {
        std::fprintf(
            stderr,
            "[pocketlm_smoke] create failed: %s\n",
            pocketlm_error_code_string(create_result));
        return 1;
    }

    const pocketlm_message message{POCKETLM_ROLE_USER, argv[2]};
    CallbackState state;
    const pocketlm_request_id request_id = pocketlm_generate_v2(
        session, &message, 1U, &params, event_callback, &state);
    if (request_id < 0) {
        std::fprintf(
            stderr,
            "[pocketlm_smoke] generation rejected: %d\n",
            request_id);
        pocketlm_destroy(session);
        return 1;
    }

    {
        std::unique_lock<std::mutex> lock(state.mutex);
        state.cv.wait(lock, [&] { return state.done; });
    }
    const bool had_error = state.had_error;
    pocketlm_destroy(session);
    return had_error ? 1 : 0;
}
