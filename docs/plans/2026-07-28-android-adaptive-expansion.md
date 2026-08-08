# PocketLM Android + adaptive model deployment — build plan

Status: draft for owner approval. No implementation has started.
Plan v3, 2026-07-30. Version history: v1 (scratch draft) revised to v2 after
the first independent planning review (2026-07-28); v2 revised to v3 after the
second independent review
(`2026-07-28-android-adaptive-expansion-review.md`, 2026-07-29). Both
adjudications are recorded at the end of this document. The review documents
themselves are never edited; corrections to them are recorded here.

## Confirmed scope decisions (owner, 2026-07-28)

1. **Adaptive scope** — multi-model tiers plus runtime tuning: the app probes
   the device, recommends which model tier to install, and auto-tunes thread
   count and context size.
2. **Model source** — in-app download with on-device verification, phased
   after an adb-seeded bring-up.
3. **iOS parity** — iOS keeps building and passing its existing suites; the
   catalog/probe/downloader features ship Android-first behind platform gates.
4. **Test target** — physical arm64 phone, CPU-only inference. GPU
   (Vulkan/OpenCL) is out of scope, mirroring the untested-Metal stance on iOS.

## Open decisions the owner must make

- **Which phone.** The exact device model is unknown. RAM-tier thresholds and
  runtime-tuning defaults stay provisional until probed on the real device.
  If the phone uses 16 KB pages, the M6/M9 16 KB gates run on it directly.
- **Top model tier and licensing.** Qwen2.5 0.5B and 1.5B Instruct are
  Apache-2.0. Qwen2.5-3B-Instruct is under the Qwen Research license, not
  Apache. Options: (a) two-tier Apache-only ladder (0.5B + 1.5B) — default;
  (b) add 3B with its research license documented in README/catalog;
  (c) a large third tier from a different family (breaks the
  one-chat-template-family simplification). Plan assumes (a) until decided.

## How much work is this?

Substantial but well-supported by the existing architecture: roughly
**7–11 weeks of focused solo work, ~7–9k new lines including tests**, across
five gated milestones. (Raised from v2's 6–9 weeks / 6–8k lines: the second
review added real scope to M6, M8, and M9 even in the bounded forms adopted
here.) The C++ core and ~95% of the JS layer carry over; the big new
artifacts are the Android bridge + its test harness, the single→multi-model
refactor with manifest migration, and the download/verify subsystem.

## Current-state basis (verified against the repo)

- `cpp/` is a platform-neutral C ABI (`pocketlm_core.h`, C++17, CMake ≥ 3.25)
  over pinned llama.cpp (`45cac7ca7`, gguf-v0.18.0-659). Metal is already
  force-disabled outside iOS builds (`cpp/CMakeLists.txt:57-59`).
- The pinned llama.cpp defaults `BUILD_SHARED_LIBS` to **ON** outside
  Emscripten/MinGW (`third_party/llama.cpp/CMakeLists.txt:54-62`). Only the
  iOS podspec and `scripts/verify-m2-model.sh` pass `OFF` today; the root
  CMake configuration does not enforce it, so host test lanes currently link
  llama shared. Static packaging on Android must be configured, not assumed.
- JS layer (Expo 55, RN 0.83.4) is nearly platform-agnostic; codegen already
  declares `android.javaPackageName: com.pocketlm`, owned by the app package
  and scanning `app/src/lib`. `app/pnpm-workspace.yaml` declares no
  `packages:` globs — a local library package requires workspace changes.
- iOS-only artifacts needing Android counterparts: `PocketLMBridge.mm`
  (1,643 lines), `PocketLMModule.mm` (173), the `withPocketLMPod` config
  plugin, seeding/verification scripts, and the bridge harness
  (`PocketLMBridgeTests`, ~2.3k lines including the 699-line ABI-level
  `FakePocketLMCore.mm`).
