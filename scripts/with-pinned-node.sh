#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
NODE_VERSION_FILE="${REPOSITORY_ROOT}/.node-version"

fail() {
    echo "PocketLM pinned Node entry point failed: $*" >&2
    exit 1
}

if (( $# == 0 )); then
    fail "no command supplied; usage: $0 <command> [args ...]"
fi

[[ -f "$NODE_VERSION_FILE" ]] ||
    fail "missing Node version pin: $NODE_VERSION_FILE"

expected_node_version=$(<"$NODE_VERSION_FILE")
if [[ ! "$expected_node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail ".node-version must contain exactly one numeric version (got: ${expected_node_version:-<empty>})"
fi

node_bin_is_valid() {
    local node_bin="$1"
    local actual_node_version

    [[ "$node_bin" != *:* ]] || return 1
    [[ -d "$node_bin" && -x "${node_bin}/node" && -x "${node_bin}/corepack" ]] ||
        return 1
    actual_node_version=$("${node_bin}/node" --version 2>/dev/null) || return 1
    [[ "$actual_node_version" == "v${expected_node_version}" ]] || return 1
    PATH="${node_bin}:${PATH:-/usr/bin:/bin}" \
        "${node_bin}/corepack" --version >/dev/null 2>&1 || return 1
}

require_valid_node_bin() {
    local node_bin="$1"
    local source_label="$2"
    local actual_node_version="<unavailable>"

    [[ "$node_bin" != *:* ]] ||
        fail "$source_label must not contain ':' because PATH uses ':' as its separator: $node_bin"
    [[ -d "$node_bin" ]] ||
        fail "$source_label is not a directory: ${node_bin:-<empty>}"
    [[ -x "${node_bin}/node" ]] ||
        fail "$source_label does not contain an executable node: $node_bin"
    actual_node_version=$("${node_bin}/node" --version 2>/dev/null) ||
        fail "$source_label node could not report its version: ${node_bin}/node"
    [[ "$actual_node_version" == "v${expected_node_version}" ]] ||
        fail "$source_label node is $actual_node_version; expected v${expected_node_version}"
    [[ -x "${node_bin}/corepack" ]] ||
        fail "$source_label does not contain an executable corepack: $node_bin"
    PATH="${node_bin}:${PATH:-/usr/bin:/bin}" \
        "${node_bin}/corepack" --version >/dev/null 2>&1 ||
        fail "$source_label corepack could not run: ${node_bin}/corepack"
}

selected_node_bin=""
if [[ "${POCKETLM_NODE_BIN+x}" == "x" ]]; then
    selected_node_bin="$POCKETLM_NODE_BIN"
    require_valid_node_bin "$selected_node_bin" "POCKETLM_NODE_BIN"
else
    active_node=$(command -v node 2>/dev/null || true)
    if [[ -n "$active_node" ]]; then
        active_node_bin=$(cd "$(dirname "$active_node")" && pwd -P)
        if node_bin_is_valid "$active_node_bin"; then
            selected_node_bin="$active_node_bin"
        fi
    fi

    if [[ -z "$selected_node_bin" ]]; then
        if [[ -n "${NVM_DIR:-}" ]]; then
            nvm_root="$NVM_DIR"
        elif [[ -n "${HOME:-}" ]]; then
            nvm_root="${HOME}/.nvm"
        else
            fail "HOME and NVM_DIR are unset; set POCKETLM_NODE_BIN to the directory containing Node v${expected_node_version} and Corepack"
        fi

        selected_node_bin="${nvm_root}/versions/node/v${expected_node_version}/bin"
        if [[ ! -d "$selected_node_bin" ]]; then
            fail "Node v${expected_node_version} was not found at $selected_node_bin; install the pinned NVM runtime or set POCKETLM_NODE_BIN to its bin directory"
        fi
        require_valid_node_bin "$selected_node_bin" "pinned NVM runtime"
    fi
fi

selected_node_bin=$(cd "$selected_node_bin" && pwd -P)
[[ "$selected_node_bin" != *:* ]] ||
    fail "selected Node bin resolves to a path containing ':'; PATH cannot represent it as one entry: $selected_node_bin"
export PATH="${selected_node_bin}:${PATH:-/usr/bin:/bin}"
exec "$@"
