#include "llama_backend.h"

#include "llama.h"

#include <algorithm>
#include <array>
#include <climits>
#include <cstdint>
#include <limits>
#include <mutex>
#include <new>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace pocketlm {
namespace {

std::once_flag g_backend_once;

void ensure_backend_initialized() {
    std::call_once(g_backend_once, [] { llama_backend_init(); });
}

const char* role_name(pocketlm_role role) {
    switch (role) {
    case POCKETLM_ROLE_SYSTEM:
        return "system";
    case POCKETLM_ROLE_USER:
        return "user";
    case POCKETLM_ROLE_ASSISTANT:
        return "assistant";
    }
    return "user";
}

class LlamaBackend final : public Backend {
public:
    ~LlamaBackend() override {
        clear_request();
        if (context_ != nullptr) {
            llama_free(context_);
        }
        if (model_ != nullptr) {
            llama_model_free(model_);
        }
    }

    static BackendResult create(const char* model_path,
                                const pocketlm_session_config& config,
                                std::unique_ptr<Backend>& out_backend) {
        ensure_backend_initialized();

#if defined(POCKETLM_SIMULATOR_CPU_ONLY)
        // Simulator Metal availability is not physical-device offload proof.
        // The tested Simulator target is CPU-only; physical iOS builds do not
        // define this policy macro and retain AUTO/Metal selection.
        const bool gpu_supported = false;
#else
        const bool gpu_supported = llama_supports_gpu_offload();
#endif
        pocketlm_accelerator selected = POCKETLM_ACCELERATOR_CPU;
        if (config.accelerator == POCKETLM_ACCELERATOR_METAL) {
            if (!gpu_supported) {
                return BackendResult::failure(
                    POCKETLM_ERR_METAL_UNAVAILABLE,
                    "Metal offload is unavailable in this build");
            }
            selected = POCKETLM_ACCELERATOR_METAL;
        } else if (config.accelerator == POCKETLM_ACCELERATOR_AUTO && gpu_supported) {
            selected = POCKETLM_ACCELERATOR_METAL;
        }

        auto backend = std::unique_ptr<LlamaBackend>(new LlamaBackend());
        BackendResult result = backend->load(model_path, config, selected);
        if (!result && config.accelerator == POCKETLM_ACCELERATOR_AUTO &&
            selected == POCKETLM_ACCELERATOR_METAL) {
            backend.reset(new LlamaBackend());
            result = backend->load(model_path, config, POCKETLM_ACCELERATOR_CPU);
        }
        if (!result) {
            return result;
        }

        out_backend = std::move(backend);
        return BackendResult::success();
    }

    pocketlm_session_diagnostics diagnostics() const noexcept override {
        return diagnostics_;
    }

    BackendResult format_and_tokenize(
        const std::vector<OwnedMessage>& messages,
        std::vector<int32_t>& tokens) override {
        const char* chat_template = llama_model_chat_template(model_, nullptr);
        if (chat_template == nullptr || *chat_template == '\0') {
            return BackendResult::failure(
                POCKETLM_ERR_CHAT_TEMPLATE_FAILED,
                "the model does not provide a supported chat template");
        }

        std::vector<llama_chat_message> chat;
        chat.reserve(messages.size());
        for (const OwnedMessage& message : messages) {
            chat.push_back({role_name(message.role), message.content.c_str()});
        }

        int32_t formatted_length = llama_chat_apply_template(
            chat_template, chat.data(), chat.size(), true, nullptr, 0);
        if (formatted_length < 0) {
            return BackendResult::failure(
                POCKETLM_ERR_CHAT_TEMPLATE_FAILED,
                "llama_chat_apply_template failed to size the prompt");
        }

        std::vector<char> formatted(static_cast<size_t>(formatted_length) + 1U);
        const int32_t written = llama_chat_apply_template(
            chat_template,
            chat.data(),
            chat.size(),
            true,
            formatted.data(),
            static_cast<int32_t>(formatted.size()));
        if (written < 0 || written > formatted_length) {
            return BackendResult::failure(
                POCKETLM_ERR_CHAT_TEMPLATE_FAILED,
                "llama_chat_apply_template failed to format the prompt");
        }

        const llama_vocab* vocab = llama_model_get_vocab(model_);
        int32_t required = llama_tokenize(
            vocab, formatted.data(), written, nullptr, 0, true, true);
        if (required == INT32_MIN) {
            return BackendResult::failure(
                POCKETLM_ERR_TOKENIZE_FAILED,
                "tokenized prompt exceeds the supported token-count range");
        }
        if (required < 0) {
            required = -required;
        }
        if (required <= 0) {
            return BackendResult::failure(
                POCKETLM_ERR_TOKENIZE_FAILED,
                "llama_tokenize produced no prompt tokens");
        }

        std::vector<llama_token> llama_tokens(static_cast<size_t>(required));
        const int32_t actual = llama_tokenize(
            vocab,
            formatted.data(),
            written,
            llama_tokens.data(),
            required,
            true,
            true);
        if (actual <= 0) {
            return BackendResult::failure(
                POCKETLM_ERR_TOKENIZE_FAILED,
                "llama_tokenize failed to encode the prompt");
        }

        tokens.assign(llama_tokens.begin(), llama_tokens.begin() + actual);
        return BackendResult::success();
    }

