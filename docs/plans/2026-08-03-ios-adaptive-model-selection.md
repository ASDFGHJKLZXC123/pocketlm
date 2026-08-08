# iOS adaptive model selection — build plan (three tiers)

Status: draft for owner approval. No implementation has started.
Plan v2, 2026-08-03. Version history: v1 revised to v2 after the independent
planning review (`2026-08-03-ios-adaptive-model-selection-review.md`,
Fable 5, 2026-08-03). The adjudication is recorded at the end of this document.
The review document itself is never edited; corrections to it live here.

Addendum to `2026-07-28-android-adaptive-expansion.md` (v3). That plan delivers
the same capability **Android-first** and places "iOS parity for probe /
catalog / downloader" in **M10 — stretch, explicitly deferred**. This document
specifies the deferred iOS side and nothing else. Where the Android plan
already decides something shared, this plan inherits the decision rather than
re-litigating it.

## What the user gets

The user opens PocketLM, sees which models their device can plausibly run,
picks one, downloads it in-app, and chats — instead of running a host shell
script to seed a single hard-pinned 491 MB model.

## Owner decisions (2026-08-03)

1. **Capability signal is advisory, not gating.** Validated on Simulator with
   injected probe values. No physical-device accuracy claim. Rationale: on
   Simulator `NSProcessInfo.physicalMemory` reports the **host Mac's** RAM, and
   `os_proc_available_memory()` returns **0** because the jetsam budget does
   not exist there. Both of this feature's inputs are structurally wrong in the
   only environment this project tests, so a hard gate could never be honestly
   validated.
2. **Lean single document.** No gate/owner/reviewer apparatus; per-milestone
   implementation log plus independent verification log, matching the Android
   plan's convention.
3. **Model set: phased.** Qwen2.5-Instruct sizes first (proves the plumbing
   with the chat-template pins intact), cross-family second.

## The one structural decision the owner still owes

**Is Android actually being built, or is iOS now the target?**

Tier 1 (multi-model) is *not* iOS-specific work — it is the Android plan's
**M8** headline item, which already ships the single→multi refactor
"compatibly for iOS in the same milestone" (shared `catalog.ts`, `storage.ts`,
`ModelContext`, models screen, jest suites, `pocketlm_model.rb`,
`fetch-models.sh`, plus the schema v1→v2 manifest migration).

- **If Android proceeds**: this plan starts after M8 and inherits the refactor,
  the recommendation-policy JS, the runtime-config resolver, the per-model
  mutation lock, and `pocketlm_verify_model` for free. iOS-A and iOS-B below
  are the only new work.
- **If Android is dropped**: two lifts become prerequisites, and they attach to
  different milestones —
  - **iOS-0a**, M8's shared portion (nearly all of M8; only the ~100-line
    Kotlin probe and Android UI glue drop out), blocks **iOS-A**: ~2–2.5 weeks.
  - **iOS-0b**, M9's `pocketlm_verify_model` ABI addition — version bump,
    header-compile tests, Catch2 coverage including a structurally-valid
    wrong-metadata GGUF fixture — blocks **iOS-B only**, not iOS-A: ~3–5 days.

  The Android plan's M5/M6/M7 (toolchain, JNI bridge, adb seeding) are then
  dropped entirely, and the M6 protocol amendment shrinks to the
  storage-boundary and in-app-publication clauses.

Estimates below assume Android proceeds.

## Current state, verified against the tree (2026-08-03, `6f9de4a`)

Every citation in this section was independently re-checked during review and
held.

- Single-model assumption is load-bearing in JS and Ruby:
  `catalog.ts:39` types `models` as a **1-tuple**, `:112-113` throws
  `'PocketLM requires exactly one catalog model.'`, `:195` returns `models[0]`;
  `pocketlm_model.rb:273-274` raises on more than one.
- The installation manifest is **single-select by construction**:
  `storage.ts:10-19` (`schemaVersion: 1`, `catalogSchemaVersion: 1`, a global
  `selectedModelId`, `selected: true`), validated against the sole catalog
  entry at `:125-129`.
