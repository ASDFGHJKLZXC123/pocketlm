# Expansion Gate 0B contract decisions

Status: accepted decisions for golden-fixture definition and independent review.
Date: 2026-08-23.

This record resolves the open or ambiguous values needed to build the Gate 0B
fixture corpus. The normative details are in
[Expansion Gate 0 contracts](./EXPANSION_GATE_0_CONTRACTS.md); the unchanged
inference event contract and its repository amendment are in
[Inference Protocol 2.1](./INFERENCE_PROTOCOL_V2.md).

## Scope and activation boundary

Gate 0B is documentation, language-neutral fixture definition, a test-only Ruby
verifier, and fast-verification wiring only. It does not change production
TypeScript, Ruby, or C++ schema readers, the production schema-1 catalog, CMake,
codegen, JNI or Objective-C++ adapters, Android or iOS behavior, downloader
behavior, persisted production data, or the built ABI.
Catalog-v2 fixtures are test data and do not add the 1.5B model to the production
catalog. Later serialized gates own implementation and activation.

## G0B-001 — versions and closed wire shapes

- The current inference contract is Protocol 2.1 on C ABI 2.1.0 /
  `0x00020100`.
- The future bounded GGUF-inspector addition targets the append-only C ABI
  2.2.0 / `0x00020200`; Gate 0B does not perform that bump.
- Every JSON wire object defined by the freeze, including catalog v2 and
  installation record v2, is closed unless explicitly declared append-only.
  Unknown keys are invalid; persisted JSON also rejects duplicate keys,
  invalid UTF-8, and a BOM.
- Every digest authenticates exact complete bytes without parse/reserialize.

## G0B-002 — manager state and migration intent

`manager-state-v1.json` is a closed, at-most-4-MiB object containing exactly its
schema version, arbitrary-precision manager revision, retained arbitrary-
precision preference revision, exact catalog digest, durable transfers, and
command receipts, plus retained quarantine records. It retains at most the 256
completed receipts with greatest
terminal manager revisions plus every nonterminal receipt. Eligible completed
receipts are evicted before a write-size failure; if the state still cannot fit,
the manager fails closed before an external effect.

Platform resume blobs, validators, redirected URLs, partial-file ownership
details, and OS task/service handles remain native-private by operation ID. They
never cross the shared snapshot or enter events, diagnostics, or logs.

`migration-v1-to-v2.json` is a closed, at-most-1-MiB object. It freezes the raw
source-manifest digest, model and selected intent, next preference revision,
exact preference bytes/digest, phase, target publication, canonical installed
time, and exact target manifest/marker bytes and digests. Its phases are
`prepared`, `recordWritten`, `markerWritten`, `preferenceWritten`,
`counterAdvanced`, and `complete`.

Migration source timestamps accept only extended RFC 3339
`YYYY-MM-DDTHH:mm:ss[.1-9digits](Z|±HH:MM)`, valid Gregorian fields, seconds
00–59, and offsets through ±14:00. Conversion to UTC precedes fractional-second
truncation. A grammatically valid source is rejected if UTC conversion would
leave the canonical persisted year range 0001–9999. Spaces, basic/week/ordinal
forms, lowercase `z`, missing zones, and leap seconds are rejected.

## G0B-003 — persisted bytes and digest vectors

The canonical preference vector is the 129 UTF-8 bytes represented by:

```text
{"schemaVersion":1,"revision":"1","modelId":"qwen2.5-0.5b-instruct-q4-k-m","origin":"manual","updatedAt":"2026-08-23T12:34:56Z"}\n
```

Its digest is
`1d2f0c3518bcf1724dcbdfcb47ef294524106eef68814337a1e80da7312cceb7`.
Removing only the terminal LF produces
`0e9432efa89391020481022d8b87c8568077f4da88d1ec1fb7da4afa53a6a3f4`.

The canonical runtime fingerprint is
`9045afb4538b981664b35371a4d2054fd5408409199f448ede2c31a2a61f5177`
for the exact field vector recorded in the normative contract.

For model `qwen2.5-0.5b-instruct-q4-k-m`, expected manager revision
`100000000000000000000000000000000000000`, operation ID
`11111111111111111111111111111111`, and origin `manual`, the six normalized
argument digests are:

| Method | SHA-256 |
| --- | --- |
| `startInstall` | `5a6eedf062da7828ccf754fbd17eaf179b2c2d4a78a709f83323c3800276315d` |
| `pauseInstall` | `58ae358c1f67be1963c2bb2195412485df16ff6cdf1f8806f62b05bf55ce1a04` |
| `resumeInstall` | `912ce7671ca1bd212a014d69680da299ad11695e83be4cab73a17356d1935197` |
| `cancelInstall` | `f8c8113e7f515f113a8770091cc19132f9f0130861b4101440050861b66d00c8` |
| `deleteInstallation` | `b391396a55a95bf57126c9f14b50419ce519bd94c95d063d6b59d10f71af94d5` |
| `setSelectedPreference` | `d07c6d2d95a88e1fe4890a06b8e9b9904df9d05c8b11de82df97fbbafebffd5e` |

## G0B-004 — authenticated model facts

The 0.5B artifact remains the catalog floor. Its verified chat template is
2,509 bytes with SHA-256
`d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4`;
inspection records GGUF v3, 291 tensors, and 26 metadata entries.

The independently authenticated 1.5B artifact is:

| Fact | Value |
| --- | --- |
| Model ID | `qwen2.5-1.5b-instruct-q4-k-m` |
| Repository revision | `91cad51170dc346986eccefdc2dd33a9da36ead9` |
| Introduced revision | `dd26da440ef0330c47919d1ecae0966d24022222` |
| Filename | `qwen2.5-1.5b-instruct-q4_k_m.gguf` |
| Bytes | `1117320736` |
| SHA-256 | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| GGUF | v3, 339 tensors, 26 metadata entries |
| Alignment/data offset | 32 / 5,950,496 |
| Exact parameter count | 1,777,088,000 |
| Required scalar metadata | `qwen2`, file type 15, `gpt2`, `qwen2` |
| Chat template | 2,509 bytes; `d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4` |
| License | Apache-2.0; 11,343 bytes; `832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e` |

Both models require the exact markers `<|im_start|>`, `<|im_end|>`, and
`add_generation_prompt`. The large downloaded artifact and its external
inspection evidence remain outside Git.

## G0B-005 — runtime policy profile v1

| Model | Minimum total RAM | Recommended total RAM | Initial context |
| --- | ---: | ---: | ---: |
| 0.5B | 2,147,483,648 | 4,294,967,296 | 2,048 |
| 1.5B | 4,294,967,296 | 6,442,450,944 | 2,048 |

Catalog order is increasing recommendation rank. Policy selects the
greatest-index model whose recommended RAM fits total RAM; if none, it selects
the first model whose minimum fits; below every minimum it returns null. A
missing or malformed probe returns null and makes no recommendation claim.
Simulator output is advisory.
Profile-v1 recommendation uses total memory only; other probe and benchmark
facts may inform warnings, runtime threads, or disk preflight but not model rank.

Manual preference always wins and may select a committed model below a RAM
threshold with a warning; models are never hidden. JavaScript may submit only
`manual` or `recommended`; `migrated` and `fallback` are manager-reserved.

Runtime configuration is catalog initial context, AUTO accelerator, zero GPU
layers, and profile version 1. Missing-probe threads are 0. iOS uses the smaller
of active processors and 4. Android counts known-frequency CPUs at least 90% of
the maximum and clamps to 1 through the smaller of active processors and 4; any
null frequency falls back to the smaller of active processors and 4. The
normative contract contains exact boundary vectors.

## G0B-006 — probe invariants

- `AVAILABLE_MEMORY_UNKNOWN` appears exactly when iOS reports available memory
  zero and is forbidden otherwise.
- `CPU_FREQUENCY_UNKNOWN` appears exactly when an Android frequency element is
  null and is forbidden otherwise.
- `SIMULATOR_HOST_FACTS` appears exactly when `isSimulator` is true.
- Android's frequency array length equals `processorCount`.
- Limitations are unique and in declared enum order.

## G0B-007 — marker adoption and recovery

Ordinary loading rejects a record without a commit marker. Adoption is allowed
only under exclusive startup repair when one matching durable transfer or
migration intent names the exact publication and raw target bytes, all
model/catalog/path/protection checks pass, and no competing generation or intent
exists. A stray markerless record is quarantined.

