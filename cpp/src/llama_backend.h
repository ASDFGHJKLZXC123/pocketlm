#pragma once

#include "backend.h"

#include <memory>
#include <string>

namespace pocketlm {

BackendResult create_llama_backend(
    const char* model_path,
    const pocketlm_session_config& config,
    std::unique_ptr<Backend>& out_backend);

} // namespace pocketlm