- Catalog verification expectations are **hardcoded globals**, not per-entry:
  `catalog.ts:72-99` (file type 15, tokenizer `gpt2`/`qwen2`,
  `<|im_start|>`/`<|im_end|>`/`add_generation_prompt` chat-template markers) and
  the by-value repeat at `:165-171`. `family`/`quantization` at `:6,16` are
  literal *type* annotations over the same assumption. `requiredMetadata` is
  already per-entry data. Any non-Qwen entry is rejected before it reaches the
  loader.
- Runtime parameters are hardcoded: `coordinator.ts:22` `nThreads: 0`,
  `:25-26` `DEFAULT_SESSION_CONFIG.contextSize: 2048`, passed at `:524`.
- **No capability detection exists anywhere.** Zero occurrences of
  `physicalMemory`, `os_proc_available_memory`, `NSProcessInfo`/`ProcessInfo`,
  or `hw.memsize` in `app/src`, `app/ios/PocketLM`, or `cpp/src`. The only
  capability check is host-side shell (`scripts/lib/provisioning.sh`,
  `df -Pk` + 64 MiB reserve).
- **No in-app download exists.** No `downloadAsync`, `createDownloadResumable`,
  `URLSession`, or `fetch(` in app or iOS native source. Acquisition is
  host-driven `fetch-models.sh` → `seed-simulator-model.sh`.
- Nothing in `cpp/` needs to change for multi-model: `pocketlm_create_v2`
  (`pocketlm_core.h:142`) takes `(model_path, {context_size, accelerator,
  gpu_layers})`, and `llama_backend.cpp:97` reads the model's **own** embedded
  chat template via `llama_model_chat_template`. A different model formats
  correctly with no core work. `pocketlm_verify_model` does **not** exist yet.
- On-disk layout is already per-model
  (`.../Application Support/PocketLM/Models/<appDirectoryName>/`,
  `storage.ts:249-256`), so models coexist without a layout change.
- `PrivacyInfo.xcprivacy` already declares
  `NSPrivacyAccessedAPICategoryDiskSpace` (reasons E174.1 / 85F4.1).
- `storage.ts:229-233` deliberately does **not** rehash the installed model on
  the JS thread. That constraint is load-bearing for iOS-B.

## iOS-A — Device probe and advisory recommendation

Goal: the models screen shows what this device can plausibly run, honestly
labelled, and the recommendation actually drives session parameters.

- **`PocketLMDeviceProbe`, a separate iOS TurboModule** (~120 lines
  Objective-C++). The **PocketLM module contract is untouched**; what changes
  is that the generated `PocketLMSpec` artifact gains a second protocol —
  `app/package.json:73-80` declares one codegen unit, so a sibling module's
  spec regenerates the same library/header the podspec consumes
  (`PocketLMNative.podspec:93-101`). `INFERENCE_PROTOCOL_V2.md:220` requires
  one coherently registered **`PocketLM`** TurboModule and permits a sibling;
  cite it in the implementation log. Spec file home:
  `app/src/lib/NativePocketLMDeviceProbe.ts` if Android is dropped, or the
  workspace library alongside the moved `codegenConfig` if M6 has landed.
  Registration and the `Bridge/*.{h,m,mm}` glob absorb the new `.mm`
  automatically. Accessed from JS via `TurboModuleRegistry.get` with a null
  gate, mirroring the Android decision so one call site serves both platforms.
  Exposes:
  - `physicalMemoryBytes` — `NSProcessInfo.processInfo.physicalMemory`;
  - `availableMemoryBytes` — `os_proc_available_memory()` (iOS 13+). **Returns
    0 on Simulator and Mac Catalyst**, where no jetsam budget exists.
    `0` is defined as *unknown*, never as *no memory*; the policy falls back to
    `physicalMemoryBytes` under the advisory label. This is a required
    behavior, not a defensive nicety.
  - `activeProcessorCount` and `processorCount`;
  - `freeDiskBytes` — `volumeAvailableCapacityForImportantUsageKey`, read from
    the app-support model directory URL inside the sandbox;
  - **`isSimulator`** — compile-time `TARGET_OS_SIMULATOR`. Load-bearing, not
    cosmetic: it is what makes decision 1 enforceable.
- **Recommendation policy is the shared pure-JS module from Android M8** —
  same formulas, caps, byte units, and boundary vectors. iOS does not get a
  second policy implementation.
