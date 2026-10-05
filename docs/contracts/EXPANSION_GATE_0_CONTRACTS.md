# Expansion Gate 0 contract freeze

Status: normative Gate 0B freeze accepted; overall Gate 0 remains open.
Sections not explicitly marked open are frozen for fixture and task-packet
design. No schema activation or runtime implementation is authorized until the
overall Gate 0 exit criteria are satisfied and the applicable implementation
gate is dispatched.
Date: 2026-08-07.
Open-evidence updated: 2026-08-23.
Protocol basis: Inference Event Protocol 2.1 and current C ABI `0x00020100`.
The future GGUF-inspector addition targets C ABI `0x00020200`; Gate 0B changes
documents and fixture definitions only and does not bump the built ABI.
Decision record:
[Expansion Gate 0B contract decisions](./EXPANSION_GATE_0_DECISIONS.md).
Acceptance evidence:
[Gate 0B contract-fixture acceptance](../implementation-logs/GATE_0B_CONTRACT_FIXTURES_2026-08-23.md).

## Version map

| Contract | Expansion version | Compatibility rule |
| --- | --- | --- |
| Catalog | 2 | Unknown schema fails closed |
| Installation record | 2 | Immutable after commit; unknown/newer is unsupported and not deleted |
| Commit marker | 1 | Written last; required for loadability |
| Selected preference | 1 | Durable user intent only |
| Runtime fingerprint | 1 | Memory/runtime identity only |
| Device probe snapshot | 1 | Immutable pure-fact snapshot |
| Model-manager snapshot | 1 | Native state authority |
| Manager state | 1 | Closed durable native-manager journal; 4 MiB maximum |
| Migration journal | 1 | Closed, resumable schema-1 conversion intent; 1 MiB maximum |
| Quarantine record | 1 | Closed, non-loadable recovery evidence |
| Runtime policy | 1 | Pure shared recommendation and runtime configuration |
| GGUF facts | 1 | Bounded append-only C ABI payload |
| Current core C ABI | 2.1.0 / `0x00020100` | Implemented inference ABI; existing v2 symbols remain unchanged |
| Target expansion C ABI | 2.2.0 / `0x00020200` | Future append-only GGUF-inspector bump; not activated by Gate 0B |
| Inference protocol | v2 + 2.1 amendment | Event grammar unchanged; amendment covers paths, leases, publication, and reload |

Every extensible native struct starts with its exact size and independent
version. Enum values are never reused or reordered. Control flow uses stable
codes, never diagnostic messages.

Every JSON wire object defined by this contract—including catalog v2 and
installation record v2—whether persisted or returned across the bridge, is a
closed shape: unknown keys are rejected unless a section explicitly declares
an append-only object.
Persisted objects also reject duplicate JSON keys, invalid UTF-8, and a UTF-8
BOM. An explicitly versioned nested object is closed independently. A new field
therefore requires a new containing schema version unless this document
explicitly declares it append-only.

## Canonical scalar and byte encodings

- Persisted timestamps use exactly `YYYY-MM-DDTHH:mm:ssZ`: four-digit years
  0001–9999, valid proleptic-Gregorian calendar fields, UTC only, and seconds
  00–59. Fractions, offsets, spaces, and leap-second `:60` are invalid. During
  v1 migration, the accepted source grammar is the strict extended RFC 3339
  subset `YYYY-MM-DDTHH:mm:ss[.1-9digits](Z|+HH:MM|-HH:MM)`: Gregorian calendar
  fields are valid, seconds are 00–59, and offsets do not exceed `14:00` in
  either direction (an hour of 14 requires minutes `00`). Spaces, basic form,
  week dates, ordinal dates, lowercase `z`, missing zones, and leap seconds are
  rejected. The value is converted to UTC and fractional seconds are truncated
  after conversion, never rounded. A grammatically valid source value is also
  rejected if UTC conversion would leave the canonical persisted year range
  0001–9999. Timestamps are informational; revisions, not clock values, order
  state.
- Manager and preference revisions are canonical arbitrary-precision decimal
  strings matching `0|[1-9][0-9]*`, with no sign, whitespace, leading zero,
  numeric conversion, maximum value, wrap, or exhaustion state. Implementations
  compare length then lexicographic digits and increment with checked decimal
  string arithmetic. Before readiness, the manager persists a bootstrap
  `manager-state-v1.json` at revision `0`. Manager revision increments once for
  each atomic replacement of that manager-state file, including a receipt-only
  rejection; replacing the separate preference file does not itself increment
  it.
  The retained preference counter starts at `0` when no preference has ever
  existed; the first preference uses `1`. The counter remains in manager state
  while no preference file exists and increments for every preference replace
  or clear. Revision digit strings are bounded only by the 4 MiB manager-state
  or 1 MiB migration-journal file limit containing them; validation operates
  directly on the digits, so an overlarge file fails as `STORAGE_IO` before any
  revision is parsed as a machine integer.
  `expectedRevision` always names the manager revision, never the preference
  revision.
- Decimal fields in runtime-fingerprint input use canonical unsigned decimal
  with no sign, whitespace, or leading zero. `contextSize` is positive;
  `gpuLayers` is nonnegative; `policyProfileVersion` is positive. Fingerprint
  fields are separated by one NUL byte and there is no trailing NUL after the
  final field. `ActiveFingerprint.value` is lowercase 64-hex.
- Every SHA-256 field—including catalog, artifact, license, template, manifest,
  runtime-fingerprint, normalized-argument, and migration source-manifest
  digests—is lowercase 64-hex. A digest covers the exact complete byte sequence
  named by its field. JSON digests cover the persisted UTF-8 bytes as stored,
  including whitespace, line endings, and any terminal newline; persisted JSON
  is UTF-8 without a BOM. Hashing never reparses or reserializes JSON. Golden
  fixtures therefore provide both the exact bytes and their digest.
- Command, operation, publication, and quarantine IDs are nonzero lowercase
  32-hex values. Command IDs are client-created. The other IDs are generated
  with a cryptographically secure random source and regenerated on any collision
  with current manager state or repository entries. The all-zero value is
  invalid.

The canonical persisted-preference byte vector is the following 129-byte UTF-8
sequence, expressed as an escaped string so its one terminal LF is explicit:

```text
{"schemaVersion":1,"revision":"1","modelId":"qwen2.5-0.5b-instruct-q4-k-m","origin":"manual","updatedAt":"2026-08-23T12:34:56Z"}\n
```

Its SHA-256 is
`1d2f0c3518bcf1724dcbdfcb47ef294524106eef68814337a1e80da7312cceb7`.
The same JSON without the terminal LF has SHA-256
`0e9432efa89391020481022d8b87c8568077f4da88d1ec1fb7da4afa53a6a3f4`
and is deliberately a different byte vector.

## Catalog v2

```ts
type CatalogV2 = {
  schemaVersion: 2;
  models: readonly ModelV2[];
};

type ModelV2 = {
  id: string;
  displayName: string;
  family: 'qwen2';
  repository: string;
  revision: string;
  artifactIntroducedRevision: string;
  filename: string;
  sourceUrl: string;
  byteSize: number;
  sha256: string;
  ggufMagic: 'GGUF';
  ggufVersion: number;
  quantization: 'Q4_K_M';
  parameterCountApproximate: string;
  license: 'Apache-2.0';
  licenseUrl: string;
  licenseByteSize: number;
  licenseSha256: string;
  gated: false;
  initialContextTokens: number;
  minTotalRamBytes: number;
  recommendedRamBytes: number;
  chatTemplateSource: 'gguf_metadata';
  chatTemplateVerified: true;
  appDirectoryName: string;
  installedFilename: 'model.gguf';
  requiredMetadata: RequiredMetadataV1;
};

type RequiredMetadataV1 = Readonly<{
  'general.architecture': 'qwen2';
  'general.file_type': 15;
  'tokenizer.ggml.model': 'gpt2';
  'tokenizer.ggml.pre': 'qwen2';
  'tokenizer.chat_template': Readonly<{
    nonEmpty: true;
    byteSize: number;
    sha256: string;
    contains: readonly string[];
  }>;
}>;
```

Normative invariants:

- JSON is UTF-8 and contains 1–32 models.
- All integer byte, token, and RAM fields are positive safe integers.
- `minTotalRamBytes <= recommendedRamBytes`.
- revisions are exact lowercase 40-character hexadecimal values and SHA-256
  values are exact lowercase 64-character hexadecimal values.
- `repository` is exactly two ASCII components separated by one `/`; each
  component matches
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$`. There are no empty, `.`, or `..`
  components and no percent encoding.
- `sourceUrl` is exactly the ASCII string
  `https://huggingface.co/<repository>/resolve/<revision>/<filename>`, with no
  query, fragment, alternate escaping, credentials, or mutable redirect URL.
- `licenseUrl` is exactly
  `https://huggingface.co/<repository>/resolve/<revision>/LICENSE`; license is
  exactly `Apache-2.0`, and the positive safe-integer byte size plus lowercase
  SHA-256 authenticate those exact bytes. Other licenses, mutable URLs, or byte
  drift fail catalog validation.
