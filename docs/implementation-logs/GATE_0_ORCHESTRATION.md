# Expansion Gate 0 orchestration packet

Status: active; G0-A tooling/macOS package evidence and G0-B contract fixtures
are accepted. Overall Gate 0 and feature dispatch remain held. The 2026-10-03
plan revision passed Claude Opus 5.5 review with nonblocking notes and fresh
independent verification; notes are incorporated/carried into scoped packets.
Original packet date: 2026-08-07.
Updated: 2026-10-03.
Repository basis: `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4`.
Documentation preservation: `3425a50c20f758702316b2c0cb831240ffbdde44`.
G0-A implementation: `2975d61d13903dd3cb5ee8518034427fe9d345be`.
G0-B accepted checkpoint: `8e6c4adef7a0c7fc6015b2b28460fbf7875d671e`.
Owning plan: `docs/plans/2026-08-07-ios-android-expansion-implementation-plan.md`.

## Outcome

The expansion will run as an orchestrated program. Gate 1 remains a single
foundation lane because it owns CMake linkage, native-codegen placement, catalog
identity, and the iOS packaging boundary. Android and iOS implementation lanes
may split only after those shared outputs and the Gate 0 contracts are accepted.

No expansion source implementation is authorized by this packet. G0-A added
only a reproducible verification entry point and evidence. Gate 0B accepted the
173-case corpus; native/TypeScript/Kotlin/Objective-C++ runtime conformance is
later implementation proof, not already established by that corpus. Gate 0 is
not closed: exact physical-phone facts, assigned Linux/KVM installation evidence,
and final overall closure review are outstanding.

The Gate 0 exit checklist below is the authoritative remaining-work list. New
prebuild/XCTest/device-SDK implementation belongs to Gate 1; Android emulator/
native execution belongs to Gates 3A/4A and final platform qualification to
Gate 6. Recording these gaps in Gate 0 does not require implementing them before
their own foundation can start. Current capacity/worktree/tool readiness is a
separate pre-dispatch check and is not permanently satisfied by dated evidence.

Independent review evidence is recorded in
`docs/implementation-logs/GATE_0_INDEPENDENT_REVIEW.md`.
The August repository, verification, model, and platform refresh is recorded
in `docs/implementation-logs/GATE_0_CONSOLIDATION_2026-08-23.md`.
Accepted fixtures/model facts are recorded in
`docs/implementation-logs/GATE_0B_CONTRACT_FIXTURES_2026-08-23.md` and
`docs/contracts/EXPANSION_GATE_0_DECISIONS.md`. The current revision/review is
recorded under `docs/implementation-logs/plan-revision/`.

## Model routing

The inherited `../AGENTS.md` now governs implementation: Claude Code implements
code, a fresh independent agent verifies each changed attempt, and the lead
reads both logs before accepting. The user requests exact `claude-opus-5-5` for
this planning validation; it is review-only, with no silent fallback. The owning
plan defines the current workflow. The following table preserves August audit
assignments as historical evidence, not a present allowlist or availability check.

| Role | Model | August assignment |
| --- | --- | --- |
| Root orchestrator and contract authority | `gpt-5.6-sol`, high | Dependency graph, freeze decisions, integration, and final evidence audit |
| Contract audit | `gpt-5.6-sol`, high | Completed; no files changed |
| Android readiness audit | `gpt-5.6-terra`, high | Completed; no files changed |
| iOS readiness audit | `gpt-5.6-terra`, high | Completed; no files changed |
| Independent Gate 0 packet review | `gpt-5.6-sol`, high | Completed; no P0/P1 remains and the packet is safe as a hold-only boundary |
| Small bounded follow-up | `gpt-5.3-codex-spark` | Unavailable in this session; leave queued or assign to Terra, never substitute `gpt-5.3-codex` |

The historical Spark preflight does not establish availability today or replace
the inherited Claude implementation/review requirements.

## Orchestration topology

