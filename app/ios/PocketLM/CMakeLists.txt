cmake_minimum_required(VERSION 3.25)

# ---------------------------------------------------------------------------
# iOS-specific project for PocketLM's C++ core
#
# CMake's job here ends at the static library.  The Bridge Swift/Obj-C++
# sources (app/ios/PocketLM/Bridge/) are compiled by Xcode/CocoaPods,
# not by this file.
#
# Usage (standalone iOS configure via Xcode toolchain):
#
#   cmake -S app/ios/PocketLM \
#         -B /tmp/pocketlm-ios \
#         -G Xcode \
#         -DCMAKE_SYSTEM_NAME=iOS \
#         -DCMAKE_OSX_ARCHITECTURES=arm64 \
#         -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
#
# CocoaPods will invoke CMake with equivalent flags when wired via the
# podspec (mobile-developer's next task).
# ---------------------------------------------------------------------------

project(pocketlm_ios_core C CXX)

# ---------------------------------------------------------------------------
# PocketLM supports iOS 17 and later.
# Xcode/CocoaPods normally pass this in; the default here guards standalone
# invocations.
# ---------------------------------------------------------------------------
if (CMAKE_OSX_DEPLOYMENT_TARGET AND
    NOT CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "17.0")
    message(FATAL_ERROR
        "PocketLM requires CMAKE_OSX_DEPLOYMENT_TARGET=17.0; got "
        "${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "17.0" CACHE STRING
    "PocketLM minimum iOS deployment target" FORCE)

# ---------------------------------------------------------------------------
# Architecture defaults for standalone invocation.
#
# When Xcode builds the project it passes CMAKE_OSX_ARCHITECTURES via its
# own toolchain file — do not force-override it here.  We only set a
# sensible default for bare cmake invocations.
#
# arm64 covers:
#   - iOS physical devices (arm64)
#   - iOS Simulator on Apple Silicon (arm64 with SDKROOT=iphonesimulator)
#   - Intel Mac simulator (x86_64) is handled by adding x86_64 when the
#     caller passes -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64".
#
# CocoaPods / Xcode supply the right value automatically; we do not
# hardcode the list here to avoid fighting the build system.
# ---------------------------------------------------------------------------
if (NOT CMAKE_OSX_ARCHITECTURES AND CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING
        "Default to arm64 for iOS device builds" FORCE)
endif()

# ---------------------------------------------------------------------------
# Signal to the root cpp/CMakeLists.txt that this is an iOS build so it
# does NOT force GGML_METAL=OFF.  Setting both variables covers the two
# cases:
#   - CMAKE_SYSTEM_NAME=iOS  (cross-compile toolchain sets IOS=TRUE)
#   - Plain macOS configure for syntax/IDE checks (POCKETLM_IOS_BUILD=ON)
# ---------------------------------------------------------------------------
set(POCKETLM_IOS_BUILD ON CACHE BOOL "Building for iOS" FORCE)

# llama.cpp's Metal backend can compile and initialize in the iOS Simulator,
# but that does not make the simulated GPU path a valid qualification target.
# Detect the SDK (not the architecture: Apple-Silicon devices and Simulators
# are both arm64) and keep Simulator inference on the deterministic CPU path.
# Physical iphoneos builds retain AUTO/Metal selection.
string(TOLOWER "${CMAKE_OSX_SYSROOT}" POCKETLM_OSX_SYSROOT_LOWER)
if(POCKETLM_OSX_SYSROOT_LOWER MATCHES "iphonesimulator")
    set(POCKETLM_SIMULATOR_CPU_ONLY ON CACHE BOOL
        "Disable accelerator selection in iOS Simulator builds" FORCE)
else()
    set(POCKETLM_SIMULATOR_CPU_ONLY OFF CACHE BOOL
        "Disable accelerator selection in iOS Simulator builds" FORCE)
endif()