- IDs, filenames, and directory names match
  `^[A-Za-z0-9][A-Za-z0-9._-]*$`; `.`, `..`, separators, controls, and unsafe
  Unicode scalars are rejected.
- IDs, application directories, resolved relative install paths, and source
  triples are independently unique.
- Model IDs are exact, case-sensitive API values, but IDs, application
  directories, and resolved local paths must also be unique after ASCII
  lowercasing. Callers never receive case-insensitive ID resolution. This makes
  one catalog valid on both case-folding APFS and case-sensitive Android filesystems.
- Catalog order is the deterministic fallback/tie-break order, not a security
  identity.
- `requiredMetadata` is the closed v1 shape above; unknown keys or predicates
  are rejected. The four scalar facts compare exactly to inspector outputs.
  Strings compare as their original valid UTF-8 bytes with no Unicode
  normalization. The chat template must be nonempty, have the exact byte size
  and SHA-256, and contain every listed UTF-8 byte fragment. `contains` has 1–16
  unique nonempty entries, each at most 128 UTF-8 bytes, and is supplementary to
  the exact full-template hash rather than an identity substitute.
- Builds embed the repository catalog bytes plus a separately generated SHA-256
  of those exact bytes. The catalog does not contain a self-referential digest.

The independently authenticated 1.5B catalog identity and policy fields are
frozen as follows:

```text
id: qwen2.5-1.5b-instruct-q4-k-m
displayName: Qwen2.5 1.5B Instruct (Q4_K_M)
family: qwen2
repository: Qwen/Qwen2.5-1.5B-Instruct-GGUF
revision: 91cad51170dc346986eccefdc2dd33a9da36ead9
artifactIntroducedRevision: dd26da440ef0330c47919d1ecae0966d24022222
filename: qwen2.5-1.5b-instruct-q4_k_m.gguf
sourceUrl: https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf
byteSize: 1117320736
sha256: 6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e
ggufMagic: GGUF
ggufVersion: 3
quantization: Q4_K_M
parameterCountApproximate: 1.78B
license: Apache-2.0
licenseUrl: https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/LICENSE
licenseByteSize: 11343
licenseSha256: 832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e
gated: false
initialContextTokens: 2048
minTotalRamBytes: 4294967296
recommendedRamBytes: 6442450944
chatTemplateSource: gguf_metadata
chatTemplateVerified: true
appDirectoryName: qwen2.5-1.5b-q4km
installedFilename: model.gguf
requiredMetadata.general.architecture: qwen2
requiredMetadata.general.file_type: 15
requiredMetadata.tokenizer.ggml.model: gpt2
requiredMetadata.tokenizer.ggml.pre: qwen2
requiredMetadata.tokenizer.chat_template.nonEmpty: true
requiredMetadata.tokenizer.chat_template.byteSize: 2509
requiredMetadata.tokenizer.chat_template.sha256: d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4
requiredMetadata.tokenizer.chat_template.contains: <|im_start|>, <|im_end|>, add_generation_prompt
```

The independent full-file inspection records GGUF v3, 339 tensors, 26 metadata
key/value entries, 32-byte alignment, data offset 5,950,496, and exact parameter
count 1,777,088,000. Alignment, data offset, and exact parameter count are
evidence facts rather than additional catalog-v2 fields. The license fixture at
that revision is 11,343 bytes with SHA-256
`832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e`.

The authenticated 0.5B artifact's v2 chat-template requirement is independently
read from the local GGUF as 2,509 UTF-8 bytes with SHA-256
`d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4`.
Its full-file inspection records GGUF v3, 291 tensors, and 26 metadata entries.
The catalog-v2 fixture must record those exact values in addition to the three
existing required fragments.
Its pinned Apache-2.0 license bytes at catalog revision
`9217f5db79a29953eb74d5343926648285ec7e67` have the same 11,343-byte size and
SHA-256 `832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e`.
The 0.5B model freezes `initialContextTokens = 2048`,
`minTotalRamBytes = 2147483648`, and `recommendedRamBytes = 4294967296`.
The 0.5B and 1.5B artifacts therefore share the exact 2,509-byte authenticated
chat template, but retain independent artifact and publication identities.

## Runtime fingerprint v1

Do not depend on generic JSON canonicalization. Compute:

```text
sha256(
  "PocketLM/runtime-fingerprint/v1\0" +
  NUL-separated UTF-8 fields in this exact order:
  modelId,
  artifactSha256,
  publicationId,
  contextSize as base-10,
  requestedAccelerator,
  gpuLayers as base-10,
  policyProfileVersion as base-10
)
```

Catalog strings that can enter the fingerprint cannot contain NUL.
`publicationId` distinguishes replacement generations even when bytes match.
`nThreads` is deliberately absent: it is a per-generation parameter in the
frozen inference API, not session-load state. Policy resolves and records the
actual `nThreads` on every generation/qualification request; changing it does
not require a model-session switch.

The canonical fingerprint fixture uses these fields:

```text
modelId: qwen2.5-0.5b-instruct-q4-k-m
artifactSha256: 74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
publicationId: 0123456789abcdef0123456789abcdef
contextSize: 2048
requestedAccelerator: auto
gpuLayers: 0
policyProfileVersion: 1
sha256: 9045afb4538b981664b35371a4d2054fd5408409199f448ede2c31a2a61f5177
```

## Installation record and commit marker

```ts
type InstallationRecordV2 = {
  schemaVersion: 2;
  catalogSchemaVersion: 2;
  modelId: string;
  publicationId: string;
  installedAt: string;
  backupExcluded: true;
  relativePath: {
    appDirectoryName: string;
    installedFilename: 'model.gguf';
  };
  artifact: {
    byteSize: number;
    sha256: string;
    sourceRevision: string;
    sourceFilename: string;
  };
  inspection: {
    inspectorFactsVersion: 1;
    ggufVersion: number;
    tensorCount: number;
    metadataCount: number;
    architecture: string;
    fileType: number;
    tokenizerModel: string;
    tokenizerPre: string;
    chatTemplateSha256: string;
    chatTemplateBytes: number;
  };
};

type CommitMarkerV1 = {
  schemaVersion: 1;
  publicationId: string;
  manifestSha256: string;
  modelSha256: string;
  modelByteSize: number;
};
```

`publicationId` is 32 lowercase hexadecimal characters (128 bits). The installation record is
immutable after commit and never contains selection state. A replacement creates
a new publication ID, record, and marker.
`installedAt` uses the canonical timestamp grammar above. `manifestSha256`
hashes the exact persisted UTF-8 bytes of `manifest.json`; `modelSha256` hashes
the complete closed `model.gguf` bytes.

An installation is loadable only when all of these are true:

- startup repair has completed;
- the final model is a regular file;
- record and marker agree with each other;
- the current catalog agrees with artifact identity, relative path, and required
  inspection facts; and
- backup exclusion has succeeded.

Ordinary loading always rejects a record without a matching commit marker. A
markerless record may be adopted only while startup holds exclusive authority
and a matching durable transfer or migration intent names the same model and
target publication. Adoption rehashes the exact raw record and model bytes,
re-runs catalog and GGUF comparison, re-verifies canonical path, permissions,
file protection, and backup exclusion, proves that no competing active,
staging, rollback, or intent exists, and then writes/fsyncs/renames the exact
intent-frozen marker last. A markerless record without that unique intent is
stray metadata and is quarantined; it is never inferred or adopted heuristically.

A catalog addition does not invalidate another record. Unknown/newer records are
unsupported and must not be automatically deleted on downgrade.

The model, record, and marker are one generation. They are never promoted as
three independent final-path renames. Replacement uses the directory-swap
protocol defined below so failure cannot destroy the prior committed bytes.

## Schema-1 migration

The migration journal is a closed JSON object with a 1 MiB maximum exact file
size:

```ts
type MigrationPhaseV1 =
  | 'prepared'
  | 'recordWritten'
  | 'markerWritten'
  | 'preferenceWritten'
  | 'counterAdvanced'
  | 'complete';

type MigrationJournalV1 = {
  schemaVersion: 1;
  sourceManifestSha256: string;
  modelId: string;
  selectedIntent: 'selected';
  nextPreferenceRevision: string;
  preferenceBytesUtf8: string;
  preferenceBytesSha256: string;
  phase: MigrationPhaseV1;
  targetPublicationId: string;
  installedAt: string;
  targetManifestBytesUtf8: string;
  targetManifestSha256: string;
  targetMarkerBytesUtf8: string;
  targetMarkerBytesSha256: string;
};
```

The byte strings contain the exact no-BOM persisted bytes, including any
terminal newline. Each adjacent digest authenticates exactly that string's
UTF-8 bytes. `installedAt` is the already converted canonical persisted
timestamp and is reused byte-for-byte on every retry. Unknown fields, invalid
phase transitions, an overlarge file, or any byte/digest disagreement fail
closed before migration mutates the generation.

