#include "pocketlm_core.h"

#include <type_traits>

static_assert(std::is_standard_layout<pocketlm_token_event>::value, "C payload layout");
static_assert(std::is_standard_layout<pocketlm_stats>::value, "C payload layout");

int main() {
    return pocketlm_abi_version() == POCKETLM_ABI_VERSION ? 0 : 1;
}
