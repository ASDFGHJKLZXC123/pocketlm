require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# ---------------------------------------------------------------------------
# CMake configuration used at prepare_command time (pod install).
#
# Simulator-focused build configuration:
#   We use `prepare_command` instead of a Xcode `script_phase` so that
#   `pod install` produces the static libs once and Xcode links them as
#   `vendored_libraries`.  Flags are pinned to iphonesimulator / arm64.
#
#   Consequence: device builds (arm64-iphoneos) require a separate pod
#   install run with POCKETLM_CMAKE_SYSROOT=iphoneos or a `script_phase`
#   upgrade. Device support remains future work.
#
#   For CI / Simulator-only development this is sufficient.
# ---------------------------------------------------------------------------

# Allow the caller to override the sysroot at pod install time:
#   POCKETLM_CMAKE_SYSROOT=iphoneos pod install
CMAKE_SYSROOT = ENV.fetch('POCKETLM_CMAKE_SYSROOT', 'iphonesimulator')
CMAKE_ARCH    = (CMAKE_SYSROOT == 'iphoneos') ? 'arm64' : 'arm64'

# cmake binary — try PATH first, fall back to the CMake.app bundle on macOS.
CMAKE_BIN = `which cmake 2>/dev/null`.strip.then { |p|
  p.empty? ? '/Applications/CMake.app/Contents/bin/cmake' : p
}

