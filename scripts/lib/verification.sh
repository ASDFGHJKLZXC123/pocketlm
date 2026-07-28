#!/usr/bin/env bash

# Shared invariants for the repository verification entrypoints. Callers enable
# `set -euo pipefail` before sourcing this file.

POCKETLM_EXPECTED_NODE_VERSION="22.23.1"
POCKETLM_EXPECTED_PNPM_VERSION="10.34.0"
POCKETLM_EXPECTED_CMAKE_VERSION="4.4.0"
POCKETLM_EXPECTED_NINJA_VERSION="1.13.2"
POCKETLM_EXPECTED_RUBY_VERSION="3.4.4"
POCKETLM_EXPECTED_BUNDLER_VERSION="4.0.7"
POCKETLM_EXPECTED_COCOAPODS_VERSION="1.16.2"
POCKETLM_EXPECTED_XCODE_VERSION="26.4.1"
POCKETLM_EXPECTED_XCODE_BUILD="17E202"
POCKETLM_EXPECTED_SWIFT_VERSION="6.3.1"
POCKETLM_EXPECTED_LLAMA_COMMIT="45cac7ca703fb9085eae62b9121fca01d20177f6"

pocketlm_fail() {
    echo "PocketLM verification failed: $*" >&2
    return 1
}

pocketlm_require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        pocketlm_fail "required command is unavailable: $command_name"
    fi
}

pocketlm_repository_root() {
    local script_directory="$1"

    (cd "${script_directory}/.." && pwd)
}

pocketlm_status_snapshot() {
    local repository_root="$1"

    git -C "$repository_root" status --porcelain=v1 --untracked-files=all
}

pocketlm_worktree_fingerprint() {
    local repository_root="$1"
    local untracked_path

    {
        git -C "$repository_root" status \
            --porcelain=v1 --untracked-files=all -z
        git -C "$repository_root" diff --binary HEAD --
        while IFS= read -r -d '' untracked_path; do
            printf '%s\0' "$untracked_path"
            git hash-object -- "${repository_root}/${untracked_path}"
        done < <(git -C "$repository_root" ls-files \
            --others --exclude-standard -z)
    } | git hash-object --stdin
}

pocketlm_require_clean_worktree() {
    local repository_root="$1"
    local status

    status=$(pocketlm_status_snapshot "$repository_root")
    if [[ -n "$status" ]]; then
        echo "Release verification requires a clean worktree. Current status:" >&2
        echo "$status" >&2
        return 1
    fi
}

pocketlm_assert_worktree_unchanged() {
    local repository_root="$1"
    local before="$2"
    local fingerprint_before="$3"
    local after
    local fingerprint_after

    after=$(pocketlm_status_snapshot "$repository_root")
    fingerprint_after=$(pocketlm_worktree_fingerprint "$repository_root")
    if [[ "$after" != "$before" || "$fingerprint_after" != "$fingerprint_before" ]]; then
        echo "Verification changed the worktree." >&2
        echo "Status before:" >&2
        echo "${before:-<clean>}" >&2
        echo "Status after:" >&2
        echo "${after:-<clean>}" >&2
        return 1
    fi

    git -C "$repository_root" diff --check
}

pocketlm_version_matches() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    local strict="${4:-0}"
    local allow_unpinned="${POCKETLM_ALLOW_UNPINNED_TOOLCHAIN:-0}"

    if [[ "$actual" == "$expected" ]]; then
        echo "$label: $actual"
        return 0
    fi

    if [[ "$strict" != "1" && "$allow_unpinned" == "1" ]]; then
        echo "WARNING: $label is $actual; pinned value is $expected." >&2
        return 0
    fi

    pocketlm_fail "$label is $actual; expected $expected"
}