- The iOS bridge runs **three** serial execution contexts, not two: a
  lifecycle queue (owner-side fence), an event-delivery queue, and a
  dedicated teardown queue (`com.pocketlm.bridge.teardown`,
  `PocketLMBridge.mm:218`) so blocking `pocketlm_destroy` never stalls
  lifecycle work. The bridge supports a session making progress while another
  is mid-teardown; the JS coordinator serializes to one session at a time.
  Android parity must reproduce the three-context design.
- The inference coordinator hardcodes runtime parameters
  (`coordinator.ts:22` `nThreads: 0`, `:26` `contextSize: 2048`) and its
  dependencies expose only a model-path resolver. Adaptive defaults require a
  coordinator-level integration, not just policy + UI.
- `docs/contracts/INFERENCE_PROTOCOL_V2.md` is normative but contains
  iOS-specific normative text (owner-side fence wording, Objective-C++ module
  registration, iOS storage path). Android conformance requires a versioned,
  platform-neutralizing amendment — scheduled in M6.
- The single-model assumption is load-bearing in three languages, and the
  schema-1 installation manifest is single-select by construction
  (`catalogSchemaVersion: 1`, global `selectedModelId`, `selected: true`,
  validation against `catalog.models[0]` — `storage.ts:11-19,102-129`).
  `catalog.ts` throws unless exactly one model; `pocketlm_model.rb` raises on
  more than one; `fetch-models.sh` deliberately rejects expansion. The
  catalog is embedded for both platforms, so a second entry without the M8
  parser/manifest work would throw on iOS at startup. Single→multi is an
  explicit, shared-code milestone item with a manifest migration (M8).
- Model trust chain (size, SHA-256, GGUF magic/version/metadata,
  chat-template identity, atomic install, catalog-derived manifest,
  backup exclusion) is host-driven today; M9 moves an equivalent chain
  on-device.

## Milestones

Naming continues the existing sequence (m1a, m2, M4/M4R exist). Every
milestone gates on: existing macOS/iOS suites green, implementation log plus
independent verification log under `docs/implementation-logs/<milestone>/`,
and docs updated (ARCHITECTURE, TOOLCHAIN, TROUBLESHOOTING, VALIDATION as
applicable). No future-milestone work lands early.

### M5 — Android toolchain and native core cross-compile

Goal: `pocketlm_core` + llama.cpp build for Android in a deliberate static
configuration; smoke generation runs on a device/emulator.

- Pin in TOOLCHAIN.md and CI: JDK 17 (Temurin), Android SDK platform and
  build-tools, **NDK r28+** (16 KB page alignment default), AGP/Gradle as
  generated by Expo 55 prebuild, and the CI emulator image.
- Decision made now, not in-milestone: **CI emulator lane runs x86_64 AVDs on
  ubuntu/KVM runners** (the repo's Apple-silicon `macos-26` runners cannot
  boot the emulator — no nested virtualization). Consequence: native ABIs are
  `arm64-v8a` (shipping) plus `x86_64` (CI/emulator only; excluded from
  release APKs via per-variant abiFilters).
- **Static packaging enforced at the root**: add `BUILD_SHARED_LIBS OFF` to
  the existing force-cache block in `cpp/CMakeLists.txt` (alongside
  `GGML_METAL`/`LLAMA_BUILD_*`/`LLAMA_CURL`) so every consumer — iOS pod,
  model-test script, both Android paths — inherits it and cannot drift.
  Side effect accepted: host macOS test lanes flip from shared to static
  llama, making all lanes match the shipped link mode; the existing
  suites-stay-green gate verifies this. The now-redundant explicit `OFF`
  flags in the podspec and `verify-m2-model.sh` stay (harmless; removing
  them is out-of-scope churn). `verify-android-native.sh` asserts the
  dynamic `NEEDED` closure of `pocketlm_smoke` (M6 extends the assertion to
  the final JNI `.so`).
