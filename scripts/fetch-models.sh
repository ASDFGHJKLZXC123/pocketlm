#!/usr/bin/env bash
# Fetch the single PocketLM development model into a host-side cache.
# This is not the application runtime path; the seeding workflow imports the
# verified file into Library/Application Support/PocketLM/Models.

set -euo pipefail

if ! command -v ruby >/dev/null 2>&1; then
    echo "Ruby is required to verify models/catalog.json and GGUF metadata." >&2
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download the model." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_PATH="${POCKETLM_CATALOG_PATH:-${SCRIPT_DIR}/../models/catalog.json}"
VERIFIER_PATH="${SCRIPT_DIR}/verify-model.rb"
# shellcheck source=lib/provisioning.sh
source "${SCRIPT_DIR}/lib/provisioning.sh"

# The catalog is the only model-identity source. Reject multiple entries so a
# future catalog expansion cannot silently change this fetch command.
IFS=$'\t' read -r MODEL_ID MODEL_FILENAME MODEL_URL MODEL_BYTES MODEL_SHA256 \
    MODEL_MAGIC MODEL_GGUF_VERSION MODEL_DIRECTORY_NAME MODEL_INSTALLED_FILENAME \
    CATALOG_SCHEMA_VERSION < <(
        ruby "$VERIFIER_PATH" catalog --catalog "$CATALOG_PATH" --format tsv
    )

MODEL_CACHE_DIR="${POCKETLM_MODEL_CACHE_DIR:-${HOME:?HOME is required}/.pocketlm/models}"
FORCE=0

usage() {
    echo "Usage: $0 [--force]"
    echo "Optional: set POCKETLM_MODEL_CACHE_DIR to override the host cache."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

verify_model() {
    local path="$1"
    ruby "$VERIFIER_PATH" verify --catalog "$CATALOG_PATH" "$path"
}

mkdir -p "$MODEL_CACHE_DIR"
TARGET_PATH="${MODEL_CACHE_DIR}/${MODEL_FILENAME}"
PARTIAL_PATH="${TARGET_PATH}.partial"

if [[ -f "$TARGET_PATH" && "$FORCE" -eq 0 ]]; then
    if verify_model "$TARGET_PATH"; then
        echo "Using verified existing model: $TARGET_PATH"
        exit 0
    fi
    echo "Existing model is invalid; rerun with --force to replace it." >&2
    exit 1
fi

cleanup_partial() {
    rm -f -- "$PARTIAL_PATH"
}
trap cleanup_partial EXIT

# A partial is never an installed model and is never resumed without a fresh
# integrity pass. Remove a stale one before calculating the required capacity.
rm -f -- "$PARTIAL_PATH"
pocketlm_require_free_space "$MODEL_CACHE_DIR" "$MODEL_BYTES" "model download"

echo "Downloading immutable PocketLM model $MODEL_ID..."
curl --location --fail --show-error --progress-bar \
    --output "$PARTIAL_PATH" \
    -- "$MODEL_URL"

verify_model "$PARTIAL_PATH"
mv -f -- "$PARTIAL_PATH" "$TARGET_PATH"
trap - EXIT

verify_model "$TARGET_PATH"
echo "Installed verified model: $TARGET_PATH"
echo "SHA-256: $MODEL_SHA256"