Migration runs under the native repository's exclusive authority. It validates
the existing v1 pair against the current 0.5B entry, rehashes and inspects the
model, and verifies the v1 global `selectedModelId` and per-model `selected`
fields consistently identify that model. Before replacing metadata it atomically
writes/fsyncs `<root>/migration-v1-to-v2.json`, recording the source-manifest
hash over the exact complete on-disk v1 manifest bytes, model ID, selected
intent, next preference revision, exact desired preference UTF-8 bytes and their
SHA-256, and phase. It then writes and fsyncs a temporary
v2 record, atomically renames it and fsyncs the parent, and
writes/renames/fsyncs the marker last. After the v2 generation is loadable it
atomically writes/fsyncs `selected-preference.json` with that model and
`origin = 'migrated'`, atomically advances/fsyncs the retained manager-state
preference counter to the journal's exact `nextPreferenceRevision`, and only then marks
complete and removes the migration journal. The model is not moved or downloaded
again.

Retries are idempotent. Startup consults the journal before ordinary fallback:
v1 plus a prepared journal resumes conversion; v2 plus a journal and no
preference writes the migrated preference; a matching migrated preference with
a stale retained counter advances/fsyncs that counter from the journal before
cleanup. Preference-write/fsync or counter-write/fsync failure keeps repair
incomplete and the journal durable, so fallback is not persisted and mutators
stay disabled.
A conflicting valid preference or journal/source/target hash mismatch fails
closed. A valid v2 record without a marker is adoptable only through the unique
durable-intent procedure above; otherwise it is quarantined. Migration activates
only after v2 readers, writers, and fixtures are green in TypeScript, Ruby, and
native code.

## Preference and active-session semantics

```ts
type SelectionOrigin = 'manual' | 'recommended' | 'migrated' | 'fallback';
type RequestedSelectionOrigin = 'manual' | 'recommended';

type SelectedPreferenceV1 = {
  schemaVersion: 1;
  revision: string;
  modelId: string;
  origin: SelectionOrigin;
  updatedAt: string;
};

type ActiveFingerprint = {
  value: string;
  modelId: string;
  publicationId: string;
  config: {
    contextSize: number;
    accelerator: 'auto' | 'cpu' | 'metal';
    gpuLayers: number;
    policyProfileVersion: number;
  };
  sessionId: number;
};
```

The preference is one atomically replaced and fsynced file outside per-model
records. `activeFingerprint` is process memory only and exists only after native
load, diagnostics validation, and read-lease acquisition succeed.
`SelectedPreferenceV1.revision` and `updatedAt` use the canonical preference
revision and timestamp rules above.
JavaScript may request only `manual` or `recommended` through
`setSelectedPreference`. `migrated` and `fallback` are native-manager origins
reserved for migration and deterministic repair. Supplying either reserved
origin through the public mutator rejects as `INVALID_ARGUMENT` before receipt
creation.
The next preference revision and exact desired preference bytes (or clear
intent) are frozen in the command receipt or migration journal before touching
the preference file. The file is replaced/removed and its parent fsynced before
the receipt or migration journal advances/fsyncs the retained preference
counter. Startup reconciles a
file/counter mismatch from that durable intent before manager readiness; without
a matching intent it fails closed. This is the transaction boundary across the
separate preference and manager-state files.

Required transitions:

- startup repair resolves preference but always starts with `active = null`;
- installing an unselected model does not change preference or active state;
- selection without a session persists preference and leaves active null;
- initial-load failure leaves preference unchanged and active null;
- switching cancels generation, awaits terminal delivery, awaits unload, clears
  active, then loads the desired fingerprint;
- only after a successful desired load may the controller begin the ordered
  commit: first make the new preference durable, then publish the active
  fingerprint;
- preference is committed before the desired fingerprint is published as
  active. Until then, the successfully loaded desired native session is an
  internal staged session and accepts no inference request;
- if preference persistence/fsync fails, do not publish active: unload the
  staged desired session, then attempt the old-fingerprint reload. Successful
  recovery restores old active/preference; failed recovery ends explicitly
  unloaded. If staged-session unload itself fails, retain its lease and session
  ID as a process-global fault blocker, reject inference and mutation with
  `UNLOAD_FAILED`, and require the orphan-unload recovery path;
- failed desired load preserves the old preference and attempts to reload its
  previous fingerprint; failed recovery ends explicitly unloaded;
- failed unload retains old active/preference and aborts the switch;
- delete of a selected or loaded model first completes a switch to a committed
  fallback when one exists. If it is the only valid installation, unload it,
  atomically clear/fsync the preference, then delete under exclusive authority;
  preference-clear failure aborts deletion, while later delete failure leaves a
  valid but unselected installation and an explicit error; and
- process death always yields active null and preserves durable preference.

On a full JavaScript VM reload, native sessions and leases survive. The app must
enumerate blocking session IDs and unload any orphan before enabling mutation;
it must never infer active state from preference.

Fallback for missing/corrupt/unknown/deleted preference is deterministic: first
the installed valid recommendation, then the first installed valid catalog
entry, otherwise null. Persist a fallback preference only after repair and under
mutation authority. Manual selection of an invalid or uninstalled model fails.

## Native repository, leases, and canonical paths

Each platform owns one process-lifetime `ModelRepository`, shared by inference
and model management and never owned by React state. A bound read-lease key is
model ID, publication ID, and canonical file identity.

- Load first obtains a per-model pending admission that excludes writers. While
  holding it, native code performs no-follow path validation/open and obtains
  canonical file identity from the opened handle. It atomically promotes the
  pending admission to the bound `(modelId, publicationId, canonical file
  identity)` read lease before writer exclusion can lapse, and holds that lease
  through join-before-free destruction.
- Publish, replace, delete, and repair require an exclusive lease.
- A writer never calls unload while holding exclusive authority. It returns
  `MODEL_IN_USE` with blocking session IDs; the switch controller unloads and
  retries.
- Failed load releases its pending read. Failed unload retains the read.
- Writer acquisition is fair. Commands for one model serialize. File work for
  different models may overlap, although application policy permits only one
  resident inference session.
- Lock order is repository coordinator, per-model lease, then bridge lifecycle
  admission. Teardown releases its lease only after native destruction and
  outside repository callbacks.

Production roots are native-derived:

```text
iOS:     <ApplicationSupport>/PocketLM/Models
Android: <filesDir>/PocketLM/Models
```

The repository layout is fixed for v1.1:

```text
<root>/selected-preference.json
<root>/migration-v1-to-v2.json              # present only during migration
<root>/manager-state-v1.json                # revision, transfers, command receipts
<root>/<appDirectoryName>/model.gguf
<root>/<appDirectoryName>/manifest.json
<root>/<appDirectoryName>/commit.json
<root>/.staging/<modelId>/<operationId>/...
<root>/.rollback/<modelId>/<publicationId>/...
<root>/.quarantine/<modelId>/<quarantineId>/...
<root>/.deleting/<modelId>/<commandId>/...
```

Each quarantine directory contains one closed `quarantine.json` record:

```ts
type QuarantineReasonV1 =
  | 'INVALID_ACTIVE'
  | 'UNAUTHORIZED_STAGING'
  | 'AMBIGUOUS_STAGING'
  | 'INVALID_ROLLBACK'
  | 'AMBIGUOUS_ROLLBACK'
  | 'PUBLICATION_FAILED'
  | 'MISSING_COMMIT_MARKER'
  | 'PROTECTION_DRIFT'
  | 'BACKUP_EXCLUSION_DRIFT'
  | 'MIGRATION_CONFLICT';

type QuarantineRecordV1 = {
  schemaVersion: 1;
  quarantineId: string;
  modelId: string;
  publicationId: string | null;
  sourceKind: 'active' | 'staging' | 'rollback';
  reason: QuarantineReasonV1;
  createdManagerRevision: string;
  quarantinedAt: string;
  byteSize: number;
};
```

The record is immutable after the quarantine directory and its index entry are
durable. A replacement quarantine always receives a new quarantine ID.
`byteSize` is the exact sum of regular-file bytes retained from the quarantined
generation, excluding `quarantine.json` itself, and is included in
install/replacement disk-space preflight. A
quarantine is never loadable. At most one quarantine is retained per model. If
repair encounters more than one, it retains the record with the greatest
canonical manager revision and removes older entries only after repair has
completed; equal revisions or malformed records fail closed. There is no
age-based deletion. The retained newest quarantine remains until a successful
reinstall/replacement commits that model or the user explicitly chooses
`Delete damaged files`. A successful commit makes removal mandatory; repair is
not complete until directory removal, parent fsync, and the manager-state index
replacement are durable. When no valid active
generation exists but a quarantine does, the snapshot reports `invalid`, and
the user-visible actions are `Retry install` and `Delete damaged files`.
`Delete damaged files` invokes the quarantine-target branch of
`deleteInstallation`; its receipt freezes the exact quarantine ID before any
rename or removal.