```mermaid
flowchart LR
    G0["Gate 0: contracts and evidence"] --> G1["Gate 1: serialized foundation"]
    G1 --> NC["G3A root build-config sub-checkpoint"]
    NC --> AN["Android native execution acceptance"]
    G1 --> SC["Shared catalog/runtime policy"]
    G1 --> IP["iOS durable packaging/test lane"]
    AN --> AB["Android bridge/repository"]
    SC --> AB
    NC --> V["G3B accepted GGUF inspector"]
    V --> AB
    SC --> IR["G4C iOS repository"]
    V --> IR
    SC --> ACT["G4D serialized migration/switch/1.5B"]
    AB --> ACT
    IR --> ACT
    ACT --> AD["Android probe/downloader"]
    SC --> IPR["G4B iOS probe"]
    IP --> IPR
    ACT --> ID["iOS downloader integration"]
    IPR --> ID
    AD --> Q["Cross-platform qualification"]
    ID --> Q
```

The root orchestrator is the only lane that may accept shared-interface changes,
change the dependency graph, or integrate work across platform boundaries.

## Gate 0 decisions

The detailed contract is in
`docs/contracts/EXPANSION_GATE_0_CONTRACTS.md`. The following decisions are
accepted for planning and task-packet preparation:

1. The durable model preference and the active native session are separate.
   A preference never proves that a model is loaded.
2. Model installation, replacement, deletion, repair, and inference share one
   process-lifetime native repository/lease authority per platform.
3. Production model paths are derived and revalidated by native code. Arbitrary
   JavaScript paths remain available only through a separately compiled test
   entry point.
4. Catalog v2, installation record v2, commit marker v1, preference v1, probe
   snapshot v1, manager snapshot v1, and GGUF facts v1 evolve independently.
5. The Inference Event Protocol remains v2. The accepted 2.1 amendment documents
   committed-path validation, leases, publication, and reload reconciliation.
6. iOS uses isolated `iphonesimulator-arm64` and `iphoneos-arm64` native output
   lanes first. An XCFramework may replace them only after both slices and their
   link metadata are reproducible.
7. Android release ships `arm64-v8a` only, with distinct Armv8.0 baseline and
   feature-probed dot-product libraries. `x86_64` is a CI/emulator artifact only.
8. iOS Simulator qualification is available now, but no physical-device Metal,
   background-transfer, or performance claim is permitted without a connected
   iPhone. Android physical and 16 KiB behavior is likewise evidence-gated.
9. Background services remain in the application process for v1.1. A future
   Android remote process or iOS extension would require an OS/file-lock design.
10. Installation replacement promotes a complete staged generation directory.
    The prior active directory is first moved to a same-volume rollback path and
    can be restored after failure or crash; individual model/record/marker files
    are never mixed across publications.
11. The 1.5B artifact identity and GGUF/template/license facts were independently
    authenticated and accepted in Gate 0B, pinned to the official Qwen
    repository at revision `91cad51170dc346986eccefdc2dd33a9da36ead9`, file
    size `1117320736`, and SHA-256
    `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`.
    Its facts are recorded in decision G0B-004. Authentication is complete;
    production admission still waits for Gate 4D's native foundations, one-model
    migration, and accepted preference/fingerprint/switch behavior.
12. Development seeding uses a compiled dev/test-only local-file transport seam
    beneath the unchanged `startInstall` flow, owned by Gates 4A/4C. Host scripts
    deliver bytes to a private inbox, never write committed generations. Native
    receipt/transfer/validation/publication rules remain unchanged. No new public
    manager API, schema, receipt, ABI, or shipped release override is introduced.
    Android has no production schema-1 writer; real legacy migration is iOS-only,
    with native migration-fixture conformance and fresh v2 bootstrap on Android.

## Platform matrix

### Android target matrix