# ---------------------------------------------------------------------------
# Metal — must be set BEFORE add_subdirectory so that ggml/CMakeLists.txt
# sees these values when it evaluates its option() calls.
#
# Flag names verified against:
#   cpp/third_party/llama.cpp/ggml/CMakeLists.txt  (tag b8833, commit 45cac7ca7)
#
#   GGML_METAL              — line 245: "ggml: use Metal"
#   GGML_METAL_EMBED_LIBRARY— line 248: "ggml: embed Metal library"
#                             Default is already ${GGML_METAL}, so when METAL=ON
#                             it defaults ON too; we force it explicitly to be
#                             unambiguous and to survive CMake cache round-trips.
#   GGML_ACCELERATE         — line 199: "ggml: enable Accelerate framework"
#                             Default is already ON on Apple; we force it here
#                             for documentation clarity and to ensure it isn't
#                             accidentally overridden by a parent cache.
#
# GGML_METAL_EMBED_LIBRARY is critical for iOS: without it the Metal
# shader is compiled into a separate .metallib file that must exist at a
# known filesystem path at runtime.  Embedding it in the binary avoids
# that runtime dependency inside the app sandbox.
#
# Note: LLAMA_METAL / LLAMA_METAL_EMBED_LIBRARY are the legacy names;
# llama.cpp's llama_option_depr() transition helper (llama.cpp
# CMakeLists.txt lines 158-167) maps them to GGML_* with a WARNING.
# We use the canonical GGML_* names directly.
# ---------------------------------------------------------------------------
set(GGML_METAL              ON  CACHE BOOL "Enable Metal on iOS"              FORCE)
set(GGML_METAL_EMBED_LIBRARY ON  CACHE BOOL "Embed Metal library into binary"  FORCE)
set(GGML_ACCELERATE          ON  CACHE BOOL "Enable Apple Accelerate framework" FORCE)

# ---------------------------------------------------------------------------
# Suppress Catch2 FetchContent even for Debug builds.
#
# The root cpp/CMakeLists.txt gates Catch2 behind POCKETLM_BUILD_TESTS,
# which defaults ON when CMAKE_BUILD_TYPE=Debug.  The iOS build must never
# trigger a network fetch (no git / network access during Xcode build
# phases; FetchContent would also pollute the Xcode build directory).
#
# Setting this with FORCE before add_subdirectory overrides the option()
# default in the root CMakeLists.txt regardless of build type.
# ---------------------------------------------------------------------------
set(POCKETLM_BUILD_TESTS OFF CACHE BOOL "Disable Catch2 in iOS builds" FORCE)

# ---------------------------------------------------------------------------
# Suppress llama.cpp's own examples, tests, and tools.
# The root cpp/CMakeLists.txt already sets these, but they are also set
# here defensively in case the iOS CMake is invoked in a context where the
# root CMake cache variables have not been populated yet.
# ---------------------------------------------------------------------------
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON   OFF CACHE BOOL "" FORCE)

# ---------------------------------------------------------------------------
# Include the C++ source tree.
#
# The root cpp/CMakeLists.txt is the single source of truth for:
#   - pocketlm_core (static library)
#   - pocketlm_smoke (CLI executable — also built here as a side-effect;
#     harmless, and lets the host machine run smoke tests)
#   - add_subdirectory(third_party/llama.cpp)
#   - All include paths and target_link_libraries
#
# We do NOT duplicate the source file list here.
# ---------------------------------------------------------------------------
add_subdirectory(
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../cpp   # source: cpp/
    ${CMAKE_BINARY_DIR}/cpp                    # binary: <build>/cpp/
)

# ---------------------------------------------------------------------------
# At this point pocketlm_core (STATIC) is defined by the subdirectory.
# CocoaPods / Xcode will link against it via the path:
#
#   <build>/cpp/libpocketlm_core.a
#
# No additional targets are needed here; the library and its transitive
# dependencies (ggml, llama) are all defined inside the subdirectory.
# ---------------------------------------------------------------------------