Pod::Spec.new do |s|
  # Keep the CocoaPods/Xcode target identity distinct from the PocketLM app
  # target. The JS/TurboModule contract remains exported as `PocketLM`.
  s.name        = 'PocketLMNative'
  s.version     = package['version']
  s.summary     = 'On-device LLM TurboModule bridge (llama.cpp + React Native)'
  s.description = 'Native iOS bridge for PocketLM: wraps the pocketlm_core C API with an Objective-C++ TurboModule.'
  s.homepage    = 'https://github.com/ASDFGHJKLZXC123/PocketLM'
  s.license     = { :type => 'Proprietary' }
  s.author      = 'PocketLM contributors'
  # PocketLM has one deployment target across Expo, CocoaPods, Xcode, and
  # the native CMake build. Keep this aligned with Podfile.properties.json and
  # the fixed CMake deployment target in prepare_command below.
  s.platform    = :ios, '17.0'

  # ---------------------------------------------------------------------------
  # Source — the pod's root is app/ios/ (where this podspec lives).
  # CocoaPods sets PODS_TARGET_SRCROOT to this directory.
  # ---------------------------------------------------------------------------
  s.source = { :path => '.' }

  # ---------------------------------------------------------------------------
  # The pod exposes exactly one Objective-C++ TurboModule (`PocketLM`). The plain
  # Objective-C bridge header also lets the deterministic harness compile the
  # lifecycle/delivery layer without React Native.
  # ---------------------------------------------------------------------------
  s.source_files        = 'PocketLM/Bridge/*.{h,m,mm}'
  s.public_header_files = 'PocketLM/Bridge/PocketLMBridge.h'

  # ---------------------------------------------------------------------------
  # Static libraries produced by prepare_command below.
  #
  # Order matters for the linker: high-level libs before low-level ones.
  #   pocketlm_core -> llama -> ggml -> ggml-cpu, ggml-blas, ggml-metal, ggml-base
  # ---------------------------------------------------------------------------
  cmake_build = 'PocketLM/cmake-build'

  s.vendored_libraries = [
    "#{cmake_build}/cpp/libpocketlm_core.a",
    "#{cmake_build}/cpp/third_party/llama.cpp/src/libllama.a",
    "#{cmake_build}/cpp/third_party/llama.cpp/ggml/src/libggml.a",
    "#{cmake_build}/cpp/third_party/llama.cpp/ggml/src/libggml-cpu.a",
    "#{cmake_build}/cpp/third_party/llama.cpp/ggml/src/ggml-blas/libggml-blas.a",
    "#{cmake_build}/cpp/third_party/llama.cpp/ggml/src/ggml-metal/libggml-metal.a",
    "#{cmake_build}/cpp/third_party/llama.cpp/ggml/src/libggml-base.a",
  ]

  # ---------------------------------------------------------------------------
  # System frameworks required by llama.cpp / ggml.
  # Metal shader is embedded into libggml-metal.a (GGML_METAL_EMBED_LIBRARY=ON),
  # so no runtime .metallib lookup is needed.
  # ---------------------------------------------------------------------------
  s.frameworks = %w[
    Foundation
    Metal
    MetalKit
    MetalPerformanceShaders
    Accelerate
  ]

  # ---------------------------------------------------------------------------
  # Header search paths so that:
  #   PocketLMBridge.mm  can #include "pocketlm_core.h"
  #   PocketLMModule.mm can #import <PocketLMSpec/PocketLMSpec.h>
  # ---------------------------------------------------------------------------
  cpp_include = '${PODS_TARGET_SRCROOT}/../../cpp/include'
  codegen_headers = '${PODS_ROOT}/Headers/Public/ReactCodegen'

  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../../cpp/include"',
      '"$(PODS_ROOT)/Headers/Public/ReactCodegen"',
      '"$(PODS_ROOT)/Headers/Public/React-Core"',
      '"$(PODS_ROOT)/boost"',
      '"$(PODS_ROOT)/RCT-Folly"',
      '"$(PODS_ROOT)/DoubleConversion"',
    ].join(' '),
    # React Native 0.83 generated TurboModule headers require C++20. The core
    # static libraries remain C++17 and meet this target only through the C ABI.
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    # Required for TurboModules: C++ exceptions must not cross the boundary
    'GCC_ENABLE_CPP_EXCEPTIONS'   => 'YES',
    'GCC_ENABLE_OBJC_EXCEPTIONS'  => 'YES',
    # Belt-and-suspenders: inject the clang flags directly so they survive any
    # Xcode build system version that does not honour the GCC_ENABLE_* xcconfig
    # keys for pod library targets compiled as Obj-C++ (.mm).
    'OTHER_CPLUSPLUSFLAGS'        => '$(inherited) -fexceptions -fobjc-exceptions',
    'OTHER_CFLAGS'                => '$(inherited) -fexceptions -fobjc-exceptions',
    'OTHER_LDFLAGS'               => '$(inherited) -lc++',
  }

  # ---------------------------------------------------------------------------
  # React Native / TurboModule dependencies.
  #
  # We list explicit pods rather than calling install_modules_dependencies()
  # because that helper is designed to be called from within the Podfile's
  # post-integration hook context, not from a library podspec.
  # ---------------------------------------------------------------------------
  s.dependency 'React-Core'
  s.dependency 'React-NativeModulesApple'
  s.dependency 'ReactCommon/turbomodule/core'
  s.dependency 'ReactCommon/turbomodule/bridging'
  s.dependency 'React-RCTAppDelegate'
  s.dependency 'RCTRequired'
  s.dependency 'RCTTypeSafety'
  s.dependency 'React-Fabric'
  s.dependency 'ReactCodegen'

  # ---------------------------------------------------------------------------
  # prepare_command — runs at `pod install` time (before Xcode build).
  #
  # Invokes CMake from app/ios/PocketLM/cmake-build/ with static-lib flags.
  # The output directory is relative to the podspec root (app/ios/).
  #
  # Simulator default: sysroot=iphonesimulator, arch=arm64.
  # To build for device: POCKETLM_CMAKE_SYSROOT=iphoneos pod install
  # ---------------------------------------------------------------------------
  s.prepare_command = <<~SHELL
    set -e

    PODS_SRCROOT="$(pwd)"
    CMAKE_SOURCE="${PODS_SRCROOT}/PocketLM"
    BUILD_DIR="${CMAKE_SOURCE}/cmake-build"

    # Resolve cmake binary
    if command -v cmake &>/dev/null; then
      CMAKE_BIN="cmake"
    elif [ -x "/Applications/CMake.app/Contents/bin/cmake" ]; then
      CMAKE_BIN="/Applications/CMake.app/Contents/bin/cmake"
    else
      echo "ERROR: cmake not found. Install CMake.app or add cmake to PATH." >&2
      exit 1
    fi

    SYSROOT="${POCKETLM_CMAKE_SYSROOT:-iphonesimulator}"
    ARCH="${POCKETLM_CMAKE_ARCH:-arm64}"
    # Keep one minimum across CocoaPods, Xcode, Expo, and native CMake.
    # Sysroot/architecture may vary, but the deployment target may not.
    DEPLOY_TARGET="17.0"

    echo "[PocketLM] CMake configure: sysroot=${SYSROOT} arch=${ARCH} deploy=${DEPLOY_TARGET}"

    # CMake and ggml's embedded-Metal assembly record absolute paths. A moved
    # checkout therefore cannot safely reuse this generated tree. The stamp
    # makes relocation cleanup explicit, scoped, and incremental thereafter.
    BUILD_STAMP="${BUILD_DIR}/.pocketlm-source-root"
    if [ -d "${BUILD_DIR}" ] && { [ ! -f "${BUILD_STAMP}" ] || [ "$(<"${BUILD_STAMP}")" != "${CMAKE_SOURCE}" ]; }; then
      case "${BUILD_DIR}" in
        "${CMAKE_SOURCE}/cmake-build") ;;
        *) echo "ERROR: refusing unexpected build cleanup path: ${BUILD_DIR}" >&2; exit 1 ;;
      esac
      echo "[PocketLM] Removing relocated native build tree: ${BUILD_DIR}"
      rm -rf "${BUILD_DIR}"
    fi
    mkdir -p "${BUILD_DIR}"
    printf '%s\n' "${CMAKE_SOURCE}" > "${BUILD_STAMP}"

    "${CMAKE_BIN}" \
      --fresh \
      -S "${CMAKE_SOURCE}" \
      -B "${BUILD_DIR}" \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_SYSROOT="${SYSROOT}" \
      -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOY_TARGET}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DPOCKETLM_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_TOOLS=OFF \
      -DLLAMA_BUILD_COMMON=OFF \
      -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=ON \
      -DGGML_ACCELERATE=ON \
      -DPOCKETLM_IOS_BUILD=ON \
      2>&1

    echo "[PocketLM] CMake build (this may take several minutes on first run)..."
    "${CMAKE_BIN}" --build "${BUILD_DIR}" --config Release -j$(sysctl -n hw.ncpu) 2>&1

    echo "[PocketLM] Static libraries:"
    find "${BUILD_DIR}" -name "*.a" | sort
    echo "[PocketLM] prepare_command done."
  SHELL
end
