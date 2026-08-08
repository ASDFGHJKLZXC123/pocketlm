# Review: PocketLM Android + adaptive model deployment build plan

Review date: 2026-07-29  
Reviewed document: `2026-07-28-android-adaptive-expansion.md` (plan v2)  
Disposition: **revision required before owner approval**

Priority meanings:

- **P1** — design blocker that can invalidate milestone acceptance, cause a
  runtime crash/corruption, or leave the central feature unimplemented.
- **P2** — material planning gap that should be added to the applicable
  milestone's acceptance criteria before implementation begins.

## Findings

### 1. P1 — `armv8.2-a+dotprod` is not an `arm64-v8a` baseline

Plan lines 89–94 choose a single shipping baseline of
`-march=armv8.2-a+dotprod`, although the exact phone is still unknown.
Android's `arm64-v8a` ABI guarantees Armv8.0, not the optional Armv8.2
dot-product extension. A conforming device can therefore install the APK and
then encounter `SIGILL`. The x86_64 emulator lane cannot detect that failure.

Required correction:

- Build the shipping library for an Armv8.0 baseline; or
- explicitly limit the demo to a probe-confirmed device and make an arm64
  physical-device smoke test an M5 exit gate; or
- provide a baseline implementation plus feature-probed optimized dispatch.

The compile option must also be scoped to `arm64-v8a`, never the x86_64 build.

