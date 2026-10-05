# Expansion Gate 0 baseline

Status: G0-A tooling/macOS package evidence and G0-B fixtures accepted;
G0-A Linux/KVM evidence and overall Gate 0 remain open.
Original evidence date: 2026-08-07.
Updated: 2026-10-03 (status/dependency reconciliation, not a build rerun).
Repository basis: `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4`.
Documentation preservation: `3425a50c20f758702316b2c0cb831240ffbdde44`.
G0-A implementation: `2975d61d13903dd3cb5ee8518034427fe9d345be`.

This log distinguishes current-project behavior from expansion work. The
initial baseline capture was read-only. G0-A subsequently changed only the
verification entry point, its fixtures, and related documentation; it did not
add iOS or Android expansion behavior.

Detailed G0-A workspace, commit-chain, toolchain, and acceptance evidence is in
`docs/implementation-logs/GATE_0A_REPRODUCIBLE_WORKSPACE.md`.
The August consolidation and platform refresh is in
`docs/implementation-logs/GATE_0_CONSOLIDATION_2026-08-23.md`.
Gate 0B acceptance is in
`docs/implementation-logs/GATE_0B_CONTRACT_FIXTURES_2026-08-23.md`.

## Current checkpoint — 2026-10-03

- Active branch: `codex/gate-0b-contract-fixtures`, HEAD
  `8e6c4adef7a0c7fc6015b2b28460fbf7875d671e`; clean before this documentation revision.
- Local `main`: `561c66d6e0cc2f8dc8ce384f5341a0ea39ae6bac`; cached `origin/main`:
  `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4`. No fetch/push was performed.
- The original path still contains spaces; the historical G0-A and M4R
  worktrees remain absent/prunable. No metadata or user files were removed.
- Disk observation: 12,770,476 KiB (12.18 GiB). This is above the iOS release
  verifier's default 8 GiB threshold but below the Android 40 GiB safety floor /
  50 GiB preference. Recheck immediately before each lane; the August 53.04 GiB
  PASS is historical and cannot satisfy current dispatch readiness.
- Gate 0B's 173 cases / 10 families / 30 indexed files and the authenticated
  1.5B GGUF/template/license facts are accepted; production stays schema 1 / one
  model / ABI 2.1.0. Future native-language conformance is not yet proved.
- This revision runs documentation/fixture checks only; no application/native
  build, dependency installation, emulator or physical-device qualification is
  claimed. The orchestration checklist owns current overall Gate 0 blockers.

The following repository/tool/build tables preserve the August evidence context,
except where an explicit current-status pointer is given. They are not a fresh
October host inventory or build acceptance.

## Repository state

| Check | Result |
| --- | --- |
| Approved base | `main` and `origin/main` at `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4` |
| Documentation preservation | Commit `3425a50c20f758702316b2c0cb831240ffbdde44`, sole parent the approved base, adds exactly nine Gate 0 documents |
| G0-A branch | `codex/expansion-g0a` at accepted evidence commit `d6bdeb61f18a2f3651f96f4c7266016383b40d09` |
| G0-A worktree | Historical acceptance path `/Users/f8fq/coding/PocketLM-G0A`; no-space predicate passed in the recorded run, but the path is now absent and its metadata prunable |
| Consolidation checkout | `codex/gate-0-consolidation`, created directly from `d6bdeb6`; the original nine untracked blobs were reverified against `3425a50` and stashed recoverably before switching |
| llama.cpp submodule | `45cac7ca703fb9085eae62b9121fca01d20177f6`, clean and exact |
| Original checkout path | `/Users/f8fq/coding projects/Unfinished/PocketLM`; still rejected for release evidence because it contains spaces |
| G0-A release-path status | PASS: `verify-release.sh ios` accepted the no-space worktree and ended with a clean result |
| Other worktree | One stale/prunable metadata entry exists at `/private/tmp/PocketLM-M4R`; it was not modified or pruned |

## Host and pinned tools