- **CPU kernels: dual-variant arm64, runtime-selected.** Android's
  `arm64-v8a` ABI guarantees only Armv8.0; dotprod is optional below v8.4,
  so a single `-march=armv8.2-a+dotprod` library can `SIGILL` on conforming
  budget devices — and neither the x86_64 lane nor arm64 AVDs on
  Apple-silicon hosts (which have dotprod) can catch it. Therefore M5
  produces **two arm64-v8a build configurations of the one native library**:
  an Armv8.0 baseline and an `armv8.2-a+dotprod` variant, both smoke-tested;
  a ~30-line Kotlin CPU-feature probe (M6) picks which to `System.loadLibrary`
  at startup. `-march` flags are scoped to arm64-v8a only, never x86_64.
  Multi-variant dispatch via `GGML_CPU_ALL_VARIANTS` remains rejected (it
  hard-requires `GGML_BACKEND_DL` dlopen packaging) and is recorded as the
  deep-fallback remediation. An i8mm third variant is a documented deferral.
- 16 KB scope in M5: assert alignment on the `pocketlm_smoke` executable
  only — static archives have no meaningful `LOAD` alignment. APK-level
  gates land in M6/M9 where packaged `.so` files exist.
- `verify-android-native.sh` overall: configure/build all variants, assert
  CPU-only in the configure log (no Metal/Vulkan/OpenCL/BLAS), assert static
  closure, push the 491 MB model to `/data/local/tmp` and run
  `pocketlm_smoke` (both arm64 variants where hardware allows) via adb, run
  Catch2 suites on-Android where practical (document which remain
  host-only).
- CI lane `android-native`. TOOLCHAIN.md documents the Android
  checkout-path-with-spaces stance explicitly.
- Estimate: 3–5 days. Risk: low-moderate.

### M6 — Android bridge: Kotlin TurboModule + JNI adapter (protocol parity)

Goal: the app runs on the Android emulator with a fixture-seeded model; chat,
cancel, regenerate, and unload satisfy the amended Inference Protocol v2.
Largest single port item.

- **Packaging and codegen ownership, decided now**: the bridge ships as a
  local autolinked RN library (workspace package with its own `android/`,
  `build.gradle`, and CMake `externalNativeBuild` into `cpp/`).
  `NativePocketLM.ts` **and its `codegenConfig` move into the library** so
  codegen has exactly one owner; `app/pnpm-workspace.yaml` gains the
  `packages:` glob and the app depends on the workspace package;
  `app/src/lib/NativePocketLM.ts` becomes a re-export shim so existing
  imports and jest suites do not churn; the iOS pod must consume the
  library-generated `PocketLMSpec` header unchanged. Acceptance gate: **two
  consecutive clean prebuilds produce exactly one registered `PocketLM`
  module** (and one generated spec) on each platform. (Fallback if
  autolinking cannot wire the CMake path: minimal config plugin — documented
  trade, decided inside M6.)
- **JNI adapter with the full ownership contract**, mirroring the iOS
  three-context design:
  - lifecycle `HandlerThread` (owner-side fence): validates, copies, calls
    the C ABI, detaches handles;
  - **dedicated teardown executor**: after the lifecycle thread detaches the
    raw handle, blocking `pocketlm_destroy` (cancel → join-before-free) runs
    here so lifecycle work continues for other sessions; terminal flush then
    promise resolution ordering preserved;
  - serial event-delivery executor; payload copies before crossing threads;
    JS delivery deferred until `generate()` returns; coalescing
    (4,096-byte / 16 ms bounds) without splitting fragments or crossing a
    request boundary; token index/tokenCount bookkeeping;
  - **explicit JNI rules**: core callbacks arrive on native worker threads —
    no `JNIEnv*` or local references reused across threads; `JavaVM`-based
    attach/detach policy for callback threads; global references for Java
    objects retained across callbacks; pending-exception checks at every
    boundary;
  - **byte-array string boundary**: fragment payloads cross JNI as UTF-8
    byte arrays decoded in Kotlin — never `NewStringUTF`/`GetStringUTFChars`,
    whose Modified UTF-8 breaks strict-UTF-8 supplementary characters
    (emoji) that the protocol and the existing 100-run encoding suite
    guarantee.
