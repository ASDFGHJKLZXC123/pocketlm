#include "llama_backend.h"

namespace pocketlm {

BackendResult create_llama_backend(
    const char*,
    const pocketlm_session_config&,
    std::unique_ptr<Backend>&) {
    return BackendResult::failure(
        POCKETLM_ERR_MODEL_LOAD_FAILED,
        "focused fake-backend test stub");
}

} // namespace pocketlm
