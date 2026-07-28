#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUTPUT_DIR=${POCKETLM_HARNESS_OUTPUT_DIR:-/tmp/pocketlm-m1b-harness}
mkdir -p "$OUTPUT_DIR"

SANITIZER_FLAGS=
if [ "${POCKETLM_HARNESS_SANITIZE:-0}" = "1" ]; then
  SANITIZER_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer"
fi

xcrun --sdk macosx clang++ \
  -fobjc-arc \
  -fblocks \
  -std=c++20 \
  -Wall \
  -Wextra \
  -Werror \
  $SANITIZER_FLAGS \
  -DPOCKETLM_BRIDGE_TESTING=1 \
  -I"$REPO_ROOT/cpp/include" \
  -I"$REPO_ROOT/app/ios/PocketLM/Bridge" \
  -I"$REPO_ROOT/app/ios/PocketLMBridgeTests" \
  "$REPO_ROOT/app/ios/PocketLM/Bridge/PocketLMBridge.mm" \
  "$REPO_ROOT/app/ios/PocketLMBridgeTests/FakePocketLMCore.mm" \
  "$REPO_ROOT/app/ios/PocketLMBridgeTests/PocketLMBridgeHarness.mm" \
  -framework Foundation \
  -o "$OUTPUT_DIR/PocketLMBridgeHarness"

if [ "${POCKETLM_HARNESS_SANITIZE:-0}" = "1" ]; then
  # LeakSanitizer is unavailable in Apple's macOS ASan runtime. Explicit live
  # context and fake create/destroy counters cover ownership balance instead.
  ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
    "$OUTPUT_DIR/PocketLMBridgeHarness"
else
  "$OUTPUT_DIR/PocketLMBridgeHarness"
fi
