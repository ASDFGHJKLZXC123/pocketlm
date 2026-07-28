#ifndef POCKETLM_CORE_H
#define POCKETLM_CORE_H

#include <stddef.h>
#include <stdint.h>

#define POCKETLM_ABI_VERSION 0x00020100u

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pocketlm_session pocketlm_session;
typedef int32_t pocketlm_request_id;

enum {
    POCKETLM_REQUEST_ID_INVALID = 0,
};

typedef enum {
    POCKETLM_ACCELERATOR_AUTO = 0,
    POCKETLM_ACCELERATOR_CPU = 1,
    POCKETLM_ACCELERATOR_METAL = 2,
} pocketlm_accelerator;

typedef struct {
    int32_t context_size;
    pocketlm_accelerator accelerator;
    int32_t gpu_layers;
} pocketlm_session_config;

typedef enum {
    POCKETLM_ROLE_SYSTEM = 0,
    POCKETLM_ROLE_USER = 1,
    POCKETLM_ROLE_ASSISTANT = 2,
} pocketlm_role;

typedef struct {
    pocketlm_role role;
    const char *content;
} pocketlm_message;

typedef struct {
    int32_t max_tokens;
    float temperature;
    int32_t top_k;
    float top_p;
    int32_t seed;
    int32_t n_threads;
} pocketlm_params;

typedef enum {
    POCKETLM_EVT_TOKEN = 1,
    POCKETLM_EVT_DONE = 2,
    POCKETLM_EVT_ERROR = 3,
} pocketlm_event_type;

typedef enum {
    POCKETLM_FINISH_EOS = 1,
    POCKETLM_FINISH_MAX_TOKENS = 2,
    POCKETLM_FINISH_CANCELLED = 3,
    POCKETLM_FINISH_CONTEXT_EXHAUSTED = 4,
} pocketlm_finish_reason;

typedef enum {
    POCKETLM_OK = 0,
    POCKETLM_ERR_INVALID_ARGUMENT = 1,
    POCKETLM_ERR_OOM = 2,
    POCKETLM_ERR_MODEL_LOAD_FAILED = 3,
    POCKETLM_ERR_CONTEXT_CREATE_FAILED = 4,
    POCKETLM_ERR_METAL_UNAVAILABLE = 5,
    POCKETLM_ERR_CHAT_TEMPLATE_FAILED = 6,
    POCKETLM_ERR_TOKENIZE_FAILED = 7,
    POCKETLM_ERR_PROMPT_TOO_LONG = 8,
    POCKETLM_ERR_DECODE_FAILED = 9,
    POCKETLM_ERR_INTERNAL = 10,
} pocketlm_error_code;

/* Negative synchronous generate results. Rejections never invoke callbacks. */
typedef enum {
    POCKETLM_GENERATE_INVALID_ARGUMENT = -1,
    POCKETLM_GENERATE_BUSY = -2,
    POCKETLM_GENERATE_SHUTTING_DOWN = -3,
    POCKETLM_GENERATE_OOM = -4,
    POCKETLM_GENERATE_ID_EXHAUSTED = -5,
} pocketlm_generate_rejection;

/*
 * A token event is one non-empty, complete, valid UTF-8 transport fragment.
 * `index` is a zero-based contiguous fragment index, not a sampled-token
 * ordinal. Payload memory is valid only during the callback.
 */
typedef struct {
    const char *bytes;
    size_t length;
    int32_t index;
} pocketlm_token_event;

typedef struct {
    int64_t prefill_ms;
    int64_t decode_ms;
    int32_t prompt_tokens;
    int32_t generated_tokens;
    int64_t peak_rss_bytes;
    pocketlm_finish_reason reason;
} pocketlm_stats;

typedef struct {
    pocketlm_error_code code;
    /* Non-empty valid UTF-8; borrowed and callback-scoped. */
    const char *message;
    size_t message_length;
} pocketlm_error;

typedef struct {
    pocketlm_accelerator requested_accelerator;
    pocketlm_accelerator selected_accelerator;
    int32_t context_size;
    int32_t batch_size;
    int32_t model_layers;
    int32_t offloaded_layers;
    int32_t kqv_offloaded;
    int64_t peak_rss_bytes;
} pocketlm_session_diagnostics;

typedef void (*pocketlm_event_cb)(
    void *user_data,
    pocketlm_request_id request_id,
    pocketlm_event_type type,
    const void *payload
);

/* These value-returning helpers cannot fail. */
pocketlm_session_config pocketlm_default_session_config(void);
pocketlm_params pocketlm_default_params(void);

/*
 * `model_path` and `out_session` are required. `config == NULL` selects the
 * default configuration. `*out_session` is set to NULL before validation and
 * remains NULL on failure. The path and config are consumed during this call.
 */
pocketlm_error_code pocketlm_create_v2(
    const char *model_path,
    const pocketlm_session_config *config,
    pocketlm_session **out_session
);

/* `pocketlm_destroy(NULL)` is a no-op. See the protocol's owner-side fence. */
void pocketlm_destroy(pocketlm_session *session);

/*
 * `session`, `messages`, a non-zero `message_count`, and `callback` are
 * required. `params == NULL` selects default parameters; `user_data` may be
 * NULL. Message strings and parameters are copied before acceptance. The
 * callback and `user_data` pointer value are borrowed through terminal return.
 */
pocketlm_request_id pocketlm_generate_v2(
    pocketlm_session *session,
    const pocketlm_message *messages,
    size_t message_count,
    const pocketlm_params *params,
    pocketlm_event_cb callback,
    void *user_data
);

/* A NULL session or invalid/stale request ID is a no-op. */
void pocketlm_cancel(
    pocketlm_session *session,
    pocketlm_request_id request_id
);

/* Both pointers are required; invalid arguments return INVALID_ARGUMENT. */
pocketlm_error_code pocketlm_get_diagnostics(
    const pocketlm_session *session,
    pocketlm_session_diagnostics *out_diagnostics
);

/* Returns 0 for a NULL session. Returned strings have static lifetime. */
int64_t pocketlm_peak_rss_bytes(const pocketlm_session *session);
uint32_t pocketlm_abi_version(void);
const char *pocketlm_version(void);
const char *pocketlm_error_code_string(pocketlm_error_code code);

#ifdef __cplusplus
}
#endif

#endif /* POCKETLM_CORE_H */
