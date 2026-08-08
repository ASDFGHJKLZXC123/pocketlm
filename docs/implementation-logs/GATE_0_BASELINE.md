# Expansion Gate 0 baseline

Status: active capture.
Date: 2026-08-07.
Repository basis: `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4`.

This log distinguishes current-project behavior from expansion work. No source
implementation was changed while collecting this evidence.

## Repository state

| Check | Result |
| --- | --- |
| Branch | `main`, aligned to `origin/main` at the recorded basis |
| Working tree | At capture start, pre-existing untracked `docs/plans/`; the active orchestration now also adds untracked `docs/contracts/` and `docs/implementation-logs/`; no expansion source edits |
| llama.cpp submodule | `45cac7ca703fb9085eae62b9121fca01d20177f6`, clean and exact |
| Checkout path | `/Users/f8fq/coding projects/Unfinished/PocketLM` |
| Release-path status | Blocked: the path contains spaces and the iOS release verifier rejects it |
| Other worktree | One stale/prunable metadata entry exists at `/private/tmp/PocketLM-M4R`; it was not modified or pruned |

## Host and pinned tools

| Item | Observed | Status |
| --- | --- | --- |
| Host | macOS 26.4.1, arm64, 16 GiB RAM, 8 logical / 4 performance cores | Recorded |
| Free disk | Approximately 17–19 GiB during audit | Above the 8 GiB release floor, but too tight for comfortable Android SDK/image expansion |
| Default Node | 25.9.0 | Does not match repository pin |
| Pinned Node | `/Users/f8fq/.nvm/versions/node/v22.23.1/bin/node` | Exact and usable |
| pnpm before Corepack activation | 10.33.0 | Does not match repository pin |
| pnpm during `verify-fast` | 10.34.0 | Exact; activated by repository verification |
| Ruby / Bundler | 3.4.4 / 4.0.7 | Exact |
| CMake / Ninja | 4.4.0 / 1.13.2 | Exact |
| Xcode / Swift | 26.4.1 (17E202) / 6.3.1 | Exact |
| CocoaPods | 1.16.2 | Exact |
| Java | Temurin 17.0.19+10 | Accepted Android pin |

The default interactive shell is not a reproducible project entry point. Until a
wrapper or documented activation is added, Gate 0 commands must prepend the
pinned NVM Node directory and let Corepack select pnpm 10.34.0.

## Baseline results

| Lane | Result | Evidence |
| --- | --- | --- |
| Fast verification | PASS | Frozen install, TypeScript, ESLint, 5 Jest suites / 51 tests, static iOS export, 16 provisioning fixture runs / 57 assertions, and 26 qualification fixture runs / 113 assertions |
| Native Debug + ASan | COMPONENT PASS | Fresh tree; 34/34 model-independent tests passed |
| Native Release | COMPONENT PASS | Fresh Release compile and both bounded qualification timeout self-tests passed |
| Native TSan | PENDING | Separate targeted lane required because `all` excludes TSan |
| Bridge harness | PASS | Objective-C++ bridge harness and its sanitized lane both reported `RESULT PASS` |
| Model-backed 0.5B | PARTIAL PASS | Exact SHA/GGUF authentication passed; native model load/generation test runs after the native baseline |
| Clean iOS release | BLOCKED | Current checkout path contains spaces and tree includes untracked plan documentation |
| Android build | BLOCKED | No generated Android project, wrapper, NDK, API-36 platform, or runnable device lane |

The deliberate SHA mismatch printed by the provisioning fixture is a negative
test and the enclosing fixture suite passed.

The first `verify-native.sh all` invocation exited 1 only at its final
worktree-integrity guard because these Gate 0 documentation files were added
while the long native build was running. Its Debug/ASan tests, both bridge
harnesses, Release compile, and qualification self-tests all passed. The complete
command must be rerun after documentation stops changing before Gate 0 records a
green native verifier.

## Model evidence

| Item | Result |
| --- | --- |
| Cached 0.5B path | `/Users/f8fq/.pocketlm/models/qwen2.5-0.5b-instruct-q4_k_m.gguf` |
| Catalog identity | Qwen2.5 0.5B Instruct Q4_K_M, schema 1 |
| Model authentication | PASS: SHA-256 `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`; GGUF v3, 291 tensors, 26 metadata entries |
| 0.5B chat template | 2,509 UTF-8 bytes; SHA-256 `d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4` |
| 0.5B license | Apache License 2.0 bytes at the pinned revision: 11,343 bytes; SHA-256 `832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e` |
| Model-backed status | Native load/generation test pending in this log |
| 1.5B source identity | Official Qwen repository, revision `91cad51170dc346986eccefdc2dd33a9da36ead9` |
| 1.5B remote object | 1,117,320,736 bytes; SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| 1.5B license | Apache License 2.0 bytes at the pinned revision: 11,343 bytes; SHA-256 `832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e` |
| 1.5B admission | Blocked until exact GGUF facts and template evidence are independently verified |

Large models remain outside Git and ordinary CI artifacts.

## iOS readiness

- Installed runtimes: iOS 17.5 and iOS 26.4.
- Named Simulator: iPhone 15 Pro on iOS 17.5, currently shut down.
- No physical iPhone is visible to Xcode device tooling.
- The generated CMake tree is Simulator arm64/iOS 17.0 and contains stale,
  checkout-absolute paths. It is not release evidence.
- The podspec writes to one fixed `PocketLM/cmake-build` directory and defaults
  to `iphonesimulator`; an `iphoneos` install would overwrite the same output.
- The existing XCTest target/scheme is manually represented in the generated
  Xcode project. `withPocketLMPod` does not recreate it after clean prebuild.

Gate 1 must isolate SDK outputs and create the test target/scheme idempotently.

## Android readiness

- The application is explicitly iOS-only; no `app/android`, Gradle wrapper,
  Android manifest, Android bridge, or Android scripts exist.
- No Android app package/namespace is configured yet. Gate 0 freezes the app
  package/application ID/app namespace to `com.pocketlm.app`, separately from
  native-library namespace `com.pocketlm.nativebridge` and the preserved codegen
  Java package `com.pocketlm`.
- Installed tools include platform-tools 37.0.0, emulator 36.5.11,
  build-tools 36.0.0, platforms 34 and 36.1, and one arm64 Android 36.1 AVD.
- Required `platforms;android-36`, NDK r28c, SDK-side `cmake;3.31.6`, x86_64
  API-36 image revision 7, and API-36 16 KiB images revision 7 are absent.
- No Android emulator or physical device is attached.
- The installed SDK manager reports an XML schema-version warning, so its
  command-line tools must be updated before package inventory is trusted.
- Expo CLI's default SDK-55 template selector is mutable. Gate 1 must invoke
  clean prebuild with the verified `expo-template-bare-minimum@55.0.27` tarball;
  that template contains Gradle 9.0.0, so the pinned Gradle 8.13 wrapper and the
  r28c/CMake/API overrides must be deterministically reapplied and checked after
  both clean generations.

The local arm64 AVD is not a substitute for the deterministic x86_64 KVM lane,
physical arm64 feature proof, or a verified 16 KiB environment.

## Blocking conditions

1. Create a clean no-space implementation worktree after the documentation has
   an approved Git basis.
2. Increase disk headroom before installing the Android NDK and multiple system
   images.
3. Install and record the exact Android packages from the orchestration packet.
4. Connect or supply facts for one Android arm64 phone and one iOS 17+ iPhone.
5. Complete native, TSan, model-backed, and clean platform baselines.
6. Accept and fixture the Gate 0 contracts.

These are Gate 0 constraints, not failures introduced by expansion code.
