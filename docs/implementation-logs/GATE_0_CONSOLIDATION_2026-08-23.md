# Gate 0 consolidation evidence — 2026-08-23

Status: consolidation branch prepared and verified on
`codex/gate-0-consolidation`; this evidence commit completes the repository
consolidation. Gate 0 remains open and no expansion feature implementation is
authorized.

Date: 2026-08-23.
Approved code basis: `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4`.
Accepted Gate 0A chain: `3425a50c20f758702316b2c0cb831240ffbdde44` →
`2975d61d13903dd3cb5ee8518034427fe9d345be` →
`d6bdeb61f18a2f3651f96f4c7266016383b40d09`.

## Repository preservation

The consolidation started from `main` aligned with `origin/main` at the
approved basis. The checkout contained exactly nine untracked Gate 0 documents.
Before switching branches, each working-tree blob was compared with its path in
`3425a50`; all nine matched byte-for-byte.

The documents were placed in the recoverable local stash
`69016a411a96cc38ba757c4409fcf6912530e26c`, and the consolidation branch was
created directly from `d6bdeb6`. The stash was not applied because its bytes are
already tracked in the accepted ancestry. No squash, rebase, or merge rewrote
the evidence chain.

The 2026-08-23 consolidation update changes evidence documentation only. It
does not activate catalog v2, generate an Android project, change the inference
protocol, or authorize Gate 1.

## Current verification

The following checks completed on 2026-08-23. Gate 0A differs from the approved
code basis only in its pinned-Node launcher, launcher fixtures, fast-verifier
wiring, and documentation; the native, bridge, and model-backed source under
test is unchanged.

| Lane | Result |
| --- | --- |
| Pinned fast verification | PASS: Node 22.23.1 / pnpm 10.34.0, frozen install, TypeScript, ESLint, 5 Jest suites / 51 tests, static iOS export, 16 provisioning runs / 57 assertions, 26 qualification runs / 113 assertions, and 13 launcher cases |
| Native Debug + ASan | PASS: fresh build, 34/34 model-independent tests |
| Objective-C++ bridge | PASS: normal and ASan/UBSan harnesses both reported `RESULT PASS` |
| Native Release | PASS: fresh 315-step build and both bounded qualification timeout self-tests |
| Native TSan | PASS: 22/22 targeted concurrency tests with no ThreadSanitizer report |
| Exact cached 0.5B model | PASS: catalog SHA/GGUF authentication and 1/1 required model-backed load/generation test, with no skip or failure |
| iOS Simulator backend policy | PASS: Metal support compiled; Simulator inference forced to CPU |

The pinned fast verifier ran from the consolidation working tree after the
evidence edits and passed its final worktree-integrity guard.

The model-backed policy result is compile/configuration evidence. It does not
establish a physical-device Metal, performance, energy, or thermal claim.

## Current host and platform evidence

The host snapshot was captured on 2026-08-23 at 11:24 PDT.

| Area | Evidence |
| --- | --- |
| Host | macOS 26.4.1 build 25E253, arm64, 16 GiB RAM, 8 logical / 4 performance cores |
| Free data-volume space | 55,615,884 KiB (53.04 GiB), above both the 40 GiB safety floor and 50 GiB preference |
| Accepted project tools | Node 22.23.1, pnpm 10.34.0, Ruby 3.4.4, Bundler 4.0.7, CocoaPods 1.16.2, host CMake 4.4.0, Ninja 1.13.2, Xcode 26.4.1 (17E202), Swift 6.3.1, Temurin 17.0.19+10 |
| Android SDK root | `/Users/f8fq/Library/Android/sdk` |
| Android platform tools | build-tools 36.0.0, `platforms;android-36` revision 2, emulator 36.5.11, platform-tools 37.0.0 |
| Android native tools | NDK `28.2.13676358` (r28c), SDK CMake 3.31.6 |
| macOS arm64 images | API-36 Google APIs arm64 revision 7 and API-36 Google APIs 16 KiB arm64 revision 7 |
| macOS arm64 AVDs | `PocketLM_API36_arm64` and `PocketLM_API36_ps16k_arm64`, each API 36 / arm64-v8a with 2 GiB RAM and a 10 GiB data partition |
| iOS Simulator | iPhone 15 Pro / iOS 17.5 exists and is available; it was shut down during this inventory |

A functional explicit Android command-line tools 22.0 directory is available at
`cmdline-tools/22.0` and resolves the installed inventory without the XML schema
warning. It is not registered as an installed SDK package. The generic
`cmdline-tools/latest` path still selects 20.0 and emits that warning, so Gate
commands name the deterministic explicit 22.0 path. The `latest` alias is a
non-blocking host caveat.

No Android emulator or physical Android device was attached. The two PocketLM
AVDs were not booted, so their runtime ABI, page size, app installation, and
native execution remain unproved. No physical iPhone was visible to Xcode.

## Status impact

This evidence records adequate current build headroom, closes the macOS arm64
Android package-install sub-lane, and closes the exact cached 0.5B model-backed
baseline. Because the disk snapshot is post-installation, it does not
reconstruct compliance with the original pre-installation headroom policy. It
does clear the present capacity hold. Gate 0 remains open.

The following remain open:

- record the assigned Linux/KVM API-36 normal and 16 KiB x86_64 image lanes;
- generate the deterministic Android project twice and prove its pinned Gradle,
  AGP, Kotlin, SDK, NDK, CMake, namespace, and codegen outputs;
- boot and qualify the Android emulator lanes;
- make the iOS XCTest target survive two clean prebuilds and record an isolated
  `iphoneos-arm64` compile/link;
- enroll one physical Android phone and one physical iPhone;
- complete the 1.5B GGUF facts, policy vectors, quarantine policy, golden
  contract fixtures, and final independent Gate 0 review.

Feature implementation remains held until the authoritative checklist in
`GATE_0_ORCHESTRATION.md` is complete.
