#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/verification.sh
source "${SCRIPT_DIR}/lib/verification.sh"

usage() {
    echo "Usage: $0 [native|ios|all]" >&2
}

mode="${1:-all}"
case "$mode" in
    native|ios|all)
        ;;
    *)
        usage
        exit 2
        ;;
esac
if (( $# > 1 )); then
    usage
    exit 2
fi

if [[ "${POCKETLM_ALLOW_UNPINNED_TOOLCHAIN:-0}" == "1" ]]; then
    pocketlm_fail "verify-release never permits an unpinned toolchain"
    exit 2
fi

pocketlm_require_clean_worktree "$REPOSITORY_ROOT"
status_before=$(pocketlm_status_snapshot "$REPOSITORY_ROOT")
fingerprint_before=$(pocketlm_worktree_fingerprint "$REPOSITORY_ROOT")
release_derived_data=""
cleanup() {
    if [[ -n "$release_derived_data" && -d "$release_derived_data" ]]; then
        rm -rf -- "$release_derived_data"
    fi
}
trap cleanup EXIT

pocketlm_check_submodule "$REPOSITORY_ROOT"
pocketlm_check_app_toolchain "$REPOSITORY_ROOT" 1
pocketlm_check_native_toolchain 1

run_fast_once=0
run_fast() {
    if [[ "$run_fast_once" == "0" ]]; then
        "${SCRIPT_DIR}/verify-fast.sh"
        run_fast_once=1
    fi
}

reject_ios_resolution_overrides() {
    local override_name
    local resolution_overrides=(
        ENTERPRISE_REPOSITORY
        HERMES_COMMIT
        HERMES_ENGINE_TARBALL_PATH
        HERMES_OVERRIDE_HERMESC_PATH
        POCKETLM_CMAKE_ARCH
        POCKETLM_CMAKE_SYSROOT
        RCT_BUILD_HERMES_FROM_SOURCE
        RCT_DEPS_VERSION
        RCT_HERMES_V1_ENABLED
        RCT_SYMBOLICATE_PREBUILT_FRAMEWORKS
        RCT_TESTONLY_RNCORE_TARBALL_PATH
        RCT_TESTONLY_RNCORE_VERSION
        RCT_USE_LOCAL_RN_DEP
        RCT_USE_PREBUILT_RNCORE
        RCT_USE_RN_DEP
        REACT_NATIVE_OVERRIDE_HERMES_DIR
        USE_FRAMEWORKS
    )

    for override_name in "${resolution_overrides[@]}"; do
        if printenv "$override_name" >/dev/null 2>&1; then
            pocketlm_fail "verify-release rejects iOS dependency override: $override_name"
            return 1
        fi
    done
}

assert_portable_local_podspecs() {
    local canonical_root
    local local_podspecs="${REPOSITORY_ROOT}/app/ios/Pods/Local Podspecs"

    [[ -d "$local_podspecs" ]] || {
        pocketlm_fail "CocoaPods did not generate Local Podspecs"
        return 1
    }
    canonical_root=$(cd "$REPOSITORY_ROOT" && pwd -P)
    if grep -R -F -q -- "$REPOSITORY_ROOT" "$local_podspecs" ||
        grep -R -F -q -- "$canonical_root" "$local_podspecs"; then
        pocketlm_fail "evaluated podspecs contain the checkout root"
        return 1
    fi
}

run_native() {
    run_fast
    "${SCRIPT_DIR}/verify-native.sh" all
}

run_ios() {
    local derived_data
    local minimum_free_kib="${POCKETLM_MIN_RELEASE_FREE_KIB:-8388608}"
    local bundle_jobs="${POCKETLM_BUNDLE_JOBS:-4}"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        pocketlm_fail "iOS release verification requires macOS"
        return 1
    fi
    pocketlm_require_positive_integer "POCKETLM_MIN_RELEASE_FREE_KIB" "$minimum_free_kib"
    pocketlm_require_positive_integer "POCKETLM_BUNDLE_JOBS" "$bundle_jobs"
    pocketlm_require_no_space_checkout "$REPOSITORY_ROOT"
    reject_ios_resolution_overrides
    pocketlm_check_apple_toolchain 1
    run_fast

    echo "==> Simulator qualification collector fixtures"
    "${SCRIPT_DIR}/tests/m4_simulator_collector_test.sh"

    echo "==> Installing the frozen Ruby dependency graph"
    (
        cd "$REPOSITORY_ROOT"
        BUNDLE_FROZEN=true bundle install --jobs "$bundle_jobs" --retry 3
    )

    cocoa_pods_version=$(cd "$REPOSITORY_ROOT" && bundle exec pod --version)
    pocketlm_version_matches "CocoaPods" "$cocoa_pods_version" \
        "$POCKETLM_EXPECTED_COCOAPODS_VERSION" 1

    echo "==> Installing locked CocoaPods dependencies"
    (
        cd "${REPOSITORY_ROOT}/app/ios"
        BUNDLE_FROZEN=true bundle exec pod install --deployment
    )
    assert_portable_local_podspecs

    pocketlm_require_free_kib "${TMPDIR:-/tmp}" "$minimum_free_kib"
    derived_data=$(mktemp -d "${TMPDIR:-/tmp}/pocketlm-derived.XXXXXX")
    release_derived_data="$derived_data"
    echo "==> Building the current iOS workspace from fresh DerivedData"
    xcodebuild \
        -workspace "${REPOSITORY_ROOT}/app/ios/PocketLM.xcworkspace" \
        -scheme PocketLM \
        -configuration Debug \
        -sdk iphonesimulator \
        -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "$derived_data" \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO \
        build
    rm -rf -- "$derived_data"
    release_derived_data=""
}

case "$mode" in
    native)
        run_native
        ;;
    ios)
        run_ios
        ;;
    all)
        run_native
        run_ios
        ;;
esac

pocketlm_assert_worktree_unchanged \
    "$REPOSITORY_ROOT" "$status_before" "$fingerprint_before"
echo "verify-release $mode passed with a clean result."
