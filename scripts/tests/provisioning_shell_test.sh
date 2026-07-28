#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT=$(mktemp -d "/tmp/pocketlm-provisioning-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

SOURCE_PATH="${TEST_ROOT}/source.gguf"
CATALOG_PATH="${TEST_ROOT}/catalog.json"
CACHE_PATH="${TEST_ROOT}/cache"
SIMULATOR_CONTAINER="${TEST_ROOT}/simulator-data"
CURL_LOG="${TEST_ROOT}/curl.log"
XCRUN_LOG="${TEST_ROOT}/xcrun.log"

mkdir -p "$CACHE_PATH" "$SIMULATOR_CONTAINER"
ruby -I"${SCRIPT_DIR}" -rfixture_support -e '
  PocketLMTestFixture.write_gguf(ARGV.fetch(0))
  PocketLMTestFixture.write_catalog(ARGV.fetch(1), ARGV.fetch(0))
' "$SOURCE_PATH" "$CATALOG_PATH"

export PATH="${SCRIPT_DIR}/fakes:${PATH}"
export POCKETLM_CATALOG_PATH="$CATALOG_PATH"
export POCKETLM_MODEL_CACHE_DIR="$CACHE_PATH"
export POCKETLM_MIN_FREE_BYTES=0
export POCKETLM_FAKE_CURL_SOURCE="$SOURCE_PATH"
export POCKETLM_FAKE_CURL_LOG="$CURL_LOG"
export POCKETLM_FAKE_SIMULATOR_CONTAINER="$SIMULATOR_CONTAINER"
export POCKETLM_FAKE_XCRUN_LOG="$XCRUN_LOG"

FETCH_TARGET="${CACHE_PATH}/fixture.gguf"

# Insufficient capacity fails before curl creates or replaces any artifact.
export POCKETLM_MIN_FREE_BYTES=1000000000000000
if "${REPOSITORY_ROOT}/scripts/fetch-models.sh" >/dev/null 2>&1; then
    echo "fetch unexpectedly passed an insufficient disk-space check" >&2
    exit 1
fi
[[ ! -e "$CURL_LOG" ]]

export POCKETLM_MIN_FREE_BYTES=0
echo stale > "${FETCH_TARGET}.partial"
"${REPOSITORY_ROOT}/scripts/fetch-models.sh"
[[ -f "$FETCH_TARGET" ]]
[[ ! -e "${FETCH_TARGET}.partial" ]]
ruby "${REPOSITORY_ROOT}/scripts/verify-model.rb" verify \
    --catalog "$CATALOG_PATH" "$FETCH_TARGET" >/dev/null

# An invalid final is preserved and curl is not called without explicit force.
ruby -e 'File.open(ARGV.fetch(0), "r+b") { |file| file.write("NOPE") }' "$FETCH_TARGET"
LINES_BEFORE=$(wc -l < "$CURL_LOG" | tr -d '[:space:]')
if "${REPOSITORY_ROOT}/scripts/fetch-models.sh" >/dev/null 2>&1; then
    echo "fetch unexpectedly replaced an invalid final without --force" >&2
    exit 1
fi
LINES_AFTER=$(wc -l < "$CURL_LOG" | tr -d '[:space:]')
[[ "$LINES_BEFORE" == "$LINES_AFTER" ]]

"${REPOSITORY_ROOT}/scripts/fetch-models.sh" --force >/dev/null
ruby "${REPOSITORY_ROOT}/scripts/verify-model.rb" verify \
    --catalog "$CATALOG_PATH" "$FETCH_TARGET" >/dev/null

MODEL_DIRECTORY="${SIMULATOR_CONTAINER}/Library/Application Support/PocketLM/Models/fixture-q4km"
SEED_TARGET="${MODEL_DIRECTORY}/model.gguf"
MANIFEST_TARGET="${MODEL_DIRECTORY}/manifest.json"
mkdir -p "$MODEL_DIRECTORY"

# Simulator capacity is checked before terminating the app or writing a partial.
export POCKETLM_MIN_FREE_BYTES=1000000000000000
if "${REPOSITORY_ROOT}/scripts/seed-simulator-model.sh" >/dev/null 2>&1; then
    echo "seed unexpectedly passed an insufficient disk-space check" >&2
    exit 1
fi
[[ ! -e "$XCRUN_LOG" ]]
[[ ! -e "${SEED_TARGET}.partial" ]]

export POCKETLM_MIN_FREE_BYTES=0
echo stale > "${SEED_TARGET}.partial"

"${REPOSITORY_ROOT}/scripts/seed-simulator-model.sh" >/dev/null
[[ -f "$SEED_TARGET" ]]
[[ -f "$MANIFEST_TARGET" ]]
[[ ! -e "${SEED_TARGET}.partial" ]]
[[ ! -e "${MANIFEST_TARGET}.partial" ]]
ruby "${REPOSITORY_ROOT}/scripts/verify-model.rb" verify \
    --catalog "$CATALOG_PATH" "$SEED_TARGET" >/dev/null
ruby "${REPOSITORY_ROOT}/scripts/verify-model.rb" verify-manifest \
    --catalog "$CATALOG_PATH" "$MANIFEST_TARGET" >/dev/null
[[ $(wc -l < "$XCRUN_LOG" | tr -d '[:space:]') == 1 ]]

# A valid installation is idempotent and does not terminate the app again.
"${REPOSITORY_ROOT}/scripts/seed-simulator-model.sh" >/dev/null
[[ $(wc -l < "$XCRUN_LOG" | tr -d '[:space:]') == 1 ]]

# An invalid installed final is preserved without --force, then atomically
# replaced from a newly verified partial when force is explicit.
ruby -e 'File.open(ARGV.fetch(0), "r+b") { |file| file.write("NOPE") }' "$SEED_TARGET"
echo stale > "${SEED_TARGET}.partial"
if "${REPOSITORY_ROOT}/scripts/seed-simulator-model.sh" >/dev/null 2>&1; then
    echo "seed unexpectedly replaced an invalid final without --force" >&2
    exit 1
fi
[[ -e "${SEED_TARGET}.partial" ]]

"${REPOSITORY_ROOT}/scripts/seed-simulator-model.sh" --force >/dev/null
[[ ! -e "${SEED_TARGET}.partial" ]]
ruby "${REPOSITORY_ROOT}/scripts/verify-model.rb" verify \
    --catalog "$CATALOG_PATH" "$SEED_TARGET" >/dev/null
ruby "${REPOSITORY_ROOT}/scripts/verify-model.rb" verify-manifest \
    --catalog "$CATALOG_PATH" "$MANIFEST_TARGET" >/dev/null
[[ $(wc -l < "$XCRUN_LOG" | tr -d '[:space:]') == 2 ]]

echo "Provisioning shell tests passed."