The manager-state `quarantines` array is the durable index of these records and
must agree field-for-field with every retained `quarantine.json`. Quarantine
directory creation/rename and parent fsync precede the manager-state replacement.
Startup may index a uniquely valid crash-left directory; an indexed missing
directory, byte/count disagreement, or ambiguous directory set fails closed
before cleanup or manager readiness.

`<appDirectoryName>` is the only active/loadable generation. A staging directory
contains a complete candidate generation. A rollback directory contains the
previous complete generation while replacement is being promoted. Staging,
rollback, and quarantine live under the same native storage volume as the active
directory so directory renames are atomic. None is addressable by the production
load API.

The native repository root and every transient model/resume-data location are
excluded from backup before model bytes are written. iOS also applies the
documented file-protection class and restrictive permissions at directory
creation; Android's built artifact must prove matching backup-rule exclusion.
Publication fails closed if the platform cannot establish or verify the required
protection.

`resolveLoadPath(modelId)` may expose the exact path of a committed publication
for compatibility with the existing load API, but the bridge trusts no
JavaScript path. Native code validates strict scalar UTF-8/no NUL, exact expected
path, every path component with `lstat`, no symlink, a regular final file, real
path containment under the exact root, stable file identity while leased,
single-link ownership where supported, and matching record/marker/catalog.
Traversal, percent tricks, prefix collisions, case aliases, hardlinks, staging,
rollback, quarantine, and uncommitted paths are rejected.

Tests use a separately compiled `POCKETLM_ALLOW_TEST_MODEL_PATH` entry point.
The production bridge cannot reach it.

## Device probe snapshot v1

```ts
type ProbeLimitation =
  | 'AVAILABLE_MEMORY_UNKNOWN'
  | 'CPU_FREQUENCY_UNKNOWN'
  | 'SIMULATOR_HOST_FACTS';

type ProbeSnapshotCommonV1 = {
  schemaVersion: 1;
  isSimulator: boolean;
  totalMemoryBytes: number;
  availableMemoryBytes: number;
  activeProcessorCount: number;
  processorCount: number;
  freeDiskBytes: number;
  limitations: ProbeLimitation[];
};

type IOSProbeSnapshotV1 = ProbeSnapshotCommonV1 & {
  platform: 'ios';
  android?: never;
};

type AndroidProbeSnapshotV1 = ProbeSnapshotCommonV1 & {
  platform: 'android';
  android: {
    isLowRamDevice: boolean;
    onlineProcessorCount: number;
    maxFrequencyKhzByCpu: (number | null)[];
    arm64DotProduct: boolean;
    pageSizeBytes: number;
  };
};

type ProbeSnapshotV1 = IOSProbeSnapshotV1 | AndroidProbeSnapshotV1;

interface DeviceProbeSpec {
  getSnapshot(): Promise<ProbeSnapshotV1>;
}
```

Numbers are finite nonnegative safe integers; processor counts are positive and
active does not exceed total when known. A missing CPU frequency is null, not
zero. Android's `maxFrequencyKhzByCpu` length is exactly `processorCount`.
iOS uses raw `availableMemoryBytes = 0` as the unknown sentinel and shared
policy normalizes it to null. Simulator facts remain advisory and never hide or
block a model. A missing/rejected/malformed module selects a safe policy fallback
and makes no recommendation claim. The probe has no mutators and logs no device
identifier. Android snapshots require `android`; iOS snapshots forbid it.
Limitations are unique and appear in the enum order above.
`AVAILABLE_MEMORY_UNKNOWN` is present exactly for iOS when
`availableMemoryBytes == 0` and is forbidden otherwise.
`CPU_FREQUENCY_UNKNOWN` is present exactly for Android when at least one
frequency array element is null and is forbidden otherwise.
`SIMULATOR_HOST_FACTS` is present exactly when `isSimulator` is true.

## Runtime policy profile v1

Policy is a pure shared function over a validated catalog and probe. Catalog
order from first to last is increasing recommendation rank. Recommendation
chooses the greatest-index catalog model whose `recommendedRamBytes` is no
greater than `totalMemoryBytes`. If none qualifies, it chooses the first catalog
model whose `minTotalRamBytes` is no greater than total memory. If no model
meets its minimum, recommendation is null. A missing, rejected, or malformed
probe likewise produces recommendation null and no device-fit claim.
Recommendation profile v1 uses total memory only. Available memory,
`isLowRamDevice`, disk, processor frequency, dot-product support, and benchmark
results may produce diagnostics or preflight failures but do not change the
recommended model.

This recommendation never overwrites a durable `manual` preference. A user may
manually select any committed valid model even below its recommended or minimum
RAM value; it remains visible and receives a warning rather than a block.
Simulator results use the same calculation for preview but are explicitly
advisory, make no physical-device claim, and never hide or block a choice.

The profile-v1 session configuration is exact:

```text
contextSize = selected catalog entry.initialContextTokens
requestedAccelerator = auto
gpuLayers = 0
policyProfileVersion = 1
```

Generation `nThreads` is resolved independently on every request:

- missing or malformed probe: `0` (native automatic selection);
- iOS: `min(activeProcessorCount, 4)`;
- Android with any null frequency: `min(activeProcessorCount, 4)`; and
- Android with all frequencies known: let `M` be the maximum frequency, count
  entries `f` satisfying the exact integer comparison `10 * f >= 9 * M`, and
  clamp the result to `[1, min(activeProcessorCount, 4)]`.

Checked integer arithmetic is used for the 90-percent comparison. Policy does
not persist benchmark calibration, retune automatically, or change a loaded
session merely because the per-request thread count changes. Boundary fixtures
include at least:

| Input | Expected recommendation/result |
| --- | --- |
| total RAM `2147483647` | null |
| total RAM `2147483648` | 0.5B by minimum |
| total RAM `4294967295` | 0.5B |
| total RAM `4294967296` | 0.5B by recommendation |
| total RAM `6442450943` | 0.5B |
| total RAM `6442450944` | 1.5B by recommendation |
| missing/malformed probe | recommendation null; safe configuration and `nThreads = 0` |
| iOS active processors `1`, `4`, `5` | threads `1`, `4`, `4` |
| Android frequencies `[100, 90, 89]` | threads `2` |
| Android frequencies `[100, null, 90]`, active `3` | threads `3` |
| Android eight qualifying frequencies, active `1` | threads `1` |

The safe configuration used when probe facts are absent remains context 2,048,
AUTO, GPU layers 0, policy profile 1, and native automatic threads 0. It is a
runtime fallback only and carries no recommendation claim.

## Model-manager snapshot and API

Installation and transfer are separate axes so a failed replacement does not
erase an existing committed installation.

```ts
type InstallState =
  | 'missing' | 'committed' | 'invalid' | 'repairing' | 'deleting';

type TransferState =
  | 'idle' | 'queued' | 'downloading' | 'pausing' | 'paused'
  | 'verifying' | 'awaitingPublication' | 'publishing' | 'cancelling'
  | 'failed';

type ModelManagerErrorCode =
  | 'CATALOG_UNSUPPORTED' | 'MODEL_UNKNOWN' | 'INVALID_ARGUMENT' | 'INVALID_STATE'
  | 'STALE_REVISION' | 'INSUFFICIENT_SPACE' | 'NETWORK' | 'HTTP_STATUS'
  | 'RESUME_INVALID' | 'VALIDATOR_CHANGED' | 'RANGE_INVALID'
  | 'BACKGROUND_RESTRICTED' | 'BACKGROUND_TIMEOUT' | 'HASH_MISMATCH'
  | 'GGUF_INVALID' | 'GGUF_BOUNDS' | 'METADATA_MISMATCH'
  | 'CATALOG_DRIFT' | 'PATH_REJECTED' | 'MODEL_IN_USE'
  | 'UNLOAD_FAILED' | 'STORAGE_IO' | 'BACKUP_EXCLUSION_FAILED'
  | 'CANCELLED_BY_SYSTEM' | 'INTERNAL';

type ModelManagerError = {
  code: ModelManagerErrorCode;
  message: string;
};

type ModelManagerWarning = {
  code: 'NOTIFICATION_DENIED';
  message: string;
};

type ModelSnapshot = {
  modelId: string;
  installState: InstallState;
  publicationId: string | null;
  transfer: {
    state: TransferState;
    operationId: string | null;
    expectedBytes: number;
    bytesReceived: number | null;
    durablePartialBytes: number | null;
    hasResumeData: boolean;
    canPause: boolean;
    canResume: boolean;
    error: ModelManagerError | null;
    warnings: readonly ModelManagerWarning[];
  };
  blockers: {
    sessionIds: number[];
    mutationPending: boolean;
  };
};

type ManagerSnapshotV1 = {
  schemaVersion: 1;
  revision: string;
  catalogDigest: string;
  selectedPreference: SelectedPreferenceV1 | null;
  models: ModelSnapshot[];
  repairComplete: boolean;
};
```

Snapshot validity is normative:

- `models` contains exactly the current catalog models in catalog order.
  `modelId` comparisons remain exact and case-sensitive.
