# Toolchain and verification

PocketLM pins its build inputs so JavaScript, native, CocoaPods, and Simulator
results can be reproduced without silently changing dependencies.

## Pinned versions

| Component | Version or constraint | Source of truth |
| --- | --- | --- |
| Node.js | 22.23.1 | `.node-version` |
| pnpm | 10.34.0 | `app/package.json` |
| Expo | 55.0.15 | `app/package.json` and lockfile |
| React Native | 0.83.4 | `app/package.json` and lockfile |
| TypeScript | 5.8.x | `app/package.json` and lockfile |
| CMake | 4.4.0 verified; 3.25 project minimum | `cpp/CMakeLists.txt` |
| Ninja | 1.13.2 | verification scripts |
| Xcode | 26.4.1, build 17E202 | `.xcode-version` |
| Swift | 6.3.1 toolchain | Xcode |
| Ruby | 3.4.4 | `.ruby-version` |
| Bundler | 4.0.7 | verification scripts |
| CocoaPods | 1.16.2 | `Gemfile` and `app/ios/Podfile.lock` |
| iOS deployment target | 17.0 | Expo, CocoaPods, Xcode, and native CMake |
| iOS Simulator | iOS 17.5 on iPhone 15 Pro | tested configuration |
| llama.cpp | `45cac7ca703fb9085eae62b9121fca01d20177f6` | Git submodule |

The platform-neutral core uses C++17. The React Native host target uses C++20,
with a C ABI between them. The exact React Native patch under `app/patches/`
keeps evaluated iOS dependency paths independent of the checkout root.

## Inspect the local environment

```sh
node --version
corepack pnpm --version
cmake --version
ninja --version
xcodebuild -version
swift --version
ruby --version
bundle --version
bundle exec pod --version
git submodule status --recursive
xcrun simctl list runtimes
```

Generated CMake trees, `node_modules`, Pods, DerivedData, model files, and test
artifacts are disposable outputs. They are not portable build inputs.

## Simulator backend

The iOS Simulator build defines `POCKETLM_SIMULATOR_CPU_ONLY`. AUTO accelerator
selection therefore uses CPU, reports zero offloaded layers, and disables K/Q/V
offload. The UI labels this state `CPU fallback`.

Metal remains compiled for the native iOS target, but that alone does not prove
correct physical-device offload. Device behavior requires separate testing.

## Model integrity

`models/catalog.json` pins the model repository, immutable upstream revision,
filename, byte count, SHA-256, GGUF metadata, and chat-template identity.

The host fetcher verifies a partial download before atomically publishing it.
The Simulator seeder verifies the source and destination, writes a
catalog-derived manifest, and atomically publishes both files in the app
sandbox. Runtime JavaScript checks the manifest, size, GGUF magic, and template
identity before passing the sandbox path to native code.

The app intentionally does not hash the full 491 MB model on the JavaScript
thread at every startup.

## Verification commands

Run commands from the repository root.

### Fast checks

```sh
./scripts/verify-fast.sh
```

This command:

- validates the Node, pnpm, Ruby, and submodule pins;
- installs the frozen JavaScript dependency graph;
- runs TypeScript, ESLint, and Jest;
- performs a static Expo iOS export; and
- runs model-provisioning and qualification-validator fixtures.

### Native checks

```sh
./scripts/verify-native.sh all
```

The `all` mode runs fresh Debug and Release CMake builds. Debug enables
AddressSanitizer and coverage; Release verifies optimized compilation. On
macOS, the Debug lane also runs the Objective-C++ bridge harnesses.

ThreadSanitizer is intentionally separate:

```sh
./scripts/verify-native.sh tsan
```

The model-backed test is also separate because it requires the downloaded
GGUF:

```sh
./scripts/fetch-models.sh
./scripts/verify-m2-model.sh
```

### Full macOS build

```sh
./scripts/verify-release.sh all
```

The full verifier requires:

- a clean working tree;
- the exact pinned tools;
- a recursive submodule checkout;
- a checkout path without spaces;
- locked CocoaPods dependencies; and
- at least 8 GiB free in the temporary filesystem.

It runs the fast checks, native Debug and Release checks, CocoaPods installation,
and a fresh arm64 iOS Simulator build. It does not run the model-backed test or
ThreadSanitizer.

All shared entry points compare the working tree before and after execution and
fail if verification modifies source files.

## Continuous integration

Pull requests and pushes run application checks, Linux Debug and Release native
builds, a macOS native build, and an iOS Simulator build. Scheduled workflows
exercise a cache-free bootstrap and the dedicated ThreadSanitizer lane.

Dependency-download caches may be reused; build trees, `node_modules`, Pods,
and DerivedData are never treated as portable artifacts.