- **Advisory semantics, enforced in code**: when `isSimulator` is true, or when
  `availableMemoryBytes` is 0, the UI labels the figure "host memory —
  advisory only" and the policy never suppresses a model choice. On device the
  same path runs and the same advisory framing applies, because the project
  makes no device-validated accuracy claim. A model whose `minTotalRamBytes`
  exceeds the probe reading is marked and warned, never hidden or blocked.
- **Coordinator integration** (this is what makes it more than a badge): iOS
  consumes M8's runtime-config resolver in place of `DEFAULT_SESSION_CONFIG`,
  so `contextSize` and `nThreads` follow the selected tier. Model or
  context-size changes run through M8's awaited switch transaction
  (cancel → await `unloadModel` → load), strictly serialized.
- **Bench screen**: `bench.tsx:219` renders the single installed model's
  SHA-256. Bench identity and stored results become per-model here, or the
  screen is explicitly scoped to the selected model — decide in-milestone and
  record it; silently leaving it single-model produces results attributed to
  the wrong artifact.
- Tests: policy unit tests with injected probe values (simulator flag,
  `availableMemoryBytes == 0`, low-RAM, borderline, absent module); a
  bridge-harness assertion **pinning the 0-on-Simulator reading** so the
  fallback path is exercised rather than assumed; a coordinator test proving
  resolved config reaches `loadModel`.
- VALIDATION.md gains a row stating the probe was exercised on Simulator only
  and that the recommendation is advisory.
- Estimate: **5–8 days.** Risk: low.

## iOS-B — In-app download and verified install

Entry requirement: `pocketlm_verify_model` exists (Android M9, or iOS-0b).

Goal: clean install → probe → download recommended model → verified install →
chat, with no host script.

- **`URLSessionConfiguration.background`**, the iOS analogue of Android's
  foreground `dataSync` service: survives suspension, delegate-based.
- **`resumeData`-primary state model** (adjudicated — see F2). A background
  session permits only download tasks, which write to a **system-owned temp
  file** invisible until `didFinishDownloadingTo`; `resumeData` is an opaque
  blob, not a byte offset. Therefore:
  - the durable record holds model identity, expected size and SHA-256, source
    URL, HTTP validators (ETag / Last-Modified), and the **opaque `resumeData`
    blob** — there is deliberately **no `partialLength` field**, because iOS
    never exposes a partial the app owns;
  - resume is attempted from `resumeData` only. Any failure — invalidated blob,
    validator mismatch, `416`, or **`403` from an expired signed CDN URL**
    (`catalog.ts:158-163` pins the `resolve/<sha>` form, which 302-redirects to
    a time-limited signed URL that `resumeData` can capture) — discards and
    restarts cleanly from the pinned original URL;
  - no Range-suffix concatenation machinery is built. Rejected because it
    requires app-side splicing of system-delivered suffix files to save a
    restart on an attended, minutes-long transfer.
- **Progress events are UI sugar, never the source of truth** — the background
  session outlives the React instance. A query/snapshot API is read on mount.
- **`handleEventsForBackgroundURLSession` reaches the downloader via a small
  Expo-module subscriber shim** (`ExpoAppDelegateSubscriber`), not by editing
  `AppDelegate.swift`. The committed AppDelegate is the stock Expo template and
  is regenerated by `prebuild --clean`; the repo's convention for surviving
  prebuild is config plugins (`withPocketLMPod.js`), and Expo forwards this
  callback only to registered subscribers. A bare CocoaPod TurboModule cannot
  receive it. The Android plan's double-clean-prebuild gate applies here too.
- **Hash authority is the complete, closed file, hashed before promotion** —
  the same decision Android M9 adopted, which removes the process-death
  incremental-digest problem outright. **Hashing runs natively** (CommonCrypto,
  streamed) in the downloader, never on the JS thread: `storage.ts:229-233`
  already avoids rehashing 491 MB there, and the 1.5B artifact is 1.12 GB.
- **Verification reuses `pocketlm_verify_model`** — bounded typed GGUF facts
  out, compared in Objective-C++ against the embedded catalog entry.
- **Fenced mutation**: install / delete / replace run under M8's per-model lock
  ordered against native session ownership; deleting or replacing a loaded
  model requires cancel plus awaited `unloadModel` first.
- **Commit marker with manifest-last ordering plus a startup-repair pass**:
  a final model present without a manifest is re-verified and adopted, or
  quarantined.