- A nonnull `selectedPreference` names exactly one catalog model whose same
  snapshot entry is `committed`; any missing, unknown, duplicate, or
  noncommitted target makes the entire snapshot malformed.
- `publicationId` is a valid nonzero publication ID exactly when
  `installState == 'committed'`; it is null for `missing`, `invalid`,
  `repairing`, and `deleting`. `repairing` is allowed only while
  `repairComplete == false`; once repair completes no model remains in that
  state. `repairing` and `deleting` require transfer `idle`. Missing,
  committed, or invalid installations may have an active install/replacement
  transfer.
- `expectedBytes` always equals the current catalog entry's `byteSize`.
  `operationId` is null exactly for `idle` and is a valid nonzero operation ID
  for every other transfer state. `error` is nonnull exactly for `failed`.
- `bytesReceived` is null for `idle`; otherwise it is null or an integer in
  `[0, expectedBytes]`. If present during `verifying`,
  `awaitingPublication`, or `publishing`, it equals `expectedBytes`.
- iOS always reports `durablePartialBytes = null`. Android reports null when it
  owns no resumable partial; otherwise it reports the exact durable owned byte
  count in `[0, expectedBytes]`. It is null in `idle`, `verifying`,
  `awaitingPublication`, and `publishing`.
- Android always reports `hasResumeData = false`. On iOS it may be true only in
  `queued`, `downloading`, `pausing`, `paused`, or `failed`, while the opaque
  blob remains durably owned. `canPause` is true exactly in `queued` or
  `downloading`. `canResume` means that `resumeInstall` is currently accepted
  and is true exactly in `paused`, including an iOS pause with no resume data;
  that case restarts from the original pinned URL. A failed transfer is retried
  with `startInstall`, which creates a new operation and clears its old error.
- `warnings` is empty on iOS. Android warnings are unique, in enum order, and
  empty for `idle`; `NOTIFICATION_DENIED` never makes the transfer failed.
- `sessionIds` always enumerates every positive Int32 native session currently
  holding or acquiring a read lease for that model, unique and numerically
  ascending, even when no writer is pending. This is the reload/orphan discovery
  channel, not merely a list populated by an active mutation.
- `mutationPending` is true exactly while a repository writer is queued/held or
  repair/delete mutation is being reconciled. It is true for `repairing`,
  `deleting`, `awaitingPublication`, and `publishing`, and can also be true for a
  committed idle model during delete's selection-release phase. Ordinary
  `queued`, `downloading`, `pausing`, `paused`, and `verifying` transfers do not
  set it unless an independent repository writer is actually queued. A
  nonempty session list or a live transfer receipt does not by itself set
  `mutationPending`.

Any violation makes the snapshot malformed and triggers the shared safe-policy
fallback; consumers do not partially interpret it.

`revision` is a monotonic decimal string, never a JavaScript number. Every state
mutation is durable before its event or Promise completes. Progress events carry
only revision and model ID and prompt a fresh snapshot read.
`catalogDigest` is lowercase SHA-256 of the exact bundled repository
`models/catalog.json` bytes and must match the independently embedded digest.

Android reports exact `durablePartialBytes` for its closed/current owned partial.
iOS always reports it as null and exposes only whether opaque resume data exists;
that blob, URLs, and validators never cross or enter logs. `bytesReceived` is
nullable UI progress, not publication authority. Cancel is permanent and removes
staging/resume state. Pause may yield a paused state without resume data;
`resumeInstall` remains accepted and restarts from the pinned original URL.
Repeated control commands are
idempotent. Failed replacement preserves the old committed publication.
For an `invalid` model backed only by quarantine evidence, `startInstall` is the
`Retry install` action and `deleteInstallation` is the `Delete damaged files`
action. Neither action makes quarantined bytes loadable; both remain subject to
revision, receipt, lease, and repair-complete rules.

Stable terminal/rejecting error codes:

```text
CATALOG_UNSUPPORTED MODEL_UNKNOWN INVALID_ARGUMENT INVALID_STATE STALE_REVISION
INSUFFICIENT_SPACE NETWORK HTTP_STATUS RESUME_INVALID VALIDATOR_CHANGED
RANGE_INVALID BACKGROUND_RESTRICTED BACKGROUND_TIMEOUT
HASH_MISMATCH GGUF_INVALID GGUF_BOUNDS METADATA_MISMATCH CATALOG_DRIFT
PATH_REJECTED MODEL_IN_USE UNLOAD_FAILED STORAGE_IO BACKUP_EXCLUSION_FAILED
CANCELLED_BY_SYSTEM INTERNAL
```

`NOTIFICATION_DENIED` is recorded only in `warnings` and is nonfatal on Android
13+. Error and warning messages are single-line diagnostics of at most 512 UTF-8
bytes and exclude paths, URLs, validators, resume data, and device identifiers.

```ts
interface ModelManagerSpec {
  getSnapshot(): Promise<ManagerSnapshotV1>;
  startInstall(modelId: string, commandId: string, expectedRevision: string): Promise<void>;
  pauseInstall(modelId: string, operationId: string, commandId: string, expectedRevision: string): Promise<void>;
  resumeInstall(modelId: string, operationId: string, commandId: string, expectedRevision: string): Promise<void>;
  cancelInstall(modelId: string, operationId: string, commandId: string, expectedRevision: string): Promise<void>;
  deleteInstallation(modelId: string, commandId: string, expectedRevision: string): Promise<void>;
  setSelectedPreference(modelId: string, origin: RequestedSelectionOrigin, commandId: string, expectedRevision: string): Promise<void>;
  resolveLoadPath(modelId: string): Promise<{ canonicalPath: string; publicationId: string }>;
  addListener(name: 'onModelManagerChanged'): void;
  removeListeners(count: CodegenTypes.Int32): void;
}
```

`CodegenTypes.Int32` is the React Native 0.83 codegen type imported from
`react-native`, matching the existing inference spec. Pause, resume, and cancel
must match both the operation ID and expected snapshot revision so a delayed
command cannot control a later transfer for the same model.

After a JavaScript VM reload, `activeFingerprint` starts null. The app reads the
snapshot, treats every enumerated session ID as orphaned unless the
process-global inference runtime explicitly reattaches it, invokes the existing
inference module's `unloadModel(sessionId)`, awaits completion, and refreshes the
snapshot before enabling manager mutators. Until reconciliation empties those
session lists, mutators that require conflicting authority reject `MODEL_IN_USE`
and a refreshed snapshot continues to expose the same IDs; no new model-manager
unload API is introduced.

Replaying the same command ID with the same normalized arguments returns the
same outcome; reuse with different arguments rejects as `INVALID_STATE`. Until
repair completes, mutators reject. Repair is automatic and internal. Preference
changes require a current committed install.

Idempotency is backed by an atomically replaced/fsynced receipt journal inside
`manager-state-v1.json` with this wire shape:

```ts
type ManagerMethod =
  | 'startInstall' | 'pauseInstall' | 'resumeInstall' | 'cancelInstall'
  | 'deleteInstallation' | 'setSelectedPreference';

type ReceiptEffectStep =
  | 'platformOperationStarted' | 'pauseRequested' | 'resumeRequested'
  | 'cancelRequested' | 'selectionReleased' | 'tombstoned'
  | 'preferenceWritten';

type SelectionReleasePlan =
  | { kind: 'fallback'; modelId: string; publicationId: string }
  | { kind: 'clear' }
  | { kind: 'none' };

type PreferenceMutationPlan =
  | { kind: 'write'; nextRevision: string; bytesUtf8: string; bytesSha256: string }
  | { kind: 'clear'; nextRevision: string };

type CommandReceiptV1 = {
  schemaVersion: 1;
  commandId: string;
  method: ManagerMethod;
  modelId: string;
  argumentDigest: string;
  expectedRevision: string;
  targetOperationId: string | null;
  createdOperationId: string | null;
  targetPublicationId: string | null;
  targetQuarantineId: string | null;
  selectionReleasePlan: SelectionReleasePlan | null;
  preferenceMutation: PreferenceMutationPlan | null;
  phase: 'prepared' | 'effectCommitted' | 'terminal';
  effectStep: ReceiptEffectStep | null;
  preparedManagerRevision: string;
  effectManagerRevision: string | null;
  terminalManagerRevision: string | null;
  terminalSuccess: boolean | null;
  terminalErrorCode: ModelManagerErrorCode | null;
};
```

`manager-state-v1.json` is a closed object whose exact persisted UTF-8 file is
at most 4 MiB:

```ts
type DurableTransferV1 = {
  schemaVersion: 1;
  modelId: string;
  operationId: string;
  artifactSha256: string;
  sourceRevision: string;
  sourceFilename: string;
  expectedBytes: number;
  state: Exclude<TransferState, 'idle'>;
  bytesReceived: number | null;
  durablePartialBytes: number | null;
  hasResumeData: boolean;
  error: ModelManagerError | null;
  warnings: readonly ModelManagerWarning[];
};

type ManagerStateV1 = {
  schemaVersion: 1;
  revision: string;
  preferenceRevisionCounter: string;
  catalogDigest: string;
  transfers: readonly DurableTransferV1[];
  commandReceipts: readonly CommandReceiptV1[];
  quarantines: readonly QuarantineRecordV1[];
};
```

