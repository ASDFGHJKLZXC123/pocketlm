# Gate 0B contract-fixture acceptance — 2026-08-23

Status: accepted; Gate 0B is closed. Overall Expansion Gate 0 remains open, and
no expansion schema or runtime activation is authorized.

Repository basis: `561c66d6e0cc2f8dc8ce384f5341a0ea39ae6bac` on
`codex/gate-0b-contract-fixtures`.

## Accepted scope

Gate 0B freezes the expansion contracts, Protocol 2.1 repository amendment,
decision record, and language-neutral golden corpus. It adds a test-only Ruby
verifier and registers that verifier in the fast verification workflow.

The final corpus contains 173 cases across 10 families and 30 files in its
closed inventory. Every indexed file's exact bytes and detached SHA-256 match.
The corpus freezes canonical encodings, catalog and model facts, installation
publication and repair, preference migration, manager receipts and snapshots,
paths and leases, policy boundaries, quarantine, and bounded GGUF inspection.

No production catalog, TypeScript/Ruby/C++ schema reader, CMake, codegen,
JNI/Objective-C++ adapter, platform behavior, persistence format, or built ABI
was changed. The current ABI remains 2.1.0 / `0x00020100`; the documented
bounded inspector remains a future append-only 2.2.0 / `0x00020200` target.

## Review reconciliation

The independent review identified and the final pack resolved:

1. closed-object and duplicate-key enforcement for every persisted JSON layer;
2. no-follow load admission promoted to a publication and canonical-file-
   identity-bound read lease before writer exclusion can lapse;
3. exact preference/migration ordering, timestamp year bounds, source bytes,
   selected intent, and coherent-rehash semantic anchors;
4. immutable quarantine IDs, exact delete receipt targeting, and mandatory
   cleanup after successful repair or replacement;
5. Android thread-count clamping to active processors and four threads;
6. exact command receipt keys, argument digests, stale-revision logic, revision
   ordering, replay identity, and publication/quarantine target exclusivity;
7. exact manager/catalog identities and selected-preference catalog binding;
8. GGUF facts-v1 acceptance of wire version 3 only, with versions 1, 2, and 4
   rejected before metadata interpretation.

After these corrections, an independent `gpt-5.6-sol` reviewer returned
`ACCEPT` with no blocking or remaining actionable findings.

## Verification

The hardened corpus suite passed 19 runs and 162 assertions with warnings
enabled, including coherent mutations that refresh all detached and embedded
hashes before semantic rejection. Ruby syntax and repository whitespace checks
passed.

The complete pinned fast workflow then passed under Node 22.23.1 and pnpm
10.34.0: the Gate 0B corpus lane, frozen dependency install, TypeScript, ESLint,
5 Jest suites / 51 tests, static iOS export, 16 provisioning runs / 57
assertions, 26 qualification-validator runs / 113 assertions, and 13 pinned
Node entry-point cases. Its intentionally absent CI cached-model path was
reported as a skip, not a failure; the exact cached-model and native evidence
remain recorded by the Gate 0 consolidation evidence.

## Remaining overall Gate 0 work

Gate 0B closure does not close the overall gate. The remaining blockers are the
attached Android/iOS hardware facts, assigned Linux/KVM normal and 16 KiB
API-36 image evidence, and the outstanding platform-lane qualification recorded
by the orchestration and contract checklists.

Current-status pointer (2026-10-03): the paragraph above preserves the acceptance-
time view. The revised owning plan and `GATE_0_ORCHESTRATION.md` now assign new
prebuild/XCTest/device-SDK evidence to Gate 1, emulator/native execution to
Gates 3A/4A, and final qualification to Gate 6. Remaining overall Gate 0 evidence
is hardware enrollment, assigned Linux/KVM installation, and final closure
review. This pointer does not reopen Gate 0B, weaken its contracts, or authorize
production activation.