    BackendResult begin_request(const pocketlm_params& params) override {
        clear_request();

        const unsigned int hardware_threads = std::thread::hardware_concurrency();
        const int32_t thread_count = params.n_threads > 0
            ? params.n_threads
            : static_cast<int32_t>(std::max(1U, hardware_threads));
        llama_set_n_threads(context_, thread_count, thread_count);

        llama_sampler_chain_params chain_params = llama_sampler_chain_default_params();
        chain_params.no_perf = true;
        sampler_ = llama_sampler_chain_init(chain_params);
        if (sampler_ == nullptr) {
            return BackendResult::failure(
                POCKETLM_ERR_OOM,
                "failed to allocate the sampler chain");
        }

        if (params.temperature == 0.0F) {
            if (!add_sampler(llama_sampler_init_greedy())) {
                return sampler_allocation_failure();
            }
        } else {
            if (params.top_k > 0 && !add_sampler(llama_sampler_init_top_k(params.top_k))) {
                return sampler_allocation_failure();
            }
            if (params.top_p < 1.0F &&
                !add_sampler(llama_sampler_init_top_p(params.top_p, 1))) {
                return sampler_allocation_failure();
            }
            if (!add_sampler(llama_sampler_init_temp(params.temperature))) {
                return sampler_allocation_failure();
            }
            const uint32_t seed = params.seed < 0
                ? LLAMA_DEFAULT_SEED
                : static_cast<uint32_t>(params.seed);
            if (!add_sampler(llama_sampler_init_dist(seed))) {
                return sampler_allocation_failure();
            }
        }

        const llama_memory_t memory = llama_get_memory(context_);
        if (memory != nullptr) {
            llama_memory_clear(memory, true);
        }
        return BackendResult::success();
    }

    BackendResult decode(const int32_t* tokens, size_t count) override {
        if (tokens == nullptr || count == 0 ||
            count > static_cast<size_t>(std::numeric_limits<int32_t>::max())) {
            return BackendResult::failure(
                POCKETLM_ERR_DECODE_FAILED,
                "invalid token batch passed to llama_decode");
        }

        std::vector<llama_token> mutable_tokens(tokens, tokens + count);
        llama_batch batch = llama_batch_get_one(
            mutable_tokens.data(), static_cast<int32_t>(mutable_tokens.size()));
        const int32_t decode_result = llama_decode(context_, batch);
        if (decode_result == 0) {
            return BackendResult::success();
        }
        if (decode_result == 2 && cancellation_id_ != nullptr &&
            cancellation_id_->load(std::memory_order_acquire) == request_id_) {
            return BackendResult::cancelled();
        }
        return BackendResult::failure(
            POCKETLM_ERR_DECODE_FAILED,
            "llama_decode failed with code " + std::to_string(decode_result));
    }

    SampleResult sample() override {
        SampleResult output;
        if (sampler_ == nullptr) {
            output.result = BackendResult::failure(
                POCKETLM_ERR_INTERNAL,
                "sample called without an active sampler");
            return output;
        }

        output.token = llama_sampler_sample(sampler_, context_, -1);
        const llama_vocab* vocab = llama_model_get_vocab(model_);
        output.eog = llama_vocab_is_eog(vocab, output.token);
        if (output.eog) {
            output.result = BackendResult::success();
            return output;
        }

        std::array<char, 256> local{};
        int32_t length = llama_token_to_piece(
            vocab,
            output.token,
            local.data(),
            static_cast<int32_t>(local.size()),
            0,
            false);
        if (length >= 0) {
            output.bytes.assign(local.data(), static_cast<size_t>(length));
            output.result = BackendResult::success();
            return output;
        }

        const int32_t required = -length;
        if (required <= 0) {
            output.result = BackendResult::failure(
                POCKETLM_ERR_DECODE_FAILED,
                "llama_token_to_piece returned an invalid size");
            return output;
        }
        std::vector<char> dynamic_buffer(static_cast<size_t>(required));
        length = llama_token_to_piece(
            vocab,
            output.token,
            dynamic_buffer.data(),
            required,
            0,
            false);
        if (length < 0) {
            output.result = BackendResult::failure(
                POCKETLM_ERR_DECODE_FAILED,
                "llama_token_to_piece failed to decode a sampled token");
            return output;
        }
        output.bytes.assign(dynamic_buffer.data(), static_cast<size_t>(length));
        output.result = BackendResult::success();
        return output;
    }