There is at most one durable transfer per model; transfers appear in catalog
order and each freezes the exact source/artifact identity for its operation.
No transfer entry means snapshot transfer `idle`. Receipt entries appear in
increasing `preparedManagerRevision`; their phase invariants remain those below.
Quarantine records are in catalog order and obey the one-per-model retention
rule. The bootstrap file is revision `0`, preference revision counter `0`, the
current exact catalog digest, and three empty arrays.

Opaque iOS resume data, HTTP validators and redirected URLs, Android partial
storage details, and enumerated platform task/service handles remain in
platform-native private storage keyed only by `operationId`. They never enter
this shared file, manager snapshots, events, diagnostics, or logs. The shared
durable byte count and resume-data boolean are claims reconciled against that
private state during repair before readiness.

Before a replacement would exceed 4 MiB, the manager first applies the
deterministic completed-receipt eviction rule. It retains at most the 256
completed receipts with greatest terminal revisions plus every nonterminal
receipt. If the exact closed state still cannot fit, readiness or the mutator
fails closed with `STORAGE_IO` before any new external effect.

Nullability and method associations are exact: accepted `startInstall` alone
sets `createdOperationId`; pause/resume/cancel alone set `targetOperationId`;
and accepted preference-change receipts set `targetPublicationId`. Accepted
delete alone sets `selectionReleasePlan` and exactly one immutable target:
`targetPublicationId` for a committed generation or `targetQuarantineId` for a
quarantine-only invalid installation. Every non-delete receipt has null
`targetQuarantineId`. A selected committed target uses `fallback` or `clear`;
an unselected committed target and a quarantine-only target use `none`, with no
preference mutation, although any read lease still must be unloaded before a
committed generation is tombstoned. Delete and preference change set
`preferenceMutation` exactly when they will write or clear preference. For a
write, `bytesUtf8` contains the exact no-BOM preference-file bytes and its digest
must match; for clear, no preference bytes are present. An effect step belongs
only to its same-named
method (`platformOperationStarted` to start, the three request steps to their
controls, `selectionReleased`/`tombstoned` to delete, and
`preferenceWritten` to selection).

Phase nullability and ordering are exact:

- `prepared`: `effectStep`, `effectManagerRevision`, and all terminal fields are
  null;
- `effectCommitted`: the latest `effectStep` and `effectManagerRevision` are
  nonnull and all terminal fields are null;
- `terminal` after an effect retains the latest effect step/revision;
  `terminalManagerRevision` and `terminalSuccess` are nonnull. Terminal success
  has a null error code and terminal failure has a nonnull one;
- `terminal` without an effect has null effect fields. A direct validation
  rejection is stored atomically with
  `preparedManagerRevision == terminalManagerRevision`; and
- an accepted effectful command has strictly increasing prepared, each effect,
  and terminal manager revisions. When delete advances from
  `selectionReleased` to `tombstoned`, the latter replaces the former as the
  retained latest effect step/revision.

The normalized argument digest is lowercase SHA-256 of the UTF-8 bytes
`"PocketLM/model-manager-command/v1\0"` followed by these exact fields separated
by one NUL byte, with no trailing NUL:

```text
startInstall:          startInstall, modelId, expectedRevision
pauseInstall:          pauseInstall, modelId, operationId, expectedRevision
resumeInstall:         resumeInstall, modelId, operationId, expectedRevision
cancelInstall:         cancelInstall, modelId, operationId, expectedRevision
deleteInstallation:    deleteInstallation, modelId, expectedRevision
setSelectedPreference: setSelectedPreference, modelId, origin, expectedRevision
```

The canonical command-digest fixture uses model ID
`qwen2.5-0.5b-instruct-q4-k-m`, expected revision
`100000000000000000000000000000000000000`, operation ID
`11111111111111111111111111111111`, and origin `manual`:

| Method | SHA-256 |
| --- | --- |
| `startInstall` | `5a6eedf062da7828ccf754fbd17eaf179b2c2d4a78a709f83323c3800276315d` |
| `pauseInstall` | `58ae358c1f67be1963c2bb2195412485df16ff6cdf1f8806f62b05bf55ce1a04` |
| `resumeInstall` | `912ce7671ca1bd212a014d69680da299ad11695e83be4cab73a17356d1935197` |
| `cancelInstall` | `f8c8113e7f515f113a8770091cc19132f9f0130861b4101440050861b66d00c8` |
| `deleteInstallation` | `b391396a55a95bf57126c9f14b50419ce519bd94c95d063d6b59d10f71af94d5` |
| `setSelectedPreference` | `d07c6d2d95a88e1fe4890a06b8e9b9904df9d05c8b11de82df97fbbafebffd5e` |

`commandId` is deliberately excluded. Method and model ID are exact
case-sensitive strings; revisions and IDs use their canonical encodings above.
Command-ID lookup is global across all manager methods and models while a receipt
is retained. Syntactically malformed IDs, revisions, model scalars, or origins
reject as `INVALID_ARGUMENT` before receipt creation. For a syntactically valid
new command, receipt lookup happens first, then `expectedRevision` is compared
with the pre-command manager snapshot. Every subsequent rejection—including
unknown model, stale revision, or invalid durable state—is itself durably stored
as a terminal receipt before the Promise rejects. Accepted commands persist a
prepared receipt before effects. Transfer state and receipt state change in the
same manager-state replacement whenever both change.

A matching terminal receipt replays its stored outcome before any current
revision/state check, including after process death. A matching nonterminal
receipt joins its recovery; a different argument digest rejects. Nonterminal
receipts are never evicted. The manager retains the 256 completed receipts with
the greatest `terminalManagerRevision`, globally; eviction removes the smallest
terminal revision first. Atomic state revisions make ties impossible. Replay is
guaranteed only while the receipt is retained, and clients must never reuse an
evicted command ID.

`startInstall` succeeds and its receipt becomes terminal after the operation ID,
transfer state, and platform work handoff are durable—not after the download or
publication completes. Its `platformOperationStarted` effect is persisted before
that terminal receipt. Ordinary queued/downloading/verifying progress thereafter
belongs to the durable transfer state, not a nonterminal command receipt. A
pause/resume/cancel command may target the operation only after the start Promise
has completed and the operation appears in a refreshed snapshot.

Before manager readiness, startup repair resolves every nonterminal receipt
against durable filesystem/OS evidence:

- `startInstall` allocates and persists its operation ID before starting platform
  work. A matching staging/transfer record or enumerated iOS task/Android service
  resumes that operation; absence of all effects resumes creation from the
  prepared intent. It never starts a second operation ID.
- pause, resume, and cancel reconcile only the receipt's target operation ID with
  persisted transfer state, resume data/partial, and enumerated platform work.
  The desired already-achieved state completes successfully; an intermediate
  state resumes the idempotent transition; a different/newer operation resolves
  `INVALID_STATE`.
- delete receipts targeting a committed generation persist its exact target
  publication and a selection-release plan: either the exact committed fallback model/publication or an explicit
  clear-preference plan for the only valid selected installation, or `none` for
  an unselected installation. Their method-specific
  effect phases are `selectionReleased` and `tombstoned`. Before
  `selectionReleased`, replay follows exactly one branch: `fallback` completes
  the switch and writes the frozen fallback preference; `clear` unloads the
  target/orphans and clears the frozen target preference; `none` unloads any
  target lease, never writes or clears preference, and read-validates that the
  durable preference still does not select the target. Every branch then durably
  verifies that the exact target publication is neither selected nor leased.
  Only after that phase is durable may delete atomically rename the
  matching active generation to
  `.deleting/<modelId>/<commandId>` and fsync both parents. Presence of that
  exact-publication tombstone or absence of that same active publication resumes
  deletion and completes success; an untouched matching active generation
  resumes the rename only after rechecking the selection/lease preconditions.
  A different active publication, changed fallback identity, or renewed lease
  fails closed rather than being deleted. Thus replay cannot delete a selected,
  leased, or later publication.
- delete receipts targeting a quarantine-only invalid installation persist the
  exact immutable quarantine ID, null target publication, `none` selection plan,
  and no preference mutation. Replay may rename only that exact directory to
  `.deleting/<modelId>/<commandId>` and fsync both parents before retaining the
  `tombstoned` effect. Its tombstone or absence completes deletion, but a
  different/newer quarantine ID is never removed. Thus `Delete damaged files`
  uses `deleteInstallation` without allowing model-ID-only replay to delete
  later recovery evidence.
- preference change compares the exact durable preference contents; a match is
  success, otherwise the originally validated atomic write is retried only while
  its model/publication precondition still holds.

During startup, no new mutator is admitted while any crash-left
prepared/effect-committed receipt is unreconciled; repair writes its terminal
receipt before exposing readiness. During normal live execution, commands obey
the per-model state machine and serialization rules above; a completed start
receipt does not block later controls for its still-running transfer.

