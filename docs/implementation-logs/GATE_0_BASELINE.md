# Expansion Gate 0 baseline

Status: active capture; G0-A tooling implementation accepted, G0-A and Gate 0
remain open.
Date: 2026-08-07.
Repository basis: `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4`.
Documentation preservation: `3425a50c20f758702316b2c0cb831240ffbdde44`.
G0-A implementation: `2975d61d13903dd3cb5ee8518034427fe9d345be`.

This log distinguishes current-project behavior from expansion work. The
initial baseline capture was read-only. G0-A subsequently changed only the
verification entry point, its fixtures, and related documentation; it did not
add iOS or Android expansion behavior.

Detailed G0-A workspace, commit-chain, toolchain, and acceptance evidence is in
`docs/implementation-logs/GATE_0A_REPRODUCIBLE_WORKSPACE.md`.

## Repository state

| Check | Result |
| --- | --- |
| Approved base | `main` and `origin/main` at `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4` |
| Documentation preservation | Commit `3425a50c20f758702316b2c0cb831240ffbdde44`, sole parent the approved base, adds exactly nine Gate 0 documents |
| G0-A branch | `codex/expansion-g0a` at `2975d61d13903dd3cb5ee8518034427fe9d345be` |
| G0-A worktree | `/Users/f8fq/coding/PocketLM-G0A`; no-space predicate passed; clean before and after commit-based acceptance |
| Original checkout | Remains on `main` at the approved base with the same nine documents untracked and unmodified |
| llama.cpp submodule | `45cac7ca703fb9085eae62b9121fca01d20177f6`, clean and exact |
| Original checkout path | `/Users/f8fq/coding projects/Unfinished/PocketLM`; still rejected for release evidence because it contains spaces |
| G0-A release-path status | PASS: `verify-release.sh ios` accepted the no-space worktree and ended with a clean result |
| Other worktree | One stale/prunable metadata entry exists at `/private/tmp/PocketLM-M4R`; it was not modified or pruned |

## Host and pinned tools

| Item | Observed | Status |
| --- | --- | --- |
| Host | macOS 26.4.1, arm64, 16 GiB RAM, 8 logical / 4 performance cores | Recorded |
| Free disk | iOS preflight: 10,647,340 KiB; after accepted run: 9,707,104 KiB, observed 2026-08-07 21:45 PDT | The release lane passed its 8 GiB floor; Android SDK/NDK/image headroom remains inadequate and unproven |
| Default Node | 25.9.0 | Does not match repository pin |
| Pinned Node | `/Users/f8fq/.nvm/versions/node/v22.23.1/bin/node` | Exact and usable |
| Default pnpm | 10.33.0 | Does not match repository pin |
| Pinned entry point | `scripts/with-pinned-node.sh` resolved Node 22.23.1 and app pnpm 10.34.0 | PASS; 13/13 launcher fixtures under Bash 3.2.57 |
| Ruby / Bundler | `/opt/homebrew/opt/ruby/bin`: Ruby 3.4.4 / Bundler 4.0.7 | Exact when this directory leads `PATH`; `/usr/bin/ruby` is 2.6.10 and is rejected |
| CMake / Ninja | 4.4.0 / 1.13.2 | Exact |
| Xcode / Swift | 26.4.1 (17E202) / 6.3.1 | Exact |
| CocoaPods | 1.16.2 | Exact |
| Java | Temurin 17.0.19+10 | Accepted Android pin |

Reproducible JavaScript commands enter through `scripts/with-pinned-node.sh`.
The launcher never modifies Corepack shims. Acceptance commands explicitly put
`/opt/homebrew/opt/ruby/bin` first in `PATH` so Ruby resolution is equally
reproducible.

## Baseline results

