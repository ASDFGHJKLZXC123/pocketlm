#include "pocketlm_core.h"

int main(void) {
    pocketlm_session_config config = pocketlm_default_session_config();
    pocketlm_params params = pocketlm_default_params();
    return (config.context_size > 0 && params.max_tokens > 0) ? 0 : 1;
}