## GGUF inspector ABI 2.2

The core owns bounded parsing. Platforms own complete-file hashing and comparison
with their bundled catalog.

```c
#define POCKETLM_GGUF_FACTS_VERSION 1u
#define POCKETLM_GGUF_ARCH_MAX 64u
#define POCKETLM_GGUF_TOKENIZER_MAX 64u
#define POCKETLM_GGUF_TEMPLATE_MAX (1024u * 1024u)

typedef enum {
    PLM_GGUF_OK = 0,
    PLM_GGUF_INVALID_ARGUMENT,
    PLM_GGUF_IO,
    PLM_GGUF_NOT_REGULAR,
    PLM_GGUF_BAD_MAGIC,
    PLM_GGUF_UNSUPPORTED_VERSION,
    PLM_GGUF_TRUNCATED,
    PLM_GGUF_CORRUPT,
    PLM_GGUF_DUPLICATE_KEY,
    PLM_GGUF_COUNT_LIMIT,
    PLM_GGUF_OVERFLOW,
    PLM_GGUF_MISSING_FIELD,
    PLM_GGUF_WRONG_TYPE,
    PLM_GGUF_INVALID_UTF8,
    PLM_GGUF_FIELD_TOO_LARGE,
    PLM_GGUF_BUFFER_TOO_SMALL,
    PLM_GGUF_INTERNAL
} pocketlm_gguf_result;

typedef struct {
    uint32_t struct_size;
    uint32_t facts_version;
    char *chat_template;
    size_t chat_template_capacity;
} pocketlm_gguf_options_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t facts_version;
    uint32_t gguf_version;
    uint32_t file_type;
    uint64_t file_size;
    uint64_t tensor_count;
    uint64_t metadata_count;
    uint64_t chat_template_length;
    uint64_t required_chat_template_capacity;
    uint32_t architecture_length;
    uint32_t tokenizer_model_length;
    uint32_t tokenizer_pre_length;
    char architecture[POCKETLM_GGUF_ARCH_MAX];
    char tokenizer_model[POCKETLM_GGUF_TOKENIZER_MAX];
    char tokenizer_pre[POCKETLM_GGUF_TOKENIZER_MAX];
} pocketlm_gguf_facts_v1;

pocketlm_gguf_result pocketlm_inspect_gguf_v1(
    const char *path,
    const pocketlm_gguf_options_v1 *options,
    pocketlm_gguf_facts_v1 *out
);
```

No allocation or pointer ownership crosses the ABI. Outputs are length-delimited
UTF-8 and never truncated. The caller zeroes structs and sets exact size/version.
On success, `chat_template_length` is the UTF-8 payload length excluding a
terminating NUL, `required_chat_template_capacity` is that length plus one,
`chat_template_capacity` is the caller allocation size including the NUL, and
the inspector writes the exact payload followed by one NUL.

A null chat-template buffer with capacity zero is the canonical sizing request.
It returns `PLM_GGUF_OK`, returns all trusted facts including
`required_chat_template_capacity`, and writes no template bytes. A nonnull
buffer whose capacity is smaller than the required capacity returns
`PLM_GGUF_BUFFER_TOO_SMALL`, writes no partial template, and defines only
`required_chat_template_capacity`; every other output field is zero. On every
other writable-output error all output fields are zero. A null buffer with
nonzero capacity, or a nonnull buffer with zero capacity, is
`PLM_GGUF_INVALID_ARGUMENT`.

The fixed architecture/tokenizer lengths likewise exclude their required
trailing NUL. An empty chat template is valid parser output with length zero and
required capacity one; the platform catalog comparison rejects it as
`METADATA_MISMATCH` because the catalog requires `nonEmpty: true`. A template
payload over 1 MiB fails with `PLM_GGUF_FIELD_TOO_LARGE`; the maximum successful
caller allocation is therefore 1 MiB plus one byte.

GGUF facts version 1 accepts GGUF wire version 3 only. After matching the GGUF
magic, wire versions 1, 2, 4, and every other value return
`PLM_GGUF_UNSUPPORTED_VERSION`; no metadata field is interpreted and all
writable facts are zeroed.

Platform adapters map inspector and comparison outcomes exactly:

- bad magic, unsupported version, truncation, corrupt structure, duplicate key,
  missing field, wrong type, or invalid UTF-8 -> `GGUF_INVALID`;
- count limit, arithmetic overflow, or field too large -> `GGUF_BOUNDS`;
- inspector I/O -> `STORAGE_IO`, and non-regular/path rejection ->
  `PATH_REJECTED`;
- invalid arguments, internal errors, or a buffer-sizing protocol violation by
  the adapter -> `INTERNAL`; and
- a successfully parsed file whose facts disagree with the frozen catalog,
  including an empty template, -> `METADATA_MISMATCH`.

`CATALOG_DRIFT` remains reserved for the bundled catalog byte identity changing
against an already durable manager operation; GGUF fact disagreement itself is
`METADATA_MISMATCH`. Complete-file digest disagreement remains `HASH_MISMATCH`.

Parser limits to fixture before implementation:

- tensors: 10,000,000;
- metadata entries: 65,536;
- array elements: 5,000,000;
- key: 64 KiB;
- architecture and tokenizer strings: 63 bytes plus terminator; and
- chat template: 1 MiB.

All additions, multiplications, and seeks are checked against `uint64_t` and the
actual file size. The inspector never constructs an inference session, hashes a
file, parses a catalog, or compares expectations.

## Publication and crash recovery

Candidate construction and publication ordering are normative:

1. create an operation-scoped directory under `.staging`;
2. stage and close `model.gguf` there;
3. hash the full closed file, inspect it, and compare its facts;
4. fsync the model file;
5. apply and verify restrictive permissions, the iOS protection class and backup
   exclusion, or Android's runtime-directory policy plus build-verified backup
   rule, before any record may assert `backupExcluded: true`;
6. write/fsync/rename `manifest.json` inside the staging directory;
7. write/fsync/rename `commit.json` last inside the staging directory;
8. fsync the complete staging directory and its parents; create/fsync the
   model-specific rollback parent and require that no unresolved rollback entry
   exists for the model;
9. acquire exclusive authority or enter `awaitingPublication`;
10. if an active generation exists, atomically rename the entire active
   `<appDirectoryName>` directory to
   `.rollback/<modelId>/<oldPublicationId>` and fsync both parents;
11. atomically rename the complete staging generation directory to the active
    `<appDirectoryName>` path and fsync the model root;
12. reopen the new active generation and revalidate identity, record/marker,
    permissions, file protection, and backup exclusion, then expose its committed
    snapshot;
13. retire the rollback generation only after the new active generation is
    durably visible and revalidated; and
14. update preference only when its transition rules allow.

Any failure from the start of active-directory rename through post-rename fsync
and revalidation first atomically moves the candidate active directory to a
same-volume quarantine path and fsyncs those parents. If a rollback exists, the
writer then atomically restores it to the active path and fsyncs the model root
before reporting failure. With no prior generation, the model remains missing.
If process death interrupts that recovery, startup applies the active/rollback
matrix below. A failed replacement therefore cannot leave the candidate blocking
rollback restoration, and the active path is never a mixture of model bytes,
record, and marker from different publications.

Startup repair runs before manager readiness under exclusive authority and uses
the following deterministic cases:

- active valid, rollback absent: keep active;
- active valid, rollback present: keep active and retire rollback because the
  directory promotion completed;
- active absent, one valid rollback present: restore rollback to active;
- active absent, valid staging and valid rollback present: restore rollback;
  keep staging resumable or quarantine it according to transfer state;
- active invalid, valid rollback present: quarantine active, restore rollback;
- active invalid and rollback absent: quarantine active and establish that the
  active generation is missing; because retained quarantine evidence exists,
  the public snapshot reports `invalid` until retry or explicit damaged-file
  deletion;
- active absent with only invalid rollback state: quarantine that rollback and
  establish the same missing-active/invalid-snapshot result;
- active absent, valid complete staging and no rollback: promote staging only
  when its persisted transfer state authorizes `awaitingPublication`;
- multiple staging candidates: only the one exact directory named by the
  persisted transfer's `operationId` may proceed, and only when it is the unique
  complete valid candidate. Unauthorized or ambiguous candidates are
  quarantined and repair fails closed rather than choosing by time or path;
- a complete staging generation without an authorizing durable transfer is
  quarantined and never promoted;
- multiple rollback candidates, disagreement, invalid marker, or any remaining
  ambiguous persisted state: fail closed and require explicit repair evidence
  rather than guessing; and
- partial staging is resumable or quarantined but never loadable.

Preference never makes an uncommitted artifact loadable. Cleanup and quarantine
retention cannot run until repair has selected exactly one valid active
generation or established that the model is missing.

## Required fixture families

The language-neutral corpus root is
`fixtures/expansion-gate-0/fixture-set-v1`. Its closed inventory pins every
member's exact bytes and SHA-256; the family files below are contract data only
and do not activate any production schema.

