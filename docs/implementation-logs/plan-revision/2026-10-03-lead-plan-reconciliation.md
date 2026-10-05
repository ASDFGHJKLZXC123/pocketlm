# Expansion plan reconciliation — 2026-10-03

Status: documentation reconciliation ACCEPTED after exact Claude Opus 5.5
follow-up ACCEPT WITH NONBLOCKING NOTES and fresh independent ACCEPT, including
final note dispositions. Overall Gate 0 remains open; no feature dispatch.

## Authority and scope

The user authorized updating the build plan and sending it to Claude CLI with
Opus 5.5 for validation/review. The inherited `../AGENTS.md` requires Claude
planning review before execution and Claude implementation plus fresh independent
verification/logs for later code work. This pass changes documentation only.
Starting Gate 1, changing runtime/storage/catalog/ABI, installing dependencies,
cleaning disk/worktrees, signing, committing, and publishing are outside this pass.

Pre-edit checkpoint: clean `codex/gate-0b-contract-fixtures` at
`8e6c4adef7a0c7fc6015b2b28460fbf7875d671e`.

## Changes

- Remove the Gate 0/Gate 1 prerequisite cycle; preserve later build/device proof
  at its owning gate and keep hardware/Linux/final Gate 0 review open.
- Mark Gate 0B and 1.5B authentication accepted; distinguish frozen fixture
  definitions from future production and native-language conformance.
- Limit Gate 2 to shared definitions/readers/fake-authority tests; explicitly
  assign iOS native repository readiness to Gate 4C and serialized production
  activation to Gate 4D after both platform foundations and the inspector.
- Align the landing chain/diagram: shared readers/tests → native readiness →
  one-model v2 migration → durable preference-before-active switching → 1.5B.
- Add explicit receipt/replay, quarantine cleanup/target identity, orphan/failed
  unload, path-lease admission, and ABI/GGUF acceptance links without changing
  the frozen contract semantics or fixture bytes.
- Reconcile agent staffing with inherited Claude implementation/independent
  verification rules; retain original reviewers in historical records.
- Preserve dated acceptance history and add current workspace/disk checkpoint
  and mandatory per-dispatch refresh.

Changed controls:

- `docs/plans/2026-08-07-ios-android-expansion-implementation-plan.md`
- `docs/implementation-logs/GATE_0_ORCHESTRATION.md`
- `docs/implementation-logs/GATE_0_BASELINE.md`
- `docs/contracts/EXPANSION_GATE_0_CONTRACTS.md` (landing/remaining-work sections only)
- `docs/contracts/EXPANSION_GATE_0_DECISIONS.md` (append-only current-status pointer)
- `docs/implementation-logs/GATE_0B_CONTRACT_FIXTURES_2026-08-23.md`
  (current-status pointer only)

Review evidence belongs beside this file:

- `2026-10-03-claude-code-plan-review.md`
- `2026-10-03-verifier-plan-review.md`

## Verification performed by the lead

- `git status --short --branch`: clean before edits; documentation-only changes
  afterward on the same branch.
- `git rev-parse HEAD main origin/main`: active `8e6c4ad`, local main `561c66d`,
  cached origin/main `6f9de4a`; no remote refresh/push.
- `git worktree list --porcelain`: historical G0-A/M4R paths absent/prunable;
  no cleanup attempted.
- `df -k .`: 12,770,476 KiB / 12.18 GiB at this snapshot; above the iOS
  verifier's default 8 GiB check but below Android's 40 GiB floor / 50 GiB
  preference. Capacity is variable and must be checked again before builds.
- `/opt/homebrew/opt/ruby/bin/ruby -I scripts/tests -r expansion_contract_fixture_support -e 'summary = PocketLMExpansionContractFixtures.verify!; puts "Validated #{summary.fetch("caseCount")} cases in #{summary.fetch("fileCount")} indexed files across #{summary.fetch("families").length} families."'`
  exited 0: 173 cases / 30 indexed files / 10 families.
- `git diff --check`: exited 0, no whitespace findings.
- `claude --version`: 2.1.289; help confirms exact model selection, print/JSON
  output, safe mode, read-only tool allowlist and disabled session persistence.

No application/native build, full fast suite, emulator, physical-device check,
dependency installation, runtime migration, or model download was rerun. The
August 19-test/162-assertion acceptance remains historical evidence, not a new
result from this pass.

## Failed checks and risks

No corpus/whitespace check failed. An initial ad hoc Markdown-link scanner
misread inline timestamp grammar as a link; excluding code spans/fences passed.
The initial independent verifier accepted the revision, but the first Opus
review returned REVISE on three P1 planning gaps. Its report is preserved in
`2026-10-03-claude-code-plan-review.md`; acceptance now waits for follow-up review
and fresh verification of the changed text. A sandboxed process-status check was
denied; an approved read-only process-name/elapsed-time check confirmed the review
was running. This did not affect files or review authority.

Hardware/Linux evidence, current Android disk capacity, and
recreation of an isolated no-space worktree remain outstanding. New Gate 4C/4D
checkpoints redistribute existing work; task estimates need a fresh packet-level
review, not a claim that elapsed dates or implementation completion are known.

## Initial Claude review reconciliation

The exact `claude-opus-5-5` run exited 0, reported the same canonical model
without fallback, and returned REVISE. It used read/grep/glob only and ran no
checks/builds. Its attempted inherited-AGENTS read was denied outside the working
directory; the lead already read the complete authoritative file and supplies
its full text in the follow-up prompt, not a bypass of the denied read.

P1 findings adopted:

1. Android has no legacy production installation. Gate 4A uses schema-1
   compatibility readers/test fixtures, not a production schema-1 writer.
   Gate 4D distinguishes real iOS legacy migration from Android fresh v2
   bootstrap plus native migration-fixture conformance.
2. Gates 4A/4C own safe development seeding: compiled local-file transport
   injection beneath existing `startInstall`, host inbox byte delivery only,
   normal native receipts/authorizing transfer/hash/GGUF/durable publication.
   This introduces no public manager method, persisted shape or ABI and is
   absent from shipped releases. Its design/owners are explicit before Gate 2.
3. Gate 4D's pre-second-model switch vehicle uses a compiled two-entry fixture
   catalog, real native repository/filesystem/lease/receipt/preference code,
   and an ABI-level inference fake for deterministic failures. After production
   1.5B admission, a named actual-core 0.5B↔1.5B subset must pass on both
   platforms. Fake and real-core evidence are reported separately.

P2 dispositions:

- Adopted: Gate 3B waits on Gate 3A's reviewed root-build sub-checkpoint, not its
  whole physical execution tail; Gate 4A still needs complete Gate 3A acceptance.
- Adopted: explicit iOS production-path rejection at Gate 4C, before activation.
- Clarified without reducing scope: Simulator-only fallback needs a separate
  user-approved scope-down ADR/checklist. None is authorized here; physical
  iPhone enrollment remains required.
- Adopted: append a current-status pointer to the decisions record; label
  orchestration routing as August assignments (already corrected before the
  initial report finished). The contract header's August update date is kept as
  the frozen semantics date; the delivery reconciliation is explicitly dated
  October in its changed landing/open-evidence sections. No frozen-body edit.
- Adopted: Gate 2 fingerprints bind fixture publications against fake authority,
  never a fabricated publication ID for a production schema-1 installation.
- Adopted: publication never calls/awaits unload while holding exclusive authority.
- Adopted: bundled catalog `schemaVersion` is the production activation boundary;
  no separately mutable feature flag; dev/test seams are not enablement.
- Adopted: Gate 1's assigned Android runners need the 40 GiB floor; a separate
  iOS-only 8 GiB check does not close the joint gate.
- Adopted: Gate 4A prerequisites are explicit; Gate 4C/4D effort is redistributed
  from existing work, with packet-level estimates required before dispatch.
- Adopted: orchestration iOS probe may precede activation; Gate 5A reuses the
  accepted switch matrix with actual probe-driven configurations.
- Adopted: Simulator protection checks are attribute-level only; actual locked-
  device Data Protection remains Gate 6 physical proof.

## Final status

Opus follow-up returned ACCEPT WITH NONBLOCKING NOTES, no P0/P1, using the exact
requested `claude-opus-5-5` with no fallback or permission denials. Its report is
preserved in the Claude record. The fresh verifier accepted the repaired core
revision and final note-disposition pass. The lead read both saved review logs
before accepting this documentation reconciliation. Final whitespace, corpus,
scope and frozen-body checks pass. No implementation authority was given to
either reviewer, and overall Gate 0 remains open. All changes remain local and
uncommitted; no push was performed.

## Follow-up nonblocking-note dispositions

1. Adopted: retain authentic legacy Simulator seeding until activation; afterward
   restrict legacy generation to isolated offline migration inputs. Legacy proof
   is Simulator-based; physical iPhone gets fresh v2 bootstrap.
2. Adopted: Gate 2's Claude implementer owns small generated test catalogs/GGUF
   recipes under future `fixtures/expansion-implementation/`, outside the closed
   Gate 0B inventory; native test roots are isolated from production generations.
3. Adopted: 4A/4C and Gate 6 have explicit release-negative artifact/config/runtime
   checks for all test seams/fakes/catalogs/root overrides/fault injection. Native
   authority AND a compiled dev/test route are both required for host seeding.
4. Adopted/already corrected: 3B may overlap only the tail of Gate 2; 3A waits
   for full Gate 1 acceptance, matching the diagrams/landing constraints.
5. Adopted: the reviewed 3A root-build sub-checkpoint needs implementation and
   fresh verifier logs plus named host/header/cross-compile/PIC/closure/ELF and
   regression checks; exact commands are required in its packet before dispatch.
6. Adopted: Android schema-1 production catalog fails closed as
   `CATALOG_UNSUPPORTED`; pre-activation phone chat uses an isolated one-entry v2
   test catalog with the authentic 0.5B identity.
7. Carried explicitly into 4A/4C packet freezes: inbox location outside the fixed
   Models root, protection/backup/cleanup, double-copy disk preflight, transport
   selector/trigger, closed-error mapping, and local-transfer crash repair. No
   owner/API readiness checkbox may be accepted with these details unnamed.
8. Applicability recorded: PocketLM is an existing project, not a new from-scratch
   build; inherited new-project documentation clauses do not imply a retroactive
   implementation pass. Nonetheless Gate 1 must prepare project-local AGENTS and
   an environment/example inventory before foundation code, and Gate 6 must
   represent development signing/credential access. Preserving August reviewer
   attribution is history, not an exemption for any future implementation step.
9. Adopted: initial verifier/Claude verdicts remain historical checkpoints; fresh
   reports and current statuses are recorded separately, with updated DAG counts.
10. Adopted: real-core switching lanes are named (Android phone / iOS Simulator),
    and host recovery is explicitly limited to development builds, not release.

The proposed reader-only Android migration alternative is deferred to the 4A
packet: current native fixture conformance is retained to avoid weakening the
cross-language contract. Any scope change must preserve the accepted corpus and
have independent review. The stale August contract header is retained as
original metadata; the explicit October landing/status sections supersede its
current-status meaning without changing the frozen body.