| Item | Observed | Status |
| --- | --- | --- |
| Host | macOS 26.4.1, arm64, 16 GiB RAM, 8 logical / 4 performance cores | Recorded |
| Free disk | 55,615,884 KiB (53.04 GiB), observed 2026-08-23 11:24 PDT | PASS: above the 40 GiB Android safety floor and 50 GiB preference; the 2026-08-07 post-iOS value was 9,707,104 KiB |
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
| Model-backed 0.5B | PASS | Exact SHA/GGUF authentication and 1/1 required native load/generation test passed with no skip or failure; Simulator policy retained compiled Metal support while forcing inference to CPU |
| Clean iOS Simulator release | PASS | `verify-release.sh ios` on clean commit `2975d61`: locked Bundler/CocoaPods inputs, fresh DerivedData, generic arm64 Simulator build across 115 targets, app validation, and final clean-result guard |
| iOS XCTest | PENDING | The release verifier builds the app but does not prove the manually represented XCTest target survives clean prebuild |
| iOS device SDK | PENDING | No isolated `iphoneos-arm64` package/build evidence yet |
| Android build | BLOCKED | Local API-36/NDK/CMake/arm64 prerequisites are installed, but no generated Android project, Gradle wrapper, deterministic prebuild, running emulator, Linux/KVM x86_64 lane, or physical-device evidence exists |

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
| Model-backed status | PASS on 2026-08-23: 1/1 required CTest passed with no skip or failure; mandatory Simulator backend policy check also passed |
| 1.5B source identity | Official Qwen repository, revision `91cad51170dc346986eccefdc2dd33a9da36ead9` |
| 1.5B remote object | 1,117,320,736 bytes; SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| 1.5B license | Apache License 2.0 bytes at the pinned revision: 11,343 bytes; SHA-256 `832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e` |
| 1.5B authentication / admission | GGUF/template/license evidence accepted by Gate 0B (decision G0B-004); production admission remains deferred to Gate 4D, not blocked on authentication |

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
- A functional command-line tools 22.0 directory is available explicitly
  alongside the generic `latest` path, which still selects 20.0. The explicit
  directory is not registered as an installed SDK package. Gate evidence names
  the deterministic 22.0 path; its inventory command does not emit the old XML
  schema warning. The `latest` alias is a non-blocking host caveat.
- The local macOS arm64 gate pins are installed: build-tools 36.0.0,
  `platforms;android-36` revision 2, NDK `28.2.13676358` (r28c), SDK CMake
  3.31.6, API-36 Google APIs arm64 image revision 7, and API-36 Google APIs
  16 KiB arm64 image revision 7.
- `PocketLM_API36_arm64` and `PocketLM_API36_ps16k_arm64` are configured against
  those images. Neither AVD was booted for this capture, so runtime ABI, page
  size, app install, and native execution remain unproved.
- No Android emulator or physical device is attached.
- The assigned Linux/KVM normal and 16 KiB x86_64 image revision-7 lanes remain
  unevidenced on this host.
- Expo CLI's default SDK-55 template selector is mutable. Gate 1 must invoke
  clean prebuild with the verified `expo-template-bare-minimum@55.0.27` tarball;
  that template contains Gradle 9.0.0, so the pinned Gradle 8.13 wrapper and the
  r28c/CMake/API overrides must be deterministically reapplied and checked after
  both clean generations.

The local arm64 AVD definitions are not substitutes for the deterministic
x86_64 KVM lane, physical arm64 feature proof, or verified runtime page-size
evidence.

## Blocking conditions

Current Gate 0 evidence (authoritative checklist: `GATE_0_ORCHESTRATION.md`):

1. Record the assigned Linux/KVM normal and 16 KiB API-36 x86_64 image-revision-7
   installation evidence using the deterministic package-resolution route.
2. Connect or supply reproducible facts for one Android arm64 phone and one
   iOS 17+ iPhone, without recording private serial/device identifiers.
3. Accept the final overall Gate 0 closure/owner-readiness review. Gate 0B's
   contract/fixture freeze is already complete.

Separate implementation/dispatch requirements:

- recreate a clean no-space worktree and recheck capacity/pinned tools before
  dispatch; current Android headroom is below the floor;
- Gate 1 creates/proves deterministic prebuilds, durable XCTest, and isolated
  Simulator/device-SDK packaging; Gates 3A/4A prove Android emulator/native lanes;
- Gates 4A/4C own native repository/leases/repair, Gate 4D owns production
  migration/switch/second-model activation, and Gate 6 owns final qualification.

These existing gaps are not failures introduced by expansion code, nor grounds
to require Gate 1 outputs before permitting Gate 1 to create them.