- Canonical: persisted and migration timestamp grammar; arbitrary-precision
  decimal validation/comparison/increment; lowercase digest and nonzero ID
  grammar; exact raw-byte digests; six normalized command digests; and the
  runtime-fingerprint vector.
- Catalog: valid one/two-entry v2; legacy v1; empty/unknown; duplicate identity;
  exact and ASCII-casefold ID/directory/resolved-path collision; unsafe names;
  repository grammar and exact source/license URL mismatch; integer bounds;
  RAM inversion; unknown metadata
  key/predicate; UTF-8 exact-comparison, size/hash/fragment, metadata, and
  template mismatch; non-Apache license, mutable/wrong-revision license URL, and
  license size/hash drift; exact authenticated 0.5B/1.5B template equality; and
  all policy byte fields at their exact boundaries.
- Installation: real schema-1 pair; valid v2 per model; unknown/illegal selected
  fields; artifact/path/publication/marker disagreement; invalid time; backup
  exclusion false; record without marker; incomplete/complete staging; active
  moved to rollback; active plus rollback; invalid active with and without valid
  rollback; invalid-only rollback; authorized, unauthorized, and multiple
  staging; unresolved multiple rollbacks; uniquely adoptable and stray
  markerless records; adoptable migration metadata; quarantine-on-recovery;
  protection/exclusion failure before marker; and post-promotion
  protection/exclusion drift with rollback restoration.
- Quarantine: closed valid and unknown-field records; every stable reason;
  equal-revision ambiguity; greatest-revision retention after repair;
  one-per-model indexing; corrupt or missing record disagreement; no age-based
  deletion; preflight byte accounting; never-loadable behavior; retry,
  successful-reinstall, and explicit damaged-file deletion outcomes.
- Preference: every origin; missing/unknown/corrupt/newer; selected deletion and
  deterministic fallback; migration crash before/after v2 marker and preference;
  preference fsync retry; canonical persisted timestamps; every accepted and
  rejected migration-source timestamp form; arbitrary-precision revision
  increment/comparison; the exact 129-byte preference vector and newline
  omission counter-vector; exact raw-byte source-manifest digest; every
  migration phase; 1 MiB boundary; unknown field; and
  journal/source/target/preference
  disagreement.
- Snapshot: every install/transfer/error/warning state; invalid combinations;
  Android exact partial; iOS null partial and resume cases; stale revision;
  receipt-before-revision replay after process death; different-argument command
  ID reuse; malformed argument with no receipt; globally colliding/all-zero IDs;
  exact digest tuple for every method; direct terminal rejection; active-receipt
  non-eviction; deterministic global 256-receipt eviction; canonical manager
  arbitrary-precision revision increment/comparison, phase nullability, and
  effect-revision ordering; selected fallback/clear and unselected `none`
  deletion plans; start-handoff terminal timing; and crash at
  prepared/effect-committed/terminal for every
  mutator, including OS task enumeration and delete tombstone recovery. Manager
  state fixtures include bootstrap, closed/unknown-field rejection, the 4 MiB
  boundary, platform-private-data exclusion, durable transfer invariants, and
  exact completed/nonterminal receipt retention.
- Probe and policy: every limitation and exact iff invariant; iOS/Android closed
  shapes; frequency-array length; missing/malformed/simulator behavior; all RAM
  boundaries above; manual-origin precedence and warnings; reserved-origin
  rejection; iOS/Android/missing-probe thread vectors; safe configuration; and
  the exact runtime-fingerprint vector.
- Paths: traversal and encoding tricks; prefix/wrong-case; invalid scalars/NUL;
  symlink parent/final; hardlink; outside root; staged/quarantined; marker drift.
- Leases: multiple readers; queued writer; load/unload failures; destroy before
  release; React reload/orphan unload; blocked publish/delete; separate-model
  file concurrency; preference-write failure after desired load; staged desired
  unload failure; old-fingerprint recovery; and only-install deletion with
  preference-clear/delete failure windows.
- GGUF: valid minimal facts; exact caps and cap+1; truncation at every field; bad
  magic/version; overflow counts; duplicate/invalid UTF-8/wrong-type/missing
  metadata; parser-success empty template followed by metadata mismatch;
  oversized template; expectation mismatch; successful null/zero sizing;
  buffer-too-small with only required capacity defined; zero outputs on other
  errors; exact result-code mapping; exact payload/capacity/NUL behavior; and
  proof that no inference session is constructed.

All byte-bearing fixtures include the exact file bytes and detached digest.
Every invalid fixture declares one primary stable rejection class. It may
combine correlated violations when all lead to that same outcome; a fixture
used to establish result-code precedence isolates the competing rule. Behavioral
path, lease, publication, and crash fixtures use deterministic scenario
descriptions and barriers rather than timing races.

## Gate 0B non-activation boundary

Gate 0B changes only this contract, its decision record, the Protocol 2.1
documentation amendment, the language-neutral fixture corpus, its test-only
Ruby verifier, and fast-verification wiring that invokes that verifier. It does
not change production TypeScript/Ruby/C++ schema readers, the production
schema-1 catalog, CMake, codegen ownership or output, JNI/Objective-C++
adapters, Android or iOS runtime behavior, downloaders, persistence activation,
or the built C ABI.
Fixture-v2 catalog entries are test data only; the second production catalog
model is added only after the serialized activation gates below.

## Contract-sensitive landing constraints

The serialized shared-foundation chain is:

1. ADR and golden fixture definitions.
2. Gate 1 packaging/codegen foundation: root static/PIC CMake policy, codegen
   ownership move exactly once, minimal Android generation, isolated iOS SDK
   packaging, durable generic XCTest lane, and catalog resource identity.
3. Gate 2 dual-read catalog/record code, shared manager/snapshot/spec and switch
   definitions, and migration/switch tests against fake authority while
   production catalog/storage remain v1. These tests are not native acceptance.
4. Accept the Gate 3B ABI 2.2 inspector and Gate 4A/4C platform-native
   repositories: exclusive mutation, committed-path admission/read leases,
   startup repair, hash/GGUF/catalog validation, native readers/writers, and
   durable preference/receipt handling. Both native consumers must be green
   before changing the shared production catalog.
5. Gate 4D activates catalog v2 with one model: real iOS legacy migration under
   exclusive authority and Android fresh v2 bootstrap (plus native legacy-fixture
   conformance, never a production schema-1 writer). It then accepts durable
   preference/fingerprint/switch integration with compiled two-entry test
   catalogs on real repositories (internal desired load, preference/fsync, then
   expose active). Only afterward does it add the authenticated 1.5B entry and
   rerun the named real-core 0.5B↔1.5B switch subset on both platforms.

After Gate 1 is accepted, Android native CPU packaging may proceed in parallel
with the Gate 2 catalog/runtime chain because it cannot change catalog,
persistence, switch, or snapshot contracts. The C ABI 2.2 inspector core/host
tests may overlap only the tail of Gate 2 and must be accepted before either
platform adapter consumes it. Repository/lease/path implementations follow the
shared switch-state definitions, but precede production migration/selection
activation. The model-manager snapshot/spec lands exactly once in Gate 2 before
platform implementations. Gate 5B download engines consume the already accepted
repositories and activation flow; they do not introduce the first lease authority.
Gate 4A/4C development seeding is a compiled test-only transport seam beneath
the existing `startInstall` flow: host byte delivery only, native normal receipts/
authorizing transfer/validation/publication, no new public API or persisted shape,
and no shipped release override. The bundled catalog `schemaVersion` governs
production activation; test catalogs/seams never enable production behavior.
Authenticated model pins/policy definitions stay frozen from Gate 0B; final
release configuration/version/claim validation lands at Gate 6, separate from
Gate 4D's second-model feature activation.

Codegen/lockfiles, schema activation/migration, ABI/consumers, switch mutation
state, and shared snapshot enums must never be changed concurrently.

## Open overall Gate 0 evidence

Gate 0B's contract and fixture freeze is accepted. The following still prevent
overall Gate 0 exit:

- exact attached Android and iOS hardware facts;
- assigned Linux/KVM installation evidence for the API-36 Google APIs x86_64
  image revision 7 and API-36 Google APIs 16 KiB x86_64 image revision 7;
  macOS arm64 CMake `3.31.6` and both arm64 image revisions were recorded on
  2026-08-23; and
- final overall closure/owner-readiness review against the authoritative
  `docs/implementation-logs/GATE_0_ORCHESTRATION.md` checklist.

The 2026-10-03 planning reconciliation moves new prebuild/XCTest/device-SDK
implementation acceptance to Gate 1, Android emulator/native execution to
Gates 3A/4A, and final platform qualification to Gate 6. It does not waive those
proofs or change frozen contract semantics. Recheck worktree/tool/capacity
readiness separately before dispatch; historical host evidence is not current
build headroom. Overall Gate 0 remains open.

These items may refine open values but may not weaken the frozen ownership,
lifetime, publication, path-safety, or versioning rules.