| Area | Gate 0 decision |
| --- | --- |
| Expo / React Native | Expo 55.0.15 / React Native 0.83.4 |
| App identity | `android.package`, Gradle `applicationId`, and app-module namespace: `com.pocketlm.app` |
| Native identity | Workspace package `@pocketlm/native`; library/Kotlin namespace `com.pocketlm.nativebridge`; existing codegen Java package `com.pocketlm`; TurboModule `PocketLM`; iOS pod `PocketLMNative` |
| Prebuild template | `expo-template-bare-minimum@55.0.27`; exact [tarball](https://registry.npmjs.org/expo-template-bare-minimum/-/expo-template-bare-minimum-55.0.27.tgz); SHA-512 `def044fc7a4d5e55a0e66509f7cdec74d076e3fe7659b28b9c9f5411a3e649fcda997e5910d0bcff1e071d8143c34d6afa27056ae1c7895b47ea716ef02e864e` |
| API levels | `minSdk 24`, `compileSdk 36`, `targetSdk 36` |
| Java | Temurin 17.0.19+10 |
| AGP / Gradle | AGP 8.12.0 / Gradle wrapper 8.13 |
| Gradle distribution | `gradle-8.13-bin.zip`; SHA-256 `20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78` |
| Kotlin | 2.1.20 |
| SDK | build-tools 36.0.0 and `platforms;android-36` |
| NDK | r28c, package `28.2.13676358` |
| CMake | SDK side-by-side `cmake;3.31.6` |
| Release ABI | `arm64-v8a` only |
| Test ABI | `system-images;android-36;google_apis;x86_64`, revision 7, on a Linux/KVM lane |
| Local arm64 smoke | `system-images;android-36;google_apis;arm64-v8a`, revision 7 |
| 16 KiB | `system-images;android-36;google_apis_ps16k;arm64-v8a` and `x86_64`, revision 7, plus physical proof; verify `PAGE_SIZE=16384`, ELF alignment, and APK zip alignment |
| Physical target | Pixel 8-class device on API 35+ is the recommended target; exact model/build/fingerprint remains open until hardware is supplied |

Android implementation does not start until the pinned SDK packages, NDK, CMake,
and emulator images are installed and physical-phone evidence is recorded.

### iOS target matrix

| Area | Gate 0 decision |
| --- | --- |
| Xcode / Swift | Xcode 26.4.1 (17E202) / Swift 6.3.1 |
| Deployment target | iOS 17.0+ |
| Simulator target | iPhone 15 Pro, iOS 17.5 |
| Native packaging | Fresh, non-overlapping Simulator and device-SDK output directories |
| Test durability | The XCTest target and scheme must survive two clean Expo prebuilds |
| Device compile | Clean `iphoneos-arm64` compile/link is mandatory before Gate 1 closes |
| Physical scope | A connected iOS 17+ arm64 iPhone is required for device load/download/Metal evidence; exact device remains open |

The plan's Simulator-only fallback needs an explicit user-approved scope-down
ADR and checklist amendment; none is recorded by this revision. Physical
iPhone enrollment therefore remains an overall Gate 0 requirement.

The current pod prepares one fixed Simulator archive tree. It must not be reused
for `iphoneos`, and the current manually maintained XCTest target is not yet a
clean-prebuild proof.

## Dispatch queue

### G0-A — reproducible workspace and toolchain entry point

Owner: root orchestrator. Reviewer: GPT-5.6 Sol.
Status: tooling implementation accepted at `2975d61`; dated clean fast/iOS
Simulator release and macOS arm64 package evidence passed. The August capacity
snapshot is historical, not current dispatch readiness. G0-A remains open for
assigned Linux/KVM package-resolution evidence.

Detailed evidence is recorded in
`docs/implementation-logs/GATE_0A_REPRODUCIBLE_WORKSPACE.md`.

Prerequisites:

- owner permission to preserve the approved documentation in Git;
- a short no-space worktree root; and
- adequate disk headroom for Android SDK/NDK/images and model fixtures.

Scope:

- establish the no-space expansion worktree without modifying the existing
  dirty checkout;
- make the pinned Node 22.23.1 and pnpm 10.34.0 entry point explicit; and
- capture exact resolved platform-package revisions.

Exit evidence:

- [x] The nine-document preservation commit has the approved base as its sole
      parent, and the original checkout remained unchanged through G0-A
      acceptance.
- [x] `/Users/f8fq/coding/PocketLM-G0A` passed the no-space predicate with the
      exact clean submodule during the 2026-08-07 acceptance.
- [x] `verify-fast` succeeds from clean implementation commit `2975d61` through
      the pinned entry point.
- [x] `verify-release.sh ios` accepts the clean no-space worktree and completes
      a fresh arm64 Simulator app build.
- [x] The 2026-08-23 11:24 PDT snapshot exceeded both the 40 GiB safety floor
      and 50 GiB preference: 55,615,884 KiB (53.04 GiB) was free.
- [x] Explicit command-line tools 22.0 inventory records the required macOS
      arm64 platform, NDK, CMake, normal image, and 16 KiB image revisions.
- [ ] Record the assigned Linux/KVM normal and 16 KiB x86_64 image revisions;
      macOS Gate evidence uses the deterministic explicit tools 22.0 path.

### G0-B — contract fixtures and ADR acceptance

Status: accepted/closed at `8e6c4ad`; 173 cases, 10 families, 30 indexed files,
with independent acceptance. This does not close overall Gate 0 or activate v2.
Historical owner/reviewer: GPT-5.6 Sol; bounded fixture work could use Terra.
Evidence: `docs/implementation-logs/GATE_0B_CONTRACT_FIXTURES_2026-08-23.md`.

Scope:

- accept the non-open sections of the Gate 0 contract;
- add golden valid/invalid fixtures for catalog, install record, preference,
  manager snapshot, path, lease, and bounded GGUF cases;
- resolve the policy profile and exact metadata for the 1.5B artifact; and
- record the Protocol 2.1 amendment without changing inference event semantics.

Forbidden changes:

- no codegen relocation;
- no catalog schema activation;
- no JNI/Objective-C++ implementation;
- no downloader; and
- no addition of the second catalog model.

### G0-C — hardware enrollment

Owner: root orchestrator with user-supplied hardware.

Capture for each phone: model, OS/API, build identifier or fingerprint, RAM,
architecture, page size, and available native feature probes. Device identifiers
or serial numbers must not enter the repository.

### G1-A — serialized packaging and codegen foundation

Status: queued; must not start before Gate 0 closes.
Implementer: Claude Code under the inherited workflow. Designer/integrator: lead.
Reviewer: fresh independent verification agent, not the implementer.

The packet will own root static-link policy, Android PIC support, one autolinked
native package/codegen location, minimal Android generation, isolated iOS SDK
packaging, durable XCTest creation, and canonical catalog resource copying. It
must not change inference behavior, catalog cardinality, persistence schema, or
download behavior.

Android clean prebuilds must go through a repository wrapper that downloads or
reuses the exact template tarball only after SHA-512 verification, passes the
local tarball through `--template`, regenerates the wrapper with a verified
Gradle 8.13 distribution, and then verifies the package/namespace, Gradle, AGP,
API, NDK, and CMake values. The Expo `sdk-55` template tag and the template's
bundled Gradle 9.0.0 wrapper are not accepted build inputs.

Gate 1 exit evidence, not Gate 0 prerequisites:

- two clean iOS/Android prebuilds through that wrapper with pinned generated
  inputs and exactly one inference spec;
- durable generic XCTest recreation plus passing tests on the named Simulator;
- isolated clean Simulator and device-SDK builds from a no-space worktree; and
- canonical native catalog resource identity.

Pre-dispatch refresh (required whenever a build lane starts):

- recreate/preserve an isolated clean no-space worktree; the historical G0-A
  path is absent/prunable, and no cleanup is authorized here;
- recheck pinned tools and disk. The 2026-10-03 snapshot is 12,770,476 KiB
  (12.18 GiB), above the iOS verifier's default 8 GiB threshold, but below the
  Android 40 GiB floor / 50 GiB preference. Gate 1 includes Android generation:
  each assigned Android runner must meet that floor, and the current local host
  cannot satisfy the joint foundation preflight. A separate iOS-only check uses
  its 8 GiB minimum but does not close Android readiness; and
- confirm the assigned runner, hardware and implementation/review model access.

## Gate 0 exit checklist

- [x] Consolidated implementation plan exists.
- [x] Nine Gate 0 documents preserved in commit `3425a50` without changing the
      original `main` checkout.
- [x] Historical clean no-space G0-A worktree established with exact recursive
      submodule; current worktree readiness is a separate dispatch preflight.
- [x] GPT-5.6 contract, Android, and iOS audits completed independently.
- [x] Exact Spark selector checked; unavailable and not silently substituted.
- [x] Pinned Node entry point accepted: Node 22.23.1, pnpm 10.34.0, Bash 3.2.57,
      and 13/13 launcher fixtures; clean-commit fast verification passed.
- [x] Independent GPT-5.6 Sol review accepts this packet as a hold-only
      orchestration boundary with no remaining P0/P1 finding.
- [x] Native Debug/Release/ASan baseline recorded by a whole-verifier exit-zero
      rerun: 34/34 Debug/ASan tests, both bridge harnesses, fresh Release compile,
      and both qualification timeout self-tests.
- [x] Native TSan baseline recorded: 22/22 targeted concurrency tests passed.
- [x] Exact cached 0.5B model-backed baseline recorded: SHA/GGUF authentication,
      1/1 required load/generation test with no skip or failure, and the
      mandatory Simulator backend policy check passed on 2026-08-23.
- [x] Clean iOS Simulator app release build recorded from the no-space worktree:
      locked Pods, fresh DerivedData, 115-target generic arm64 build, and clean
      result guard all passed on `2975d61`.
- [x] Existing iOS XCTest/device-SDK and Android generated/prebuild/runtime gaps
      are recorded; Gate 1 owns their foundation, Gates 3A/4A own Android execution.
- [x] The dated August Android installation/build headroom exceeded the 40 GiB
      safety floor and 50 GiB preference; this is not current capacity acceptance.
- [x] Required SDK platform, NDK, CMake, and normal/16 KiB images are installed
      for the macOS arm64 lane; their revisions were recorded using the
      deterministic explicit command-line tools 22.0 path.
- [ ] Assigned Linux/KVM normal/16 KiB x86_64 image revisions are recorded.
- [ ] Physical Android phone and physical iPhone named by reproducible facts.
- [x] Golden contract fixtures/ADRs and authenticated 1.5B facts accepted in
      Gate 0B; no production schema/runtime/ABI activation occurred.
- [ ] Final overall Gate 0 closure review accepted against this remaining-work list.
- [ ] No dependent implementation task is blocked on an unnamed state, version,
      path rule, API, or owner.

Until every required item is checked, Gate 0 remains active and feature work is
not dispatched. The only outstanding Gate 0 evidence is hardware enrollment,
assigned Linux/KVM package installation, and final closure/owner readiness
review. Current dispatch preflight may independently hold a ready gate; it does
not move later implementation evidence back into Gate 0.

## Primary references

- [OpenAI GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model)
- [Codex-Spark focused-edit example](https://learn.chatgpt.com/use-cases/make-granular-ui-changes)
- [Expo SDK 55 reference](https://docs.expo.dev/versions/v55.0.0/)
- [Android Gradle Plugin 8.12 compatibility](https://developer.android.com/build/releases/agp-8-12-0-release-notes)
- [Android 16 KiB page-size guidance](https://developer.android.com/guide/practices/page-sizes)
- [Android native ABI guidance](https://developer.android.com/ndk/guides/abis)
- [Qwen2.5 1.5B Instruct GGUF artifact](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/blob/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf)
