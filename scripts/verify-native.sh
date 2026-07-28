#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/verification.sh
source "${SCRIPT_DIR}/lib/verification.sh"

usage() {
    echo "Usage: $0 [debug|release|tsan|all]" >&2
}

mode="${1:-all}"
case "$mode" in
    debug|release|tsan|all)
        ;;
    --debug)
        mode=debug
        ;;
    --release)
        mode=release
        ;;
    --tsan)
        mode=tsan
        ;;
    --all)
        mode=all
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

for command_name in git cmake ctest ninja; do
    pocketlm_require_command "$command_name"
done

build_jobs="${POCKETLM_NATIVE_JOBS:-4}"
test_timeout="${POCKETLM_NATIVE_TEST_TIMEOUT:-60}"
pocketlm_require_positive_integer "POCKETLM_NATIVE_JOBS" "$build_jobs"
pocketlm_require_positive_integer "POCKETLM_NATIVE_TEST_TIMEOUT" "$test_timeout"

status_before=$(pocketlm_status_snapshot "$REPOSITORY_ROOT")
fingerprint_before=$(pocketlm_worktree_fingerprint "$REPOSITORY_ROOT")
pocketlm_check_native_toolchain
pocketlm_check_submodule "$REPOSITORY_ROOT"

keep_build="${POCKETLM_KEEP_NATIVE_BUILD:-0}"
if [[ -n "${POCKETLM_NATIVE_BUILD_ROOT:-}" ]]; then
    build_root="$POCKETLM_NATIVE_BUILD_ROOT"
    if [[ -e "$build_root" ]]; then
        pocketlm_fail "POCKETLM_NATIVE_BUILD_ROOT must not already exist: $build_root"
        exit 2
    fi
    mkdir -p -- "$build_root"
    keep_build=1
else
    build_root=$(mktemp -d "${TMPDIR:-/tmp}/pocketlm-native.XXXXXX")
fi

cleanup() {
    if [[ "$keep_build" != "1" ]]; then
        rm -rf -- "$build_root"
    else
        echo "Native verification build retained at: $build_root"
    fi
}
trap cleanup EXIT

configure_build() {
    local name="$1"
    local build_type="$2"
    local asan="$3"
    local tsan="$4"
    local coverage="$5"
    local build_directory="${build_root}/${name}"
    local build_qualification=OFF

    if [[ "$build_type" == "Release" ]]; then
        build_qualification=ON
    fi

    echo "==> Configuring fresh native tree: $name"
    cmake --fresh \
        -S "${REPOSITORY_ROOT}/cpp" \
        -B "$build_directory" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE="$build_type" \
        -DPOCKETLM_BUILD_TESTS=ON \
        -DPOCKETLM_ENABLE_ASAN="$asan" \
        -DPOCKETLM_ENABLE_TSAN="$tsan" \
        -DPOCKETLM_ENABLE_COVERAGE="$coverage" \
        -DPOCKETLM_BUILD_QUALIFICATION="$build_qualification" \
        -DGIT_EXECUTABLE="$(command -v git)"

    if [[ "$name" == "tsan" ]]; then
        echo "==> Building targeted TSAN concurrency suite"
        cmake --build "$build_directory" --target test_async --parallel "$build_jobs"
    else
        echo "==> Building native tree: $name"
        cmake --build "$build_directory" --parallel "$build_jobs"
    fi
}

run_debug() {
    local detect_leaks=1
    if [[ "$(uname -s)" == "Darwin" ]]; then
        detect_leaks=0
    fi

    configure_build debug Debug ON OFF ON
    echo "==> Running complete model-independent Debug ASan and coverage tests"
    echo "    (the 491 MB model-backed check remains scripts/verify-m2-model.sh)"
    ASAN_OPTIONS="detect_leaks=${detect_leaks}:halt_on_error=1" \
        ctest --test-dir "${build_root}/debug" \
            --output-on-failure \
            --no-tests=error \
            --timeout "$test_timeout" \
            -L m1a

    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "==> Running Objective-C++ bridge harness"
        POCKETLM_HARNESS_OUTPUT_DIR="${build_root}/bridge" \
            "${REPOSITORY_ROOT}/app/ios/PocketLMBridgeTests/run-harness.sh"
        echo "==> Running sanitized Objective-C++ bridge harness"
        POCKETLM_HARNESS_OUTPUT_DIR="${build_root}/bridge-sanitized" \
        POCKETLM_HARNESS_SANITIZE=1 \
            "${REPOSITORY_ROOT}/app/ios/PocketLMBridgeTests/run-harness.sh"
    fi
}

run_release() {
    configure_build release Release OFF OFF OFF
    pocketlm_require_command ruby
    echo "==> Verifying bounded qualification fatal-timeout evidence"
    ruby "${REPOSITORY_ROOT}/scripts/tests/m4_qualify_timeout_test.rb" \
        "${build_root}/release/pocketlm_qualify"
    echo "==> Release compile passed"
}

run_tsan() {
    configure_build tsan Debug OFF ON OFF
    echo "==> Running targeted TSAN concurrency tests"
    TSAN_OPTIONS="halt_on_error=1:second_deadlock_stack=1" \
        ctest --test-dir "${build_root}/tsan" \
            --output-on-failure \
            --no-tests=error \
            --timeout "$test_timeout" \
            -L concurrency
}

case "$mode" in
    debug)
        run_debug
        ;;
    release)
        run_release
        ;;
    tsan)
        run_tsan
        ;;
    all)
        run_debug
        run_release
        ;;
esac

pocketlm_assert_worktree_unchanged \
    "$REPOSITORY_ROOT" "$status_before" "$fingerprint_before"
echo "verify-native $mode passed."