- Disk preflight before download (payload + the existing 64 MiB reserve
  convention). **Backup exclusion** applied in-app via
  `URLResourceValues.isExcludedFromBackup`; note that
  `scripts/set-backup-exclusion.swift` also falls back to a raw
  `com.apple.MobileBackup` xattr because host Foundation can report the
  iOS-only key unsupported on Simulator containers. Its `check` mode remains
  the CI oracle and **must be asserted to pass against an app-downloaded
  install**, not assumed to.
- **Protocol amendment**: `INFERENCE_PROTOCOL_V2.md:285-301` frames verified
  provisioning as host-driven. iOS-B changes *who publishes*, so the
  in-app-install clause is a versioned amendment deliverable of this milestone
  in both branches (M6's amendment covers Android wording only).
- Model management UI: per-model install state, delete, disk usage,
  free-space guardrails.
- Tests: app relaunch mid-download; background session handoff through the
  subscriber shim; invalidated `resumeData`; `403` expired-signed-URL resume;
  `416`; validator mismatch; truncated file; **structurally valid GGUF carrying
  the wrong metadata or chat template** (not just corrupted bytes);
  delete-while-loaded rejected; kill at the rename and manifest-write
  boundaries with the startup-repair invariant asserted.
- **Documented Simulator limitation**: background URLSession suspension and
  relaunch behavior differ in Simulator. State plainly which cases are
  exercised and which are asserted only by unit-level fakes.
- Estimate: **2–3 weeks.** Risk: moderate-high — background transfer edge cases
  are where this kind of feature actually fails.

## iOS-C — Cross-family models (phase 2 of decision 3)

Goal: the catalog can carry a non-Qwen model without weakening verification.

- Convert the **hardcoded validator expectations** at `catalog.ts:72-99` and
  `:165-171` into per-entry declared expectations, joining `requiredMetadata`,
  which is already per-entry. The full surface: the validator, the entry types
  (`:6,16`), the `models/catalog.json` schema, the `app.config.ts` embedding,
  `pocketlm_model.rb`, and `pocketlm_verify_model`'s comparison table.
  Verification gets *stronger*, not weaker: today a wrong-but-Qwen-shaped file
  passes the family check trivially.
- No `cpp/` work beyond the verifier's comparison table — the loader already
  applies the model's own template.
- **Licensing is the real gate, not code.** Qwen2.5 0.5B and 1.5B Instruct are
  Apache-2.0. A Llama, Gemma, or Phi entry carries a bespoke community or
  research licence whose redistribution and naming terms must be read and
  reflected in README, the catalog entry, and in-app attribution before any URL
  is pinned. Qwen2.5-3B is Qwen Research, not Apache — the Android plan already
  flags this as an open decision.
- Estimate: **1–1.5 weeks** for the generalization, plus **4–8 days per
  additional family** (template identity, tokenizer, and a quality spot-check
  each). Risk: low technically, moderate on licensing review.

## Effort summary

| Item | Estimate | Risk |
| --- | --- | --- |
| *(iOS-0a — lift M8's shared portion; blocks iOS-A; only if Android is dropped)* | *2–2.5 weeks* | *moderate* |
| *(iOS-0b — lift `pocketlm_verify_model`; blocks iOS-B only)* | *3–5 days* | *low-moderate* |
| iOS-A probe + advisory + coordinator integration | 5–8 days | low |
| iOS-B download + verified install | 2–3 weeks | moderate-high |
| iOS-C cross-family generalization | 1–1.5 weeks | low / licensing |
| **Total, Android proceeding** | **≈ 4.5–6 weeks** | |
| **Total, iOS-only** | **≈ 7–9 weeks** | |

Rough new code: probe + policy wiring ~0.4k lines; downloader + durable state +
failure matrix ~1.2–1.6k; per-entry validation ~0.3k; tests included.

## Risk register

1. **Both probe inputs are wrong on Simulator** — `physicalMemory` reports host
   RAM, `os_proc_available_memory()` reports 0. Mitigated by decision 1
   (advisory framing), the `isSimulator` flag, and the 0-⇒-unknown fallback
   with a harness assertion pinning it. Not mitigated by pretending either
   number is right.
2. **`os_proc_available_memory` is a budget, not a guarantee.** A model that
   fits the reading can still be jetsam-killed under memory pressure. Warning
   copy must not imply a guarantee.
3. **Background URLSession is under-testable on Simulator.** Residual risk
   documented rather than absorbed; resume correctness is proven by unit-level
   fakes plus targeted manual runs.
4. **Hugging Face CDN behavior is unverified** — Range support, redirect
   expiry, and rate limits. The `resumeData`-primary design degrades to a clean
   restart in every unhandled case, which bounds the blast radius.
5. **Ordering hazard, inherited**: a second catalog entry landing before the M8
   parser and manifest migration throws at startup on iOS (`catalog.ts:112`).
   Ordering is load-bearing.
6. **Storage growth**: 0.5B + 1.5B is ~1.6 GB installed. Free-space preflight
   and delete UI are requirements, not polish.
7. **Licensing drift** on cross-family entries (iOS-C) — a code-complete
   feature blocked on a licence read is a scheduling risk worth surfacing.

## Explicit non-claims

This plan does not establish, and its acceptance criteria must not be read as
establishing: physical-device execution or Metal offload; throughput, energy,
or thermal behavior; that the capability recommendation is accurate on real
hardware; leak-free memory behavior; or App Store readiness. These remain where
`docs/VALIDATION.md` puts them today.

## Release impact

Any of this invalidates the v1.0.0 qualification evidence, which is pinned to
one model SHA-256. Ships as **v1.1** with the release suite re-run and
VALIDATION.md re-derived per installed model. The qualification runner is
already parameterized by `ReadyInstalledModel` (`runner.ts:85,777-786`), so the
re-run is a fixture change, not a harness rewrite.

## Planning-review adjudication (v1 → v2, review of 2026-08-03)

All eight findings were verified and accepted. The review confirmed every
current-state citation in v1; the defects were concentrated in the translation
of Android M9 mechanics into iOS platform reality.

Adopted as prescribed: **F1** (`availableMemoryBytes == 0` ⇒ unknown, fallback
to `physicalMemory` under the advisory label, harness assertion pinning the
Simulator behavior, risk 1 extended — the finding strengthens decision 1 rather
than challenging it); **F4** (frozen-contract claim restated, spec-file home
specified for both branches, `INFERENCE_PROTOCOL_V2.md:220` cited);
**F5** (iOS-0 split into 0a/0b, re-priced, verifier moved off the iOS-A
prerequisite path onto iOS-B's entry; totals corrected); **F6** (script `check`
mode named as the CI oracle, dual mechanism noted, assertion required);
**F7** (generalization surface corrected to `catalog.ts:72-99`/`:165-171` plus
`models/catalog.json`, `app.config.ts`, and the verifier comparison table);
**F8** (bench per-model identity, in-app-publication protocol amendment, native
CommonCrypto hashing, all added; the runner-parameterization note folded into
Release impact).

Adopted with a chosen option:

- **F2 (download state model)** — took correction (a), `resumeData`-primary.
  The durable record drops `partialLength` entirely and resume degrades to a
  clean restart on any failure. Correction (b), an app-owned partial with
  Range-suffix download tasks and explicit concatenation, was rejected: it
  builds splicing machinery for system-delivered suffix files to save one
  restart on an attended, minutes-long transfer, and it reintroduces exactly
  the durable-partial-state class of bug that the closed-file hash authority
  was adopted to remove. The `403`-expired-signed-URL case was added to the
  failure matrix as prescribed.
- **F3 (app-delegate hook)** — took correction (a), an Expo-module subscriber
  shim. Correction (b), a `withAppDelegate` dangerous-mod, was rejected as
  fragile against Expo template churn; correction (c), declaring the
  AppDelegate hand-maintained, was rejected because it contradicts the repo's
  prebuild convention and the Android plan's double-clean-prebuild gate.

Nits accepted: `pocketlm_model.rb` citation widened to `:273-274`;
`storage.ts:249` widened to `:249-256`; `freeDiskBytes` source directory
specified.

Estimates changed: iOS-A 4–7 days → 5–8 days (bench decision and the added
probe-fallback tests); iOS-0 2–2.5 weeks → iOS-0a 2–2.5 weeks + iOS-0b 3–5
days; iOS-only total 6–8.5 weeks → 7–9 weeks.