    void set_abort_probe(
        const std::atomic<pocketlm_request_id>* cancellation_id,
        pocketlm_request_id request_id) noexcept override {
        cancellation_id_ = cancellation_id;
        request_id_ = request_id;
        llama_set_abort_callback(context_, &LlamaBackend::abort_callback, this);
    }

    void clear_request() noexcept override {
        if (context_ != nullptr) {
            llama_set_abort_callback(context_, nullptr, nullptr);
        }
        cancellation_id_ = nullptr;
        request_id_ = POCKETLM_REQUEST_ID_INVALID;
        if (sampler_ != nullptr) {
            llama_sampler_free(sampler_);
            sampler_ = nullptr;
        }
        if (context_ != nullptr) {
            const llama_memory_t memory = llama_get_memory(context_);
            if (memory != nullptr) {
                llama_memory_clear(memory, true);
            }
        }
    }

private:
    BackendResult load(const char* model_path,
                       const pocketlm_session_config& config,
                       pocketlm_accelerator selected) {
        llama_model_params model_params = llama_model_default_params();
        if (selected == POCKETLM_ACCELERATOR_METAL) {
            model_params.n_gpu_layers = config.gpu_layers == 0
                ? -1
                : config.gpu_layers;
        } else {
            model_params.n_gpu_layers = 0;
        }

        model_ = llama_model_load_from_file(model_path, model_params);
        if (model_ == nullptr) {
            return BackendResult::failure(
                POCKETLM_ERR_MODEL_LOAD_FAILED,
                "llama.cpp could not load the model");
        }

        llama_context_params context_params = llama_context_default_params();
        context_params.n_ctx = static_cast<uint32_t>(config.context_size);
        context_params.n_batch = std::min<uint32_t>(512U, context_params.n_ctx);
        context_params.n_ubatch = context_params.n_batch;
        context_params.no_perf = true;
        context_params.offload_kqv = selected == POCKETLM_ACCELERATOR_METAL;
        context_params.abort_callback = &LlamaBackend::abort_callback;
        context_params.abort_callback_data = this;

        context_ = llama_init_from_model(model_, context_params);
        if (context_ == nullptr) {
            return BackendResult::failure(
                POCKETLM_ERR_CONTEXT_CREATE_FAILED,
                "llama.cpp could not create the inference context");
        }

        diagnostics_.requested_accelerator = config.accelerator;
        diagnostics_.selected_accelerator = selected;
        diagnostics_.context_size = static_cast<int32_t>(llama_n_ctx(context_));
        diagnostics_.batch_size = static_cast<int32_t>(llama_n_batch(context_));
        diagnostics_.model_layers = llama_model_n_layer(model_);
        diagnostics_.offloaded_layers = selected == POCKETLM_ACCELERATOR_CPU ? 0 : -1;
        diagnostics_.kqv_offloaded = selected == POCKETLM_ACCELERATOR_METAL ? 1 : 0;
        diagnostics_.peak_rss_bytes = 0;
        return BackendResult::success();
    }

    bool add_sampler(llama_sampler* sampler) {
        if (sampler == nullptr) {
            return false;
        }
        llama_sampler_chain_add(sampler_, sampler);
        return true;
    }

    BackendResult sampler_allocation_failure() {
        clear_request();
        return BackendResult::failure(
            POCKETLM_ERR_OOM,
            "failed to allocate a sampler");
    }

    static bool abort_callback(void* data) {
        const auto* backend = static_cast<const LlamaBackend*>(data);
        return backend != nullptr && backend->cancellation_id_ != nullptr &&
            backend->cancellation_id_->load(std::memory_order_acquire) ==
                backend->request_id_;
    }

    llama_model* model_ = nullptr;
    llama_context* context_ = nullptr;
    llama_sampler* sampler_ = nullptr;
    pocketlm_session_diagnostics diagnostics_{};
    const std::atomic<pocketlm_request_id>* cancellation_id_ = nullptr;
    pocketlm_request_id request_id_ = POCKETLM_REQUEST_ID_INVALID;
};

} // namespace

BackendResult create_llama_backend(
    const char* model_path,
    const pocketlm_session_config& config,
    std::unique_ptr<Backend>& out_backend) {
    try {
        return LlamaBackend::create(model_path, config, out_backend);
    } catch (const std::bad_alloc&) {
        return BackendResult::failure(
            POCKETLM_ERR_OOM,
            "out of memory while creating the llama.cpp backend");
    } catch (const std::exception& exception) {
        return BackendResult::failure(POCKETLM_ERR_INTERNAL, exception.what());
    } catch (...) {
        return BackendResult::failure(
            POCKETLM_ERR_INTERNAL,
            "unknown exception while creating the llama.cpp backend");
    }
}

} // namespace pocketlm