| Lane | Result | Evidence |
| --- | --- | --- |
| Fast verification | PASS | Clean implementation commit through the pinned entry point: frozen install, TypeScript, ESLint, 5 Jest suites / 51 tests, static iOS export, 16 provisioning fixture runs / 57 assertions, 26 qualification fixture runs / 113 assertions, and 13 launcher cases |
| Native Debug + ASan | PASS | Whole `verify-native.sh all` rerun exited 0; fresh tree and 34/34 model-independent tests passed |
| Native Release | PASS | Same whole-verifier run completed the fresh Release compile and both bounded qualification timeout self-tests |
| Native TSan | PASS | Targeted `verify-native.sh tsan` lane: 22/22 concurrency tests, no ThreadSanitizer failure |
| Bridge harness | PASS | Objective-C++ bridge harness and its sanitized lane both reported `RESULT PASS` |
| Model-backed 0.5B | PARTIAL PASS | Exact SHA/GGUF authentication passed; native model load/generation test runs after the native baseline |
| Clean iOS Simulator release | PASS | `verify-release.sh ios` on clean commit `2975d61`: locked Bundler/CocoaPods inputs, fresh DerivedData, generic arm64 Simulator build across 115 targets, app validation, and final clean-result guard |
| iOS XCTest | PENDING | The release verifier builds the app but does not prove the manually represented XCTest target survives clean prebuild |
| iOS device SDK | PENDING | No isolated `iphoneos-arm64` package/build evidence yet |
| Android build | BLOCKED | No generated Android project, wrapper, NDK, API-36 platform, or runnable device lane |

The deliberate SHA mismatch printed by the provisioning fixture is a negative
test and the enclosing fixture suite passed.

The first `verify-native.sh all` invocation exited 1 only at its final
worktree-integrity guard because Gate 0 documentation was added while the long
native build was running. Its component checks passed. A later unchanged-tree
rerun completed with `verify-native all passed`, replacing that provisional
result with whole-verifier evidence.

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
- The no-space G0-A worktree completed a fresh generic arm64 Simulator app build
  and clean release-verifier guard. It did not run the app or XCTest.
- The original checkout's generated CMake tree contains stale absolute paths and
  is not release evidence.
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
- Installed inventory is build-tools 34.0.0/36.0.0/36.1.0, command-line tools
  20.0, emulator 36.5.11, platform-tools 37.0.0, platforms android-34 r3 and
  android-36.1 r1, and Android 36.1 Google APIs arm64 image r4. The local AVD is
  `clipsync_api_36_1`.
- Selected remote revisions are provisionally `platforms;android-36` r2, NDK
  `28.2.13676358`, SDK-side `cmake;3.31.6`, and the four assigned-host API-36
  normal/16 KiB image variants at revision 7. They are absent and must be
  resolved again with command-line tools 22 before becoming trusted pins.
- No Android emulator or physical device is attached.
- Installed command-line tools 20 report an XML schema-version warning while
  the advertised current package is 22. The tools must be updated before remote
  package resolution is trusted.
- Expo CLI's default SDK-55 template selector is mutable. Gate 1 must invoke
  clean prebuild with the verified `expo-template-bare-minimum@55.0.27` tarball;
  that template contains Gradle 9.0.0, so the pinned Gradle 8.13 wrapper and the
  r28c/CMake/API overrides must be deterministically reapplied and checked after
  both clean generations.

The local arm64 AVD is not a substitute for the deterministic x86_64 KVM lane,
physical arm64 feature proof, or a verified 16 KiB environment.

## Blocking conditions

1. Completed in G0-A: preserve the nine Gate 0 documents and create a clean,
   no-space implementation worktree without changing the original checkout.
2. Satisfy the project safety policy of at least 40 GiB local headroom before
   installing the Android NDK and macOS arm64 system-image lanes.
3. Install and record the exact Android packages from the orchestration packet.
4. Connect or supply facts for one Android arm64 phone and one iOS 17+ iPhone.
5. Complete the exact model-backed native lane, clean iOS XCTest/device-SDK
   lanes, and Android platform lanes. Native all, TSan, and clean iOS Simulator
   release evidence are complete.
6. Accept and fixture the Gate 0 contracts.

These are Gate 0 constraints, not failures introduced by expansion code.