pocketlm_check_repository_pins() {
    local repository_root="$1"
    local declared_node
    local declared_engine
    local declared_package_manager
    local declared_ruby
    local declared_xcode
    local declared_cocoa_pods
    local locked_bundler

    declared_node=$(awk 'NF { print $1; exit }' "${repository_root}/.node-version")
    declared_engine=$(node -e '
        const manifest = require(process.argv[1]);
        process.stdout.write(manifest.engines.node);
    ' "${repository_root}/app/package.json")
    declared_package_manager=$(node -e '
        const manifest = require(process.argv[1]);
        process.stdout.write(manifest.packageManager);
    ' "${repository_root}/app/package.json")
    declared_ruby=$(awk 'NF { print $1; exit }' "${repository_root}/.ruby-version")
    declared_xcode=$(awk 'NF { print $1; exit }' "${repository_root}/.xcode-version")
    declared_cocoa_pods=$(awk '/^COCOAPODS:/ { print $2; exit }' \
        "${repository_root}/app/ios/Podfile.lock")
    locked_bundler=$(awk '
        /^BUNDLED WITH$/ { getline; gsub(/^[[:space:]]+/, ""); print; exit }
    ' "${repository_root}/Gemfile.lock")

    pocketlm_version_matches ".node-version" "$declared_node" \
        "$POCKETLM_EXPECTED_NODE_VERSION" 1
    pocketlm_version_matches "package.json Node engine" "$declared_engine" \
        "$POCKETLM_EXPECTED_NODE_VERSION" 1
    pocketlm_version_matches "package.json packageManager" "$declared_package_manager" \
        "pnpm@${POCKETLM_EXPECTED_PNPM_VERSION}" 1
    pocketlm_version_matches ".ruby-version" "$declared_ruby" \
        "$POCKETLM_EXPECTED_RUBY_VERSION" 1
    pocketlm_version_matches ".xcode-version" "$declared_xcode" \
        "$POCKETLM_EXPECTED_XCODE_VERSION" 1
    pocketlm_version_matches "Podfile.lock CocoaPods" "$declared_cocoa_pods" \
        "$POCKETLM_EXPECTED_COCOAPODS_VERSION" 1
    pocketlm_version_matches "Gemfile.lock Bundler" "$locked_bundler" \
        "$POCKETLM_EXPECTED_BUNDLER_VERSION" 1
}

pocketlm_check_app_toolchain() {
    local repository_root="$1"
    local strict="${2:-0}"
    local node_version
    local pnpm_version

    pocketlm_require_command node
    pocketlm_require_command corepack
    pocketlm_check_repository_pins "$repository_root"
    node_version=$(node --version)
    node_version=${node_version#v}
    pnpm_version=$(cd "${repository_root}/app" && corepack pnpm --version)

    pocketlm_version_matches "Node.js" "$node_version" \
        "$POCKETLM_EXPECTED_NODE_VERSION" "$strict"
    pocketlm_version_matches "pnpm" "$pnpm_version" \
        "$POCKETLM_EXPECTED_PNPM_VERSION" "$strict"
}

pocketlm_check_native_toolchain() {
    local strict="${1:-0}"
    local cmake_version
    local ninja_version

    pocketlm_require_command cmake
    pocketlm_require_command ninja
    cmake_version=$(cmake --version | awk 'NR == 1 { print $3 }')
    ninja_version=$(ninja --version)

    pocketlm_version_matches "CMake" "$cmake_version" \
        "$POCKETLM_EXPECTED_CMAKE_VERSION" "$strict"
    pocketlm_version_matches "Ninja" "$ninja_version" \
        "$POCKETLM_EXPECTED_NINJA_VERSION" "$strict"
}

pocketlm_check_ruby_toolchain() {
    local strict="${1:-0}"
    local ruby_version

    pocketlm_require_command ruby
    ruby_version=$(ruby -e 'print RUBY_VERSION')
    pocketlm_version_matches "Ruby" "$ruby_version" \
        "$POCKETLM_EXPECTED_RUBY_VERSION" "$strict"
}

pocketlm_check_apple_toolchain() {
    local strict="${1:-0}"
    local bundler_version
    local xcode_output
    local xcode_version
    local xcode_build
    local swift_version

    pocketlm_require_command bundle
    pocketlm_require_command xcodebuild
    pocketlm_require_command swift

    pocketlm_check_ruby_toolchain "$strict"
    bundler_version=$(bundle --version | awk '{ print $NF }')
    xcode_output=$(xcodebuild -version)
    xcode_version=$(echo "$xcode_output" | awk 'NR == 1 { print $2 }')
    xcode_build=$(echo "$xcode_output" | awk 'NR == 2 { print $3 }')
    swift_version=$(swift --version 2>&1 | awk '
        match($0, /Apple Swift version [^ ]+/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/^Apple Swift version /, "", value)
            print value
            exit
        }
    ')

    pocketlm_version_matches "Bundler" "$bundler_version" \
        "$POCKETLM_EXPECTED_BUNDLER_VERSION" "$strict"
    pocketlm_version_matches "Xcode" "$xcode_version" \
        "$POCKETLM_EXPECTED_XCODE_VERSION" "$strict"
    pocketlm_version_matches "Xcode build" "$xcode_build" \
        "$POCKETLM_EXPECTED_XCODE_BUILD" "$strict"
    pocketlm_version_matches "Swift" "$swift_version" \
        "$POCKETLM_EXPECTED_SWIFT_VERSION" "$strict"
}

pocketlm_check_submodule() {
    local repository_root="$1"
    local status
    local actual_commit
    local nested_status

    pocketlm_require_command git
    status=$(git -C "$repository_root" submodule status --recursive)
    if [[ -z "$status" ]]; then
        pocketlm_fail "recursive submodule inventory is empty"
        return 1
    fi
    if echo "$status" | awk 'substr($0, 1, 1) != " " { exit 1 }'; then
        :
    else
        echo "$status" >&2
        pocketlm_fail "a recursive submodule is absent, conflicted, or at the wrong recorded commit"
        return 1
    fi

    actual_commit=$(git -C "${repository_root}/cpp/third_party/llama.cpp" rev-parse HEAD)
    pocketlm_version_matches "llama.cpp commit" "$actual_commit" \
        "$POCKETLM_EXPECTED_LLAMA_COMMIT" "1"

    nested_status=$(git -C "${repository_root}/cpp/third_party/llama.cpp" \
        status --porcelain=v1 --untracked-files=all)
    if [[ -n "$nested_status" ]]; then
        echo "$nested_status" >&2
        pocketlm_fail "llama.cpp submodule worktree is not clean"
    fi
}

pocketlm_require_positive_integer() {
    local label="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        pocketlm_fail "$label must be a positive integer (got: $value)"
    fi
}

pocketlm_require_no_space_checkout() {
    local repository_root="$1"

    if [[ "$repository_root" =~ [[:space:]] ]]; then
        pocketlm_fail \
            "iOS release verification requires a checkout path without whitespace: $repository_root"
    fi
}

pocketlm_require_free_kib() {
    local path="$1"
    local required_kib="$2"
    local available_kib

    available_kib=$(df -Pk "$path" | awk 'NR == 2 { print $4 }')
    if [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
        pocketlm_fail "could not determine free disk space for $path"
        return 1
    fi
    if (( available_kib < required_kib )); then
        pocketlm_fail \
            "insufficient free disk space: ${available_kib} KiB available, ${required_kib} KiB required"
        return 1
    fi
    echo "Disk preflight: ${available_kib} KiB available; ${required_kib} KiB required."
}