Reference: [Android ABI documentation](https://developer.android.com/ndk/guides/abis#arm64-v8a).

### 2. P1 — Static packaging is assumed but not configured

Plan lines 91–94 reject llama.cpp's multi-variant dispatch because PocketLM
uses a “current single static-link model.” That assumption is not true for the
root CMake configuration by default:

- `cpp/CMakeLists.txt` makes `pocketlm_core` itself static.
- The pinned `cpp/third_party/llama.cpp/CMakeLists.txt` defaults
  `BUILD_SHARED_LIBS` to `ON` outside MinGW/Emscripten.
- Only the iOS pod build currently passes `-DBUILD_SHARED_LIBS=OFF`.

Required correction:

- Pin `-DBUILD_SHARED_LIBS=OFF` in both the standalone Android build and the
  Gradle `externalNativeBuild` configuration.
- Assert the dynamic dependency closure of `pocketlm_smoke` and the final JNI
  `.so`.

Without this, the smoke executable and JNI library can depend on additional
shared libraries, and the stated packaging rationale for rejecting runtime CPU
variants no longer holds.

### 3. P2 — Validate 16 KB compatibility on the assembled APK

Plan lines 95–97 put a 16 KB alignment assertion in M5, before the final JNI
library or APK exists. Under the intended static build, the core and llama/ggml
outputs are archives; ELF `LOAD` segment alignment is not meaningful for those
archives.

Required correction:

- Retain any useful M5 check on `pocketlm_smoke`.
- Add an M6 and release/M9 gate that:
  - extracts and checks every packaged `.so`, including React Native, Hermes,
    Sentry, and other prebuilts;
  - runs `zipalign -c -P 16 -v 4` on the assembled APK;
  - verifies release ABI contents; and
  - runs on a 16 KB system image whenever the selected physical target uses
    16 KB pages.

Deferring all on-device proof to M10 is unsafe while the demo phone is unknown.

Reference: [Android 16 KB page-size guidance](https://developer.android.com/guide/practices/page-sizes).

### 4. P2 — M6's exit criterion depends on an M7 deliverable

Plan lines 106–109 require model-backed chat from the emulator using an
adb-seeded model. The repeatable seeder for the app's internal `filesDir`
layout is not delivered until M7, while the global rules say no
future-milestone work lands early.

Required correction:

- Move a minimal deterministic debug seeding fixture into M6; or
- define another exact, automated M6 provisioning route.

The M6 acceptance path should not rely on undocumented manual `adb` commands.

### 5. P2 — Codegen ownership is unresolved

Plan lines 112–118 give the proposed local React Native library its own codegen
configuration, but the app package currently owns `PocketLMSpec` codegen and
scans `app/src/lib`. The current `app/pnpm-workspace.yaml` also declares no
package globs.

Required correction:

- State whether `NativePocketLM.ts` and its codegen configuration move into the
  library or remain app-owned.
- Add the workspace package declaration and application dependency.
- Define any re-export needed by existing JavaScript imports.
- Preserve the iOS-generated `PocketLMSpec` header and registration.
- Gate M6 on two consecutive clean prebuilds producing exactly one registered
  `PocketLM` module.

### 6. P1 — The JNI and teardown ownership contract is incomplete

Plan lines 119–126 name a lifecycle `HandlerThread` and a delivery executor,
but current bridge parity needs an additional teardown execution path. The iOS
bridge detaches the raw handle on its lifecycle queue, then performs blocking
`pocketlm_destroy` on a dedicated teardown queue so lifecycle work for other
sessions can continue.

The JNI boundary also needs explicit ownership rules:

- Core callbacks run on native worker threads and cannot reuse a `JNIEnv*` or
  local references captured by `generate()`.
- Java objects retained across callbacks require global references.
- Native callback threads require a `JavaVM`-based attach/detach policy.
- `GetStringUTFChars` and `NewStringUTF` use Modified UTF-8, while the protocol
  requires standard, strict UTF-8. Supplementary characters such as emoji need
  an explicit UTF-16-to-UTF-8 path or a byte-array boundary.

Required correction:

- Specify a dedicated teardown executor, handle-detachment ordering,
  `JavaVM`/global-reference ownership, callback-thread attachment, exception
  checks, and strict string conversion.
- Add CheckJNI stress tests for emoji/supplementary characters, malformed
  surrogates, unload during decode, module reload, and another session making
  progress while destroy is blocked.

Reference: [Android JNI guidance](https://developer.android.com/ndk/guides/jni-tips#utf_8_and_utf_16_strings).

### 7. P1 — Multi-model persistence and migration are unspecified

Plan lines 184–194 introduce Catalog v2 while promising compatible iOS
behavior. The current schema-1 installation manifest:

- embeds `catalogSchemaVersion: 1`;
- contains a global `selectedModelId`;
- marks its one model `selected: true`; and
- validates only against `catalog.models[0]`.

Changing to Catalog v2 would invalidate the existing floor-model installation.
Separate per-model manifests also cannot each be the authoritative global
selection record.

Required correction:

- Separate immutable per-model installation records from the selected-model
  preference.
- Define an atomic schema-v1 migration that preserves the existing iOS floor
  installation.
- Define downgrade/rollback behavior.
- Validate unique model IDs, directory names, and installed paths.
- Define selection behavior when the selected model is missing, invalid, or
  deleted.

### 8. P2 — The Qwen2.5 1.5B Q4_K_M size is wrong

Plan lines 191–194 estimate the Q4_K_M artifact at approximately 940 MB. The
official repository reports approximately **1.12 GB** for Q4_K_M; roughly
924 MB corresponds to Q3_K_M.

Required correction:

- Replace the estimate before deriving download-time, storage-preflight,
  working-set, and RAM-tier assumptions.
- Continue to pin the final catalog entry to an exact byte size and SHA-256.

Reference: [Qwen2.5-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF).

### 9. P1 — Adaptive defaults have no integration path into inference

Plan lines 196–209 define a recommendation policy and adaptive runtime
defaults, but the current inference coordinator hardcodes:

- `contextSize: 2048`; and
- `nThreads: 0`.

Its dependencies expose only a model-path resolver, not a runtime-config
resolver. The listed M8 changes cover the catalog, storage, `ModelContext`,
policy, and UI, but not the coordinator/runtime integration. The feature can
therefore become display-only.

There are also policy-definition gaps:

- The proposed probe returns core count, not performance/efficiency core
  topology.
- One observed tok/s value at one thread count cannot identify a better thread
  count.
- Changing context size or model requires an awaited unload/reload.
- Total RAM alone does not establish LMK-safe working-set headroom.

Required correction:

- Add a runtime-config dependency to the coordinator.
- Define formulas, caps, byte units, persistence, hysteresis, and boundary test
  vectors.
- Define which DONE samples are eligible to tune a default.
- Define the awaited transaction used when model or context changes.
- Gate calibration on physical-device peak working set plus an explicit safety
  margin.

### 10. P1 — Download recovery is neither durable nor authoritative

Plan lines 220–237 combine Range resume, incremental `MessageDigest`, progress
events to JavaScript, and process-kill recovery.

Those pieces are insufficient as written:

- `MessageDigest` state is lost when the process dies. Hashing only the resumed
  response authenticates the suffix, not the existing partial prefix.
- A service can outlive the React instance, so progress events may be lost and
  cannot be the source of truth for restored UI.
- Resume must distinguish a valid `206` response from a server that ignores
  Range and returns `200`, a `416`, a shifted `Content-Range`, or a changed
  representation.

Required correction:

- Persist an authoritative download state containing model identity, expected
  size/hash, partial length, URL, and validators.
- Expose a query/snapshot API in addition to progress events.
- Rehash the existing partial before appending, or hash the complete closed
  partial before promotion.
- Validate exact `206 Content-Range` and `If-Range` semantics.
- Restart safely on `200`, `416`, validator mismatch, or a stale partial.
- Test activity recreation, React reload, service restart, process death,
  server-ignored Range, and corrupted existing prefixes.

The background-execution decision is also an incomplete comparison. Current
Android guidance selects a user-initiated data-transfer job for a
user-triggered, immediately needed large download on API 34+. If a direct
`dataSync` foreground service remains the choice, the plan must include:

- `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_DATA_SYNC`;
- the manifest and runtime service type;
- visible-state start restrictions;
- Android 13 notification-permission behavior;
- Android 15's timeout callback and six-hour quota; and
- forced-timeout/Doze tests.

Reference: [Android data-transfer guidance](https://developer.android.com/develop/background-work/background-tasks/data-transfer-options).

### 11. P1 — A path-only verifier cannot check catalog identity

Plan lines 226–233 describe a frozen ABI function
`pocketlm_verify_model(path)` with the same semantics as `verify-model.rb`.
That signature cannot provide the claimed semantics:

- The Ruby verifier receives the catalog.
- It compares expected byte size, SHA-256, GGUF version, required metadata
  values, and chat-template requirements.
- A path-only native function has neither those expectations nor a declared
  inspection result for Kotlin to compare.
- M8 introduces multiple valid model identities.

Required correction before freezing the ABI:

- Accept a bounded expected-verification descriptor; or
- return bounded, typed GGUF inspection facts for Kotlin to compare with the
  selected embedded catalog entry; or
- explicitly define and test a native catalog-embedding mechanism.

Tests must include a structurally valid GGUF with the wrong metadata or chat
template, not only truncated and byte-corrupted files.

### 12. P1 — Model mutation is not fenced and publication is not recoverable

Plan lines 234–237 add model replacement and deletion without serializing those
operations with the process-lifetime native inference session.

Failure cases include:

- UI selection changes to model B while chat still owns a session for model A.
- Deletion or replacement unlinks a model that remains mmap-backed by a live
  session.
- Install/delete/load operations race with one another.
- Process death after the verified model rename but before manifest publication
  leaves a valid final model without its manifest.

Required correction:

- Serialize model mutation with native session ownership.
- Cancel and await `unloadModel` before replacing or deleting a selected or
  loaded model.
- Use a per-model install/delete/load lock.
- Define failed-unload behavior.
- Use a staged-directory commit, commit marker, or verified startup-repair
  protocol for the model/manifest pair.
- Fault-inject before and after every rename, manifest write, and required
  `fsync`.

## Approval recommendation

Revise the plan before approval. In particular, resolve the eight P1 findings
in the design itself rather than leaving them for milestone-time discovery.
The four P2 findings should become explicit milestone deliverables and
acceptance gates.

This review made no implementation changes.
