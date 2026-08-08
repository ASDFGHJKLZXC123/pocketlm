#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENTRY_POINT="${REPOSITORY_ROOT}/scripts/with-pinned-node.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pocketlm-pinned-node-test.XXXXXX")
STATUS_BEFORE=$(git -C "$REPOSITORY_ROOT" status --porcelain=v1 --untracked-files=all)
TEST_COUNT=0

cleanup() {
    local exit_status=$?
    local status_after

    rm -rf -- "$TEST_ROOT"
    status_after=$(git -C "$REPOSITORY_ROOT" status --porcelain=v1 --untracked-files=all)
    if [[ "$status_after" != "$STATUS_BEFORE" ]]; then
        echo "Pinned Node entry-point tests changed the repository worktree." >&2
        exit_status=1
    fi
    exit "$exit_status"
}
trap cleanup EXIT

fail() {
    echo "Pinned Node entry-point test failed: $*" >&2
    exit 1
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
}

assert_contains() {
    local haystack="$1"
    local needle="$2"

    [[ "$haystack" == *"$needle"* ]] ||
        fail "expected output to contain '$needle'; got: $haystack"
}

write_runtime() {
    local bin_directory="$1"
    local node_version="$2"
    local include_corepack="${3:-1}"

    mkdir -p "$bin_directory"
    printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$node_version" > "${bin_directory}/node"
    chmod +x "${bin_directory}/node"
    if [[ "$include_corepack" == "1" ]]; then
        printf '#!/bin/sh\n[ "$(node --version)" = %q ] || exit 42\nprintf "%%s\\n" "0.34.6"\n' \
            "$node_version" > "${bin_directory}/corepack"
        chmod +x "${bin_directory}/corepack"
    fi
}

copy_entry_point_with_pin() {
    local case_name="$1"
    local pin_contents="$2"
    local case_root="${TEST_ROOT}/${case_name}"

    mkdir -p "${case_root}/scripts"
    cp "$ENTRY_POINT" "${case_root}/scripts/with-pinned-node.sh"
    chmod +x "${case_root}/scripts/with-pinned-node.sh"
    printf '%s' "$pin_contents" > "${case_root}/.node-version"
    printf '%s\n' "${case_root}/scripts/with-pinned-node.sh"
}

BASE_PATH="/usr/bin:/bin"
EXACT_ACTIVE_BIN="${TEST_ROOT}/active/bin"
write_runtime "$EXACT_ACTIVE_BIN" "v22.23.1"

active_output=$(
    env -u POCKETLM_NODE_BIN \
        NVM_DIR="${TEST_ROOT}/unused-nvm" \
        PATH="${EXACT_ACTIVE_BIN}:${BASE_PATH}" \
        "$ENTRY_POINT" /bin/sh -c 'printf "%s" "$1"' shell active-exact
)
[[ "$active_output" == "active-exact" ]] || fail "exact active Node was not used"
pass

explicit_output=$(
    POCKETLM_NODE_BIN="$EXACT_ACTIVE_BIN" \
        PATH="$BASE_PATH" \
        "$ENTRY_POINT" node --version
)
[[ "$explicit_output" == "v22.23.1" ]] || fail "valid POCKETLM_NODE_BIN was not used"
pass

MISMATCHED_BIN="${TEST_ROOT}/mismatched/bin"
NVM_ROOT="${TEST_ROOT}/nvm"
PINNED_NVM_BIN="${NVM_ROOT}/versions/node/v22.23.1/bin"
write_runtime "$MISMATCHED_BIN" "v25.9.0"
write_runtime "$PINNED_NVM_BIN" "v22.23.1"

nvm_output=$(
    env -u POCKETLM_NODE_BIN \
        NVM_DIR="$NVM_ROOT" \
        PATH="${MISMATCHED_BIN}:${BASE_PATH}" \
        "$ENTRY_POINT" node --version
)
[[ "$nvm_output" == "v22.23.1" ]] || fail "NVM fallback did not select the pinned Node"
pass

HOME_ROOT="${TEST_ROOT}/home"
HOME_NVM_BIN="${HOME_ROOT}/.nvm/versions/node/v22.23.1/bin"
write_runtime "$HOME_NVM_BIN" "v22.23.1"

home_output=$(
    env -u POCKETLM_NODE_BIN -u NVM_DIR \
        HOME="$HOME_ROOT" \
        PATH="${MISMATCHED_BIN}:${BASE_PATH}" \
        "$ENTRY_POINT" node --version
)
[[ "$home_output" == "v22.23.1" ]] || fail "HOME NVM fallback did not select the pinned Node"
pass

