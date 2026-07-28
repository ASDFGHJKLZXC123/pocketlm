#!/usr/bin/env bash
# Model-backed native verification. Unlike the general provisioning test
# runner, this command never treats an absent model or a skipped CTest as green.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_MODEL_PATH="${HOME:?HOME is required}/.pocketlm/models/qwen2.5-0.5b-instruct-q4_k_m.gguf"
MODEL_PATH="${POCKETLM_EXACT_MODEL_PATH:-$DEFAULT_MODEL_PATH}"
BUILD_DIRECTORY="${POCKETLM_M2_BUILD_DIR:-/tmp/pocketlm-m2-model}"
IOS_POLICY_BUILD_DIRECTORY="${POCKETLM_M2_IOS_POLICY_BUILD_DIR:-/tmp/pocketlm-m2-ios-policy}"
BUILD_JOBS="${POCKETLM_BUILD_JOBS:-4}"
TEST_TIMEOUT="${POCKETLM_M2_TEST_TIMEOUT:-300}"

for command in ruby cmake ctest git xcrun; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "$command is required for model-backed verification." >&2
        exit 1
    fi
done

MODEL_PATH=$(ruby -e 'puts File.expand_path(ARGV.fetch(0))' "$MODEL_PATH")
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Required exact model is absent: $MODEL_PATH" >&2
    echo "Run scripts/fetch-models.sh or set POCKETLM_EXACT_MODEL_PATH." >&2
    exit 1
fi
if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "POCKETLM_BUILD_JOBS must be a positive integer." >&2
    exit 2
fi
if [[ ! "$TEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "POCKETLM_M2_TEST_TIMEOUT must be a positive integer." >&2
    exit 2
fi

echo "Authenticating required model..."
ruby "${SCRIPT_DIR}/verify-model.rb" verify "$MODEL_PATH"

mkdir -p -- "$BUILD_DIRECTORY"
CMAKE_ARGUMENTS=(
    -S "${REPOSITORY_ROOT}/cpp"
    -B "$BUILD_DIRECTORY"
    -DPOCKETLM_BUILD_TESTS=ON
    -DGIT_EXECUTABLE="$(command -v git)"
)
if [[ ! -f "${BUILD_DIRECTORY}/CMakeCache.txt" ]]; then
    CMAKE_ARGUMENTS+=( -DCMAKE_BUILD_TYPE=Release )
fi

echo "Configuring and building the model-backed test..."
cmake "${CMAKE_ARGUMENTS[@]}"
cmake --build "$BUILD_DIRECTORY" --target test_model_backend --parallel "$BUILD_JOBS"

# catch_discover_tests writes test inventory after the executable is built.
# Refuse CTest's successful no-tests result before attempting qualification.
DISCOVERY_JSON=$(ctest --test-dir "$BUILD_DIRECTORY" --show-only=json-v1 -L m2-model)
DISCOVERED_COUNT=$(ruby -rjson -e '
  document = JSON.parse($stdin.read)
  tests = document.fetch("tests")
  abort "Model-backed verification discovered no m2-model CTests" if tests.empty?
  puts tests.length
' <<<"$DISCOVERY_JSON")
echo "Discovered $DISCOVERED_COUNT required m2-model CTest(s)."

JUNIT_PATH="${BUILD_DIRECTORY}/m2-model-results.xml"
rm -f -- "$JUNIT_PATH"
echo "Running model-backed CTest with the authenticated path..."
env POCKETLM_TEST_MODEL="$MODEL_PATH" \
    ctest --test-dir "$BUILD_DIRECTORY" \
        --output-on-failure \
        --timeout "$TEST_TIMEOUT" \
        --output-junit "$JUNIT_PATH" \
        -L m2-model

# A Catch2 SKIP has CTest success semantics. Inspect the JUnit record and fail
# explicitly if any discovered model-backed case was skipped or omitted.
ruby -rrexml/document -rrexml/xpath -e '
  document = REXML::Document.new(File.read(ARGV.fetch(0)))
  cases = REXML::XPath.match(document, "//testcase")
  expected = Integer(ARGV.fetch(1), 10)
  abort "Model-backed JUnit result omitted tests" unless cases.length == expected
  skipped = cases.count { |test_case| test_case.elements["skipped"] }
  failures = cases.count { |test_case| test_case.elements["failure"] || test_case.elements["error"] }
  abort "Model-backed run contained #{skipped} skipped test(s)" unless skipped.zero?
  abort "Model-backed run contained #{failures} failed test(s)" unless failures.zero?
' "$JUNIT_PATH" "$DISCOVERED_COUNT"

echo "Model-backed verification passed without skips: $MODEL_PATH"

echo "Configuring the mandatory iOS Simulator backend policy check..."
cmake --fresh \
    -S "${REPOSITORY_ROOT}/app/ios/PocketLM" \
    -B "$IOS_POLICY_BUILD_DIRECTORY" \
    -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DPOCKETLM_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_COMMON=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DPOCKETLM_IOS_BUILD=ON \
    -DGIT_EXECUTABLE="$(command -v git)"

ruby -e '
  cache = File.read(ARGV.fetch(0))
  flags = File.read(ARGV.fetch(1))
  abort "Simulator policy cache is not iphonesimulator" unless
    cache.match?(/^CMAKE_OSX_SYSROOT:STRING=iphonesimulator$/)
  abort "Simulator CPU-only policy is not enabled" unless
    cache.match?(/^POCKETLM_SIMULATOR_CPU_ONLY:BOOL=ON$/)
  abort "Simulator CPU-only policy did not reach pocketlm_core" unless
    flags.include?("-DPOCKETLM_SIMULATOR_CPU_ONLY=1")
  abort "Simulator policy check unexpectedly omitted compiled Metal support" unless
    flags.include?("-DGGML_USE_METAL")
' \
    "$IOS_POLICY_BUILD_DIRECTORY/CMakeCache.txt" \
    "$IOS_POLICY_BUILD_DIRECTORY/cpp/CMakeFiles/pocketlm_core.dir/flags.make"

echo "Simulator policy passed: Metal compiled, inference forced to CPU."