Invalid active without rollback and invalid-only rollback are quarantined and
leave no active generation. A valid complete staging generation is promotable
only when the matching durable operation ID uniquely authorizes it. Unauthorized
or ambiguous staging is quarantined; multiple rollback ambiguity fails closed.

## G0B-008 — quarantine retention and recovery UX

A closed quarantine record carries schema version, quarantine ID, model ID,
nullable publication ID, source kind (`active`, `staging`, or `rollback`), stable
reason, created manager revision, timestamp, and retained byte size. Quarantine
is never loadable and its bytes count in disk preflight.

At most one entry per model is retained: greatest manager revision wins, and
older entries are removed only after repair completes. The newest has no age
expiry and remains until successful reinstall/replacement or explicit
damaged-file deletion. With no active generation, retained quarantine produces
snapshot state `invalid` and the actions `Retry install` and
`Delete damaged files`.

The explicit delete uses `deleteInstallation` with a receipt that freezes the
exact immutable quarantine ID, not model ID alone. Crash replay may remove only
that target; later quarantine evidence is left intact.

## G0B-009 — GGUF ABI result semantics

- GGUF facts v1 accepts GGUF wire v3 only; every other wire version returns
  `PLM_GGUF_UNSUPPORTED_VERSION` before metadata interpretation.
- Null buffer plus zero capacity is a successful sizing request with trusted
  facts and required capacity, and no template write.
- An undersized nonnull buffer returns `PLM_GGUF_BUFFER_TOO_SMALL`; only required
  capacity is defined. Other errors zero writable outputs.
- Empty template is parser success and platform `METADATA_MISMATCH`.
- Corrupt/truncated/type/UTF-8 failures map to `GGUF_INVALID`; count, overflow,
  and overlarge fields map to `GGUF_BOUNDS`; I/O maps to `STORAGE_IO`;
  non-regular/path failure maps to `PATH_REJECTED`; programmer, internal, and
  buffer-protocol errors map to `INTERNAL`.
- Parsed-fact/catalog disagreement maps to `METADATA_MISMATCH`. A durable
  operation's catalog-byte identity changing is the separate `CATALOG_DRIFT`.

## G0B-010 — Protocol 2.1 amendment

Protocol 2.1 adds committed production-path validation, repository read/exclusive
leases, complete-generation publication, switching ownership, and JavaScript VM
reload/orphan reconciliation to the documentation. It preserves all v2 events,
payloads, identities, ordering, terminal delivery, cancellation, unload, and
EventEmitter semantics and adds no model-manager unload API.

## Fixture acceptance

The language-neutral corpus at `fixtures/expansion-gate-0/fixture-set-v1` must
cover canonical encodings, catalog, installation/publication, quarantine,
preference/migration, manager snapshot/receipt, probe/policy, path, lease, and
bounded GGUF cases. Every byte-bearing fixture includes exact bytes and a
detached digest. Each invalid case declares one primary stable rejection class
and may combine correlated violations with that same outcome; precedence cases
isolate the competing rule. Behavioral fixtures use deterministic schedules or
fault points.

The hardened closed-corpus integrity suite passed 19 runs and 162 assertions on
2026-08-23. A different GPT-5.6 Sol reviewer accepted the final 173-case corpus
and these decisions with no remaining findings, closing G0-B. Overall Gate 0
remains separately blocked on its hardware, Linux/KVM, and platform-lane
evidence. The acceptance record is
[Gate 0B contract-fixture acceptance](../implementation-logs/GATE_0B_CONTRACT_FIXTURES_2026-08-23.md).

Current-status pointer (2026-10-03): the evidence sentence above preserves the
August acceptance-time view. The owning plan and `GATE_0_ORCHESTRATION.md` now
assign new prebuild/XCTest/device-SDK acceptance to Gate 1, emulator/native
execution to Gates 3A/4A, and final platform qualification to Gate 6. Remaining
overall Gate 0 evidence is hardware enrollment, assigned Linux/KVM installation,
and final closure review. The frozen decisions/model facts and fixture bytes
are unchanged; this pointer does not authorize schema/runtime/ABI activation.