LYING_BIN="${TEST_ROOT}/lying/bin"
write_runtime "$LYING_BIN" "v22.23.0"
if lying_output=$(
    POCKETLM_NODE_BIN="$LYING_BIN" \
        PATH="${MISMATCHED_BIN}:${BASE_PATH}" \
        "$ENTRY_POINT" /bin/true 2>&1
); then
    fail "lying POCKETLM_NODE_BIN unexpectedly passed"
fi
assert_contains "$lying_output" "is v22.23.0; expected v22.23.1"
pass

if missing_output=$(
    env -u POCKETLM_NODE_BIN \
        NVM_DIR="${TEST_ROOT}/missing-nvm" \
        PATH="${MISMATCHED_BIN}:${BASE_PATH}" \
        "$ENTRY_POINT" /bin/true 2>&1
); then
    fail "missing pinned runtime unexpectedly passed"
fi
assert_contains "$missing_output" "install the pinned NVM runtime or set POCKETLM_NODE_BIN"
pass

MISSING_COREPACK_BIN="${TEST_ROOT}/missing-corepack/bin"
write_runtime "$MISSING_COREPACK_BIN" "v22.23.1" 0
if corepack_output=$(
    POCKETLM_NODE_BIN="$MISSING_COREPACK_BIN" \
        PATH="$BASE_PATH" \
        "$ENTRY_POINT" /bin/true 2>&1
); then
    fail "runtime without Corepack unexpectedly passed"
fi
assert_contains "$corepack_output" "does not contain an executable corepack"
pass

COLON_BIN="${TEST_ROOT}/colon:path/bin"
write_runtime "$COLON_BIN" "v22.23.1"
if colon_output=$(
    POCKETLM_NODE_BIN="$COLON_BIN" \
        PATH="$BASE_PATH" \
        "$ENTRY_POINT" /bin/true 2>&1
); then
    fail "colon-containing POCKETLM_NODE_BIN unexpectedly passed"
fi
assert_contains "$colon_output" "must not contain ':' because PATH uses ':' as its separator"
pass

COLON_TARGET_BIN="${TEST_ROOT}/physical:runtime/bin"
COLON_TARGET_LINK="${TEST_ROOT}/runtime-link"
write_runtime "$COLON_TARGET_BIN" "v22.23.1"
ln -s "$COLON_TARGET_BIN" "$COLON_TARGET_LINK"
if colon_target_output=$(
    POCKETLM_NODE_BIN="$COLON_TARGET_LINK" \
        PATH="$BASE_PATH" \
        "$ENTRY_POINT" /bin/true 2>&1
); then
    fail "POCKETLM_NODE_BIN resolving to a colon-containing path unexpectedly passed"
fi
assert_contains "$colon_target_output" "resolves to a path containing ':'"
pass

MALFORMED_ENTRY_POINT=$(copy_entry_point_with_pin malformed '22.23')
if malformed_output=$(
    POCKETLM_NODE_BIN="$EXACT_ACTIVE_BIN" \
        PATH="$BASE_PATH" \
        "$MALFORMED_ENTRY_POINT" /bin/true 2>&1
); then
    fail "malformed .node-version unexpectedly passed"
fi
assert_contains "$malformed_output" ".node-version must contain exactly one numeric version"
pass

EMPTY_ENTRY_POINT=$(copy_entry_point_with_pin empty '')
if empty_output=$(
    POCKETLM_NODE_BIN="$EXACT_ACTIVE_BIN" \
        PATH="$BASE_PATH" \
        "$EMPTY_ENTRY_POINT" /bin/true 2>&1
); then
    fail "empty .node-version unexpectedly passed"
fi
assert_contains "$empty_output" "got: <empty>"
pass

ARGUMENT_LOG="${TEST_ROOT}/arguments.log"
set +e
POCKETLM_NODE_BIN="$EXACT_ACTIVE_BIN" \
ARGUMENT_LOG="$ARGUMENT_LOG" \
PATH="$BASE_PATH" \
    "$ENTRY_POINT" /bin/sh -c \
        'printf "%s\\n" "$1" "$2" > "$ARGUMENT_LOG"; exit 37' \
        shell 'argument with spaces' '--literal-flag'
propagated_status=$?
set -e
[[ "$propagated_status" == "37" ]] || fail "exit status was $propagated_status; expected 37"
first_propagated_argument=$(sed -n '1p' "$ARGUMENT_LOG")
second_propagated_argument=$(sed -n '2p' "$ARGUMENT_LOG")
[[ "$first_propagated_argument" == "argument with spaces" ]] || fail "first argument changed"
[[ "$second_propagated_argument" == "--literal-flag" ]] || fail "second argument changed"
pass

[[ $(git -C "$REPOSITORY_ROOT" status --porcelain=v1 --untracked-files=all) == "$STATUS_BEFORE" ]] ||
    fail "test execution changed the repository worktree"
pass

echo "Pinned Node entry-point tests passed: ${TEST_COUNT} cases."
