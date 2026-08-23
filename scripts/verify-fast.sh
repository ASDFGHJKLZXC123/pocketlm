#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/verification.sh
source "${SCRIPT_DIR}/lib/verification.sh"

for command_name in git node corepack ruby; do
    pocketlm_require_command "$command_name"
done

status_before=$(pocketlm_status_snapshot "$REPOSITORY_ROOT")
fingerprint_before=$(pocketlm_worktree_fingerprint "$REPOSITORY_ROOT")
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/pocketlm-fast.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
}
trap cleanup EXIT

echo "==> Validating app toolchain and recursive submodules"
pocketlm_check_app_toolchain "$REPOSITORY_ROOT"
pocketlm_check_ruby_toolchain
pocketlm_check_submodule "$REPOSITORY_ROOT"

echo "==> Expansion Gate 0 contract fixtures"
ruby "${SCRIPT_DIR}/tests/expansion_contract_fixtures_test.rb"

echo "==> Installing the frozen JavaScript dependency graph"
(
    cd "${REPOSITORY_ROOT}/app"
    CI=1 corepack pnpm install --frozen-lockfile
)

echo "==> TypeScript"
(cd "${REPOSITORY_ROOT}/app" && corepack pnpm typecheck)

echo "==> ESLint"
(cd "${REPOSITORY_ROOT}/app" && corepack pnpm lint)

echo "==> Jest"
(
    cd "${REPOSITORY_ROOT}/app"
    CI=1 corepack pnpm exec jest --ci --runInBand
)

echo "==> Static iOS Expo export"
(
    cd "${REPOSITORY_ROOT}/app"
    CI=1 EXPO_NO_TELEMETRY=1 corepack pnpm exec expo export \
        --platform ios \
        --clear \
        --output-dir "${temporary_root}/expo-export"
)

echo "==> Model provisioning fixtures"
POCKETLM_EXACT_MODEL_PATH="${temporary_root}/absent-ci-model.gguf" \
POCKETLM_REQUIRE_EXACT_MODEL=0 \
    "${SCRIPT_DIR}/test-model-provisioning.sh"

echo "==> Qualification artifact validator fixtures"
ruby "${SCRIPT_DIR}/tests/m4_artifact_validator_test.rb"

echo "==> Pinned Node entry-point fixtures"
"${SCRIPT_DIR}/tests/pinned_node_entrypoint_test.sh"

pocketlm_assert_worktree_unchanged \
    "$REPOSITORY_ROOT" "$status_before" "$fingerprint_before"
echo "verify-fast passed."