- Kotlin TurboModule implementing codegen `PocketLMSpec` exactly (same
  synchronous negative-rejection mapping, identical `onInferenceEvent`
  payload). Subscriber mechanics re-derived from `addListener`/
  `removeListeners` counting (Android has no `startObserving`/
  `stopObserving`), replicating token-guarded invalidation and reload
  behavior of `PocketLMModule.mm`. Startup loads the correct arm64 kernel
  variant via the CPU-feature probe (from M5's dual build).
- **Android model storage layout defined here** (internal
  `filesDir/PocketLM/Models/<appDirectoryName>/model.gguf`; internal storage
  chosen over app-external so the verified boundary is not user-writable via
  MTP) and `storage.ts`'s iOS-only path derivation platform-gated.
- **Protocol amendment (versioned)**: platform-neutral owner-side-fence
  wording, Android module registration, Android storage boundary. M6
  acceptance gates on the amended document.
- **Minimal deterministic seed fixture** (moved from M7 so M6's exit does not
  depend on an M7 deliverable): scripted push + `run-as` + manifest write for
  debug builds, exact commands checked in — no undocumented manual adb steps
  in the acceptance path. M7 hardens this into the full verified seeder.
- App config: `android` block (package `com.pocketlm.app`), `platforms`
  extended, backup rules XML (`dataExtractionRules`/`fullBackupContent`)
  excluding the model directory (config scaffolding here; verification
  semantics land in M7). Verify the Sentry Expo plugin's Android wiring
  no-ops without DSN/token, extending the existing no-DSN test pattern.
- **16 KB APK gate**: extract and check alignment of every packaged `.so`
  (including RN, Hermes, Sentry prebuilts) and run `zipalign -c -P 16 -v 4`
  on the assembled debug APK.
- **Bridge harness parity**: port the ABI-level fake (`FakePocketLMCore.mm`,
  699 lines) to portable C++ (budgeted work — the C++ `fake_backend` fakes
  inside the core, globally replaces `operator new`, and cannot produce
  contract-fault scenarios). Instrumented androidTest lane, run under
  **CheckJNI**, covering: event ordering; coalescing invariants (assert
  no-split/no-cross-boundary/contiguity, not timing); unload fencing during
  active decode; gap handling; synchronous rejections; no-event-after-
  destroy; module reload; emoji/supplementary and malformed-surrogate
  payloads through the byte-array boundary; and a **bridge-contract
  concurrency test** — one session making progress while another blocks in
  destroy on the teardown executor. (Framing per second-review nit 2: the JS
  app serializes to one session today; this tests the bridge contract that
  iOS's teardown queue already provides, and becomes load-bearing at M8.)
- JS: remove `platforms: ['ios']`; protocol layer unchanged (existing jest
  suites prove it).
- Estimate: 2.5–3.5 weeks. Risk: highest in the plan — concurrency,
  lifecycle, and JNI subtleties; mitigated by the instrumented harness and
  CheckJNI, not by assumption.

### M7 — Android model provisioning parity (host-driven)

Goal: dev-provisioned demo on the physical phone.

- Harden the M6 fixture into `scripts/seed-android-model.sh`: re-verify
  cached GGUF → **`am force-stop` the app before replacement** (no native
  session may hold the file) → `adb push` + `run-as` into the internal
  layout → partial file → re-verify → atomic rename → catalog-derived
  manifest. `run-as` limits seeding to debug builds — acceptable: this is
  the dev path; release-build demo arrives with M9.
- Backup-exclusion semantics fork, documented: iOS checks a per-file
  attribute; Android asserts the backup-rules resource in the built APK
  excludes the model directory (build-time check), and the manifest field's
  Android meaning is defined accordingly in the protocol amendment.
- Provisioning shell tests extended with a fake `adb` (existing fake
  `xcrun`/`curl` pattern). Emulator boot + seed + launch smoke folded into
  CI where lane time allows.
- Estimate: 2–4 days. Risk: low.

### M8 — Multi-model catalog, device probe, adaptive defaults

Goal: the "based on device performance" story, still host-seeded — wired
into inference, not display-only.

- **Single→multi refactor across all three languages, shipped compatibly for
  iOS in the same milestone**: `catalog.ts` tuple/length guard → N-entry
  parser with unique-ID/directory/path validation; `storage.ts`/
  ModelContext/models screen; jest suites; `pocketlm_model.rb` exactly-one
  raise → model-id addressing (TSV protocol and shell consumers);
  `fetch-models.sh`/seeders gain `--model-id`.
- **Persistence redesign + migration** (schema-1 manifest is single-select
  by construction): separate **immutable per-model installation records**
  from a **selected-model preference**; atomic schema v1→v2 migration that
  preserves the existing floor-model installation (iOS and any dev devices);
  downgrade policy defined as documented non-support — an unknown/newer
  manifest version is treated as not-installed and triggers re-verification
  (one guard clause, no rollback machinery); defined selection fallback when
  the selected model is missing, invalid, or deleted.
- Catalog v2 entries, in-family: Qwen2.5-Instruct 0.5B Q4_K_M (existing
  floor) + 1.5B Q4_K_M (**1.12 GB** per the official repository; v2's
  ~940 MB figure was the Q3_K_M artifact), each fully pinned (revision,
  exact byte size, SHA-256, metadata, license); 3B pending the licensing
  decision. Per-model `minTotalRamBytes` / `recommendedRamBytes`.
- **Coordinator integration** (closes the display-only gap): a
  runtime-config resolver joins the coordinator's injected dependencies,
  replacing the hardcoded `contextSize: 2048` / `nThreads: 0`; model or
  context-size changes run through a defined **awaited switch transaction**
  (cancel → await `unloadModel` → load), with app-level switching **strictly
  serialized** — the bridge supports load-during-teardown (proven by the M6
  contract test), but the app policy avoids transient two-model residency on
  small-RAM devices.
- **Mutation fence starts here**: per-model install/load/switch lock ordered
  against native session ownership; defined failed-unload behavior. (M9
  extends the same lock to delete/replace.)
- **Device probe = static facts only** for tier choice: a tiny Android-only
  native module (`PocketLMDeviceProbe`, ~100 lines Kotlin: total RAM,
  `isLowRamDevice`, core count **plus per-core cpufreq max for cluster
  topology** — thread defaults come from the performance-cluster size, not
  raw core count), accessed via `TurboModuleRegistry.get` with a null gate
  on iOS. The frozen `PocketLMSpec` is untouched.
- Recommendation policy as pure, unit-tested JS with **defined formulas,
  caps, byte units, and boundary test vectors**. Provisional thresholds
  (tunable once the phone is known): < 6 GB → 0.5B; ≥ 6 GB → 1.5B; 3B tier
  decided with its licensing. Guardrails: never auto-select a model whose
  `minTotalRamBytes` exceeds device RAM; warn on borderline (LMK-kill risk).
  **No auto-retuning**: measured decode tok/s and the existing
  `peakRssBytes` diagnostic feed display and a tier-fit warning only —
  defaults come from static heuristics plus manual override, so sample
  eligibility, hysteresis, and persisted calibration state are moot by
  construction. Observed peak working set on the demo phone is recorded in
  VALIDATION.md.
- Models screen UX: probe results, recommendation, user override, per-model
  install state.
- Estimate: 2–2.5 weeks. Risk: moderate.

### M9 — In-app download and on-device verified install (demo exit criterion)

Goal: clean APK install on an arm64 phone → probe → download recommended
model → verified install → chat.

- **Downloader: foreground `dataSync` service** (kept over a user-initiated
  data-transfer job — UIDT is API 34+ only and would force a second
  implementation for older devices; the user is watching a progress bar, so
  JobScheduler indirection buys nothing). Full compliance checklist is in
  scope: `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` permissions,
  manifest and runtime service type, visible-state start restriction,
  `POST_NOTIFICATIONS` behavior on Android 13+ (service runs even if the
  notification is suppressed), Android 15's ~6-hour dataSync quota and
  `onTimeout` callback (a non-issue for minutes-long downloads, but handled
  and tested), forced-timeout and Doze tests. OkHttp streaming with HTTP
  Range resume; storage-space preflight; cancel/pause/resume UX. No
  Wi-Fi-only toggle (cut as scope).
- **Durable, authoritative download state** (progress events are UI sugar,
  never the source of truth — the service outlives the React instance):
  a persisted record of model identity, expected size/hash, partial length,
  URL, and HTTP validators (ETag/Last-Modified), plus a **query/snapshot
  API** the UI reads on mount/reload.
- **Resume correctness**: request with `Range` + `If-Range`; accept only an
  exact-match `206 Content-Range`; on `200` (server ignored Range), `416`,
  validator mismatch, or a stale/undersized/oversized partial, discard and
  restart cleanly. **Hash authority = the complete, closed partial file
  hashed before promotion** (a ≤1.2 GB sequential read — seconds on modern
  flash); incremental digests are dropped as authority, which removes the
  process-death hash-state problem entirely. Tests: activity recreation,
  React reload, service restart, process death mid-download, server-ignored
  Range, corrupted existing prefix.
- **Verifier ABI, fixed signature**: `pocketlm_verify_model` returns
  **bounded, typed GGUF inspection facts** (GGUF version, architecture,
  file type, tokenizer model/pre, chat template up to a documented cap) and
  Kotlin compares them against the selected embedded catalog entry —
  a path-only checker cannot know catalog expectations, and pushing
  expectation parsing into the frozen C ABI couples it to the catalog
  schema. Still a **frozen-ABI change**: ABI version bump, header-compile
  tests, Catch2 coverage (including a **structurally valid GGUF with wrong
  metadata/chat template**, not just truncated/corrupted bytes), protocol
  note — all inside M9.
- **Fenced mutation + recoverable publication**: install/delete/replace run
  under the M8 per-model lock, ordered against session ownership; deleting
  or replacing a loaded model requires cancel + awaited `unloadModel` first;
  partial → verified → atomic rename → manifest write with a **commit
  marker (manifest-last ordering) and a startup-repair pass** (final model
  present without manifest → re-verify and adopt, or quarantine); re-verify
  on launch. Crash coverage via **targeted process-kill tests at the rename
  and manifest-write boundaries** plus the startup-repair invariant (no
  generic fsync fault-injection framework — two crash windows do not
  justify interposition infrastructure).
- Model management UI: delete models, disk usage, free-space guardrails.
- Release path: signed APK (local keystore) for sideload; **release 16 KB
  gate** re-runs the per-`.so` + `zipalign -c -P 16` checks on the release
  APK, verifies release ABI contents (arm64 variants only, no x86_64), and
  runs on a 16 KB system image (the owner's phone if it uses 16 KB pages,
  otherwise the 16 KB emulator image). Play Store stays out of scope,
  mirroring the iOS distribution stance.
- Estimate: 2–3 weeks. Risk: moderate-high (background/download edge cases
  across Android versions and OEMs).

### M10 — stretch, explicitly deferred

iOS parity for probe/catalog/downloader (URLSession background downloads);
GPU-lane experiment (never a demo dependency); thermal/battery observations
in VALIDATION.md; Sentry Android ingestion verification.

## Effort summary

| Milestone | Estimate | Risk |
| --- | --- | --- |
| M5 toolchain + native | 3–5 days | low-moderate |
| M6 bridge + harness | 2.5–3.5 weeks | high |
| M7 provisioning | 2–4 days | low |
| M8 catalog + probe + integration | 2–2.5 weeks | moderate |
| M9 download + verify | 2–3 weeks | moderate-high |
| **Total to demo** | **≈ 7–11 weeks** | |

New code, rough order: bridge + JNI + harness ~3.5–4.5k lines; multi-model
refactor + migration + probe + policy + UI ~1.5–2k; downloader +
verification + failure matrix ~1.5–2k; build/scripts/CI ~0.5k.
**≈ 7–9k lines including tests**, excluding docs.

## Risk register

1. Owner's phone unknown → provisional tier thresholds; 16 KB on-device
   gate target unknown (open decision).
2. Qwen2.5-3B research license → tier-ladder decision (open decision).
3. Android event-emission timing vs the deferred-delivery guarantee — proven
   by instrumented tests, never assumed.
4. Shared embedded catalog + schema-1 manifest break iOS at startup if
   multi-model entries land before the M8 parser/migration work — ordering
   is load-bearing.
5. Kernel-variant loader mis-selection would `SIGILL` — mitigated by a
   debug override to force the baseline variant and a smoke test of both
   variants; deep fallback remains the `GGML_BACKEND_DL` packaging redesign
   (explicitly deferred).
6. Emulator CI lane slippage would silently degrade M6 verification to
   physical-device-only — if it happens, that trade must be recorded in the
   verification log, not absorbed.
7. Large-model decode working set vs Android LMK on 6 GB devices → policy
   guardrails + user warning; observed peak RSS recorded in VALIDATION.md.
8. OEM battery managers killing downloads → compliant foreground service +
   durable resume; residual risk documented.
9. Hugging Face availability/rate limits → Range resume mitigates.

## Planning-review adjudication 1 (v1 → v2, review of 2026-07-28)

Adopted: protocol amendment as an M6 deliverable (v1 wrongly claimed the
protocol could stay unchanged); NDK r28+ pin (v1 said r27+, which does not
default 16 KB alignment); upfront CPU-kernel decision (v1 implied runtime
dispatch was free; it requires `GGML_BACKEND_DL` packaging); CI emulator
decision moved into M5 with x86_64 tied to it; ABI-fake port budgeted in M6
(v1 wrongly pointed at `fake_backend`, which is unsafe and insufficient for
contract-fault tests); dropped the M4-runner-as-probe idea for static probe +
DONE-stats display; single→multi-model refactor promoted to the headline M8
item across three languages with iOS compatibility in the same milestone;
Android storage layout + subscriber-mechanics re-derivation +
`am force-stop` seeding + backup-rules semantics fork + Sentry-Android no-op
check added; `pocketlm_verify_model` scoped as a frozen-ABI change; Wi-Fi
toggle cut; foreground service chosen over WorkManager; local autolinked
library chosen over a Gradle-patching config plugin; M6/M8 estimates raised.
Rejected, with reasons: system `DownloadManager` (weaker
progress/verification integration than OkHttp streaming); Kotlin GGUF header
reader instead of the C ABI verifier (C route shares semantics with the
loader and is reusable on iOS); multi-variant CPU dispatch now (packaging
scope creep; recorded as remediation path); moving backup-rules XML out of
M6 (config scaffolding created once; verification semantics land in M7).

## Planning-review adjudication 2 (v2 → v3, review of 2026-07-29)

All twelve findings' diagnoses were verified against the code (and the 1.5B
artifact size against the official Hugging Face repository) and accepted.
Eight findings applied as prescribed, choosing among offered corrections:

- **F1 (arm64 baseline)**: adopted the baseline-plus-probed-dispatch option
  as dual arm64 build variants with a runtime CPU-feature loader; `-march`
  scoped to arm64-v8a only. Pure Armv8.0 rejected (loses the dotprod
  speedup that carries the performance story); probe-confirmed-device-only
  rejected (breaks the sideload demo).
- **F2 (static packaging)**: adopted, upgraded per nit 1 below to a single
  root-level `BUILD_SHARED_LIBS OFF` force instead of per-consumer flags;
  `NEEDED`-closure assertions added.
- **F3 (16 KB on APK)**: adopted — M5 checks the smoke executable only; APK
  gates at M6 (debug) and M9 (release + 16 KB image run).
- **F4 (M6/M7 ordering)**: adopted — minimal deterministic seed fixture
  moved into M6; M7 hardens it.
- **F5 (codegen ownership)**: adopted — spec + codegenConfig move to the
  library, workspace glob + re-export shim, double-clean-prebuild /
  single-registered-module gate verbatim.
- **F6 (JNI/teardown contract)**: adopted — dedicated teardown executor
  (parity with the verified iOS teardown queue), JavaVM attach/detach and
  global-reference rules, byte-array UTF-8 boundary (never
  `NewStringUTF`), CheckJNI stress lane including the concurrency contract
  test.
- **F8 (1.5B size)**: adopted — 1.12 GB (v2's ~940 MB was the Q3_K_M
  artifact); downstream storage/download framing corrected.
- **F11 (verifier signature)**: adopted the inspection-facts-out option —
  bounded typed GGUF facts compared in Kotlin against the embedded catalog
  entry; wrong-metadata-valid-GGUF test added. Descriptor-in rejected
  (couples the frozen ABI to catalog schema).

Four findings applied with bounded remedies; the rejected sub-parts and
reasons:

- **F7 (persistence/migration)**: per-model records, selection preference,
  atomic v1→v2 migration, uniqueness validation, and selection fallback all
  adopted. Rollback *machinery* rejected — downgrade is defined as
  documented non-support (newer/unknown manifest ⇒ not-installed ⇒
  re-verify): code that could never execute in this project's lifecycle and
  a needless compatibility matrix.
- **F9 (adaptive integration)**: coordinator runtime-config dependency,
  awaited switch transaction, formulas/caps/units/test vectors, and cluster
  topology all adopted. Auto-retuning machinery rejected (sample
  eligibility, hysteresis, persisted calibration, working-set-gated
  calibration): tuning from noisy, thermally confounded samples on unknown
  OEM devices can oscillate or worsen defaults, and it adds a state machine
  plus device-dependent flaky tests for value invisible in a demo. Measured
  tok/s and `peakRssBytes` are display + tier-fit warning only.
- **F10 (download recovery)**: durable authoritative state, snapshot API,
  strict 206/200/416/validator handling, and the full FGS `dataSync`
  compliance checklist adopted; hash authority moved to the closed partial
  before promotion (the review's own offered alternative), which removes
  the incremental-digest durability problem outright. Switching to a
  user-initiated data-transfer job rejected: API 34+ only (forces a second
  path for older devices), scheduling indirection for an attended flow, no
  reliability gain over a compliant FGS.
- **F12 (mutation fencing)**: per-model lock ordered against session
  ownership, awaited-unload-before-mutate, commit marker + startup repair
  all adopted (fence begins at M8 switching, extends to M9
  delete/replace). Blanket fault-injection around every rename/manifest
  write/fsync rejected: two crash windows are covered by targeted
  process-kill tests plus the startup-repair invariant; an fsync
  interposition harness in instrumented tests is disproportionate
  infrastructure.

Nits raised against the review itself (the review file is left untouched;
corrections live here per the two-log integrity rule):

- **Nit 1**: F2 said only the iOS pod passes `BUILD_SHARED_LIBS=OFF`;
  `scripts/verify-m2-model.sh:102` does too. Immaterial to the conclusion —
  and it motivated the stronger remedy: force the value once at the root so
  per-consumer flags cannot drift (host lanes deliberately flip to static,
  matching shipped link mode; redundant explicit flags left in place).
- **Nit 2**: F6's "another session making progress while destroy is
  blocked" over-implies current app behavior — the JS coordinator
  serializes to one session today. The test is kept, reframed as a
  bridge-contract test justified by the iOS teardown queue's actual design
  and by M8 switching; the app-level policy is explicitly strict
  serialization (bridge proves the stronger contract, app ships the simpler
  policy).

Estimates raised: M5 3–5 days, M6 2.5–3.5 weeks, M8 2–2.5 weeks, M9 2–3
weeks; total ≈ 7–11 weeks, ~7–9k lines including tests.
