#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_EXACT_MODEL="${HOME:?HOME is required}/.pocketlm/models/qwen2.5-0.5b-instruct-q4_k_m.gguf"
EXACT_MODEL_PATH="${POCKETLM_EXACT_MODEL_PATH:-$DEFAULT_EXACT_MODEL}"

ruby "${SCRIPT_DIR}/tests/model_verifier_test.rb"
"${SCRIPT_DIR}/tests/provisioning_shell_test.sh"

if [[ -f "$EXACT_MODEL_PATH" ]]; then
    ruby "${SCRIPT_DIR}/verify-model.rb" verify "$EXACT_MODEL_PATH"
elif [[ "${POCKETLM_REQUIRE_EXACT_MODEL:-0}" == "1" ]]; then
    echo "Required exact cached model is missing: $EXACT_MODEL_PATH" >&2
    exit 1
else
    echo "Exact cached-model verification skipped (not present): $EXACT_MODEL_PATH"
fi
