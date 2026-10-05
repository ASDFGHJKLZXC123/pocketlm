# Claude CLI planning validation — 2026-10-03

Status: follow-up ACCEPT WITH NONBLOCKING NOTES, after initial REVISE. No P0/P1
remains. Overall Gate 0 remains open; implementation is not authorized.
Exact requested and reported model: `claude-opus-5-5` (canonical model, first-party provider); no fallback.
Claude Code version: 2.1.289. Initial CLI exit: 0; `is_error: false`; 23 turns, approximately 327 seconds.

Tools: Read/Grep/Glob only; safe mode; no hooks, MCP servers, session persistence, shell, or file-writing tools.
This is planning review, not implementation, build execution, or overall Gate 0 closure.
The initial outside-workspace read of inherited `../AGENTS.md` was denied. The lead read that file directly and included its complete text in the follow-up prompt; no permission workaround or model substitution occurred.

The following initial report is preserved verbatim. Its findings are reconciled in the lead log; current-control line numbers may shift after fixes.

## Initial Opus 5.5 report

# Plan-revision review — PocketLM expansion (2026-10-03)

**Verdict: REVISE**, narrowly. Criteria 1–5 and 7 hold with no P0. Three P1 gaps in Gate 4D's executability need bounded text fixes; no re-architecture. This is not a Gate 0 closure opinion.

Reviewer model as reported by the session: `claude-opus-5-5`, no fallback. Read-only; nothing edited or run.

## Inspected

- **Requested docs read in full (8 of 9):** the plan, `GATE_0_ORCHESTRATION.md`, `GATE_0_BASELINE.md`, `EXPANSION_GATE_0_CONTRACTS.md` (all 1,549 lines), `EXPANSION_GATE_0_DECISIONS.md`, `INFERENCE_PROTOCOL_V2.md`, the Gate 0B log, and the lead reconciliation log.
- **Not read:** `../AGENTS.md`. The Read was denied by the permission mode (outside the working directory) and I did not work around it. No copy exists in the repo.
- **Also read:** `plan-revision/2026-10-03-verifier-plan-review.md` (already present, ACCEPT), `models/catalog.json`, and grep hits in `scripts/seed-simulator-model.sh` and `cpp/include/pocketlm_core.h`.

## Checks performed vs supplied

| Performed by me (read/grep/glob) | Supplied, not reproduced |
| --- | --- |
| Production catalog is schema 1 with one model (`models/catalog.json:2-5`) | 173-case `verify!` pass |
| Built ABI is `0x00020100` (`pocketlm_core.h:7`); no hard-coded literal in other sources, so the 3B bump is mechanically safe | `git diff --check` pass |
| Fixture tree is `index.json` plus 30 files, with 10 family files | HEAD `8e6c4ad`, docs-only diff |
| Contracts contain no seed/import surface (grep) | Frozen contract body byte-identical to HEAD (verifier's claim) |
| Only `scripts/seed-simulator-model.sh` exists; no Android seed script | No build rerun |

I could not run git, so criterion 7 is judged on the current text plus the verifier's byte-comparison claim.

## Criteria

1. **G0/G1 cycle removed — pass.** Plan 201–207, orchestration 28–33, 269–275 and 309–310, baseline 182–192, contracts 1540–1545. Gate 0 stays open (orchestration 316–322) and later proofs stay at their owning gates.
2. **G2 separation — pass, with note P2-e.** Plan 258–260 and 297–300.
3. **Native foundations and inspector before activation — pass.** Plan 489–491 and 698–701, orchestration 79–81, contracts 1501–1505.
4. **Sequence agreement — pass on ordering.** Plan 499–506, contracts 1506–1509, orchestration 128–130. Executability gaps are P1-1 to P1-3.
5. **Accepted vs open status — pass.** See P2-d for one stale statement.
6. **Workflow — internally consistent only.** Plan 733–767 and orchestration 46–51 and 252–254 agree with each other. Conformance to the actual `AGENTS.md` text is unverified by me.
7. **Frozen semantics — no contradiction found.** Switch order, leases, receipts, publication and ABI text in the plan match the contract. One wording drift is P2-f.

## P0

None.

## P1 (fix before acceptance, or record why not adopted)

**P1-1. Android "real schema-1 migration" is vacuous or contradictory.**
- Android has never had an installation (plan 87–88).
- 4A calls fixture seeding test-only and "not a second production storage writer" (plan 423–425).
- 4D step 2 nonetheless requires real migration "on both platforms" (plan 499–500), and the exit requires preserving "the prior 0.5B bytes" (plan 508).
- 4A does not say which storage schema Android uses before activation (plan 395–397).
- Fix: state that Android never writes production schema 1. Its 4D step 2 is then a fresh v2 bootstrap plus the corpus migration conformance already in the 4A exit (plan 421–422), and real-install migration is iOS-only. Contract 446–448 does not require Android migration, so nothing frozen weakens. This also removes Kotlin schema-1 writer work from the critical path.

**P1-2. No gate owns a v2-conformant seeding route, yet 4D needs one.**
- 4D step 4 must install 1.5B before any downloader exists (plan 504–506, 513–514).
- The 4D exit requires seeding "under exclusive authority" or confinement to a test-only route (plan 511–513).
- The existing seed is a host process that terminates the app and writes the active directory itself (`seed-simulator-model.sh:3`, `:224`).
- The frozen contract has no way to authorise that: `ManagerMethod` is closed (contracts 968–970), staging promotion needs an authorising durable transfer (contracts 1378–1385), and an out-of-process writer needs a lock design (orchestration 117–118).
- 4C has no seeding deliverable (plan 461–474); G2 references an Android seed interface that does not exist until 4A (plan 272).
- Fix: assign ownership in 4A and 4C. Recommended shape is a compiled dev/test-only local-file install that runs the normal staged-publication path inside the repository, with host scripts only delivering bytes.
- Decide before G2 whether this needs new contract surface, because the manager spec "lands exactly once" there (contracts 1517–1518).
- Until decided, the unchecked Gate 0 item at orchestration 321–322 ("no task blocked on an unnamed API or owner") cannot honestly be ticked.

**P1-3. 4D step 3 accepts switching before a second fingerprint can exist.**
- Step 3 must be green before 1.5B is added (plan 501–505).
- With one production model and a fixed profile-v1 configuration (contracts 740–747), there is nothing to switch between.
- Step 4 then only requires that both IDs "reach the actual native calls" (plan 505), so the failure matrix could go unexercised on two real models until Gate 6.
- Fix: name the step 3 vehicle (a compiled test-only two-entry catalog with small GGUF fixtures on the real repository and lease code). Require step 4 to rerun a named 0.5B↔1.5B subset of the switch matrix.

## P2 (non-blocking)

- **a. iOS 4C is transitively gated on Android hardware.** 3B says 3A "must land first" (plan 350–352), and the 3A exit needs the phone and KVM lane (plan 334–335). Clarify that 3B needs only 3A's root-CMake change merged.
- **b. 4C exit lacks 4A's explicit path-rejection criterion.** Compare plan 416–417 with 476–485. The explicit iOS criterion sits in 5B (plan 639–641), after activation. Mirror it into 4C.
- **c. No-iPhone fallback has no path through the Gate 0 checklist.** Plan 75–77 allows it; orchestration 317 and plan 195 require a physical iPhone. State whether a recorded scope-down satisfies the item.
- **d. Stale status text.** `EXPANSION_GATE_0_DECISIONS.md:226-228` still lists "platform-lane evidence" as a Gate 0 blocker in a normative control. Contracts line 9 has a stale "updated" date. The orchestration 53 column header says "Current assignment" for a table described as historical.
- **e. G2 fingerprint bullet is unqualified.** Plan 279 puts fingerprinting in inference ownership, but schema 1 has no `publicationId` (contracts 278, 287). Say it runs against fake authority with no synthetic ID. Plan 295 likewise.
- **f. Publication step 7 wording.** Plan 605 can read as unloading while holding authority, which contracts 549–551 and 1339 forbid.
- **g. The "activation boundary" mechanism is unnamed.** Plan 396–397 and 472–474. Suggest the bundled catalog `schemaVersion` as the sole switch, with no runtime flag.
- **h. G1 dispatch capacity floor is ambiguous.** G1 runs Android prebuilds, and 12.18 GiB is under the Android floor (plan 108–112, orchestration 281–283). Say which floor governs G1.
- **i. Missing prerequisites and estimates.** 4A has no "starts after" line (plan 377); 4C and 4D have no estimates; the 4A estimate predates its repository scope (acknowledged at plan 836–838).
- **j. Diagram and scope overlap.** The orchestration diagram places the iOS probe after 4D (82–84), while the plan allows 4B earlier (429–430). The 5A exit at plan 532–533 duplicates the 4D exit.
- **k. Simulator does not enforce Data Protection.** Bound the 4C "protection" exit (plan 481) to attribute-level checks, with device proof at Gate 6.

## Risks

- Builds that ran 4D step 2 cannot downgrade (contracts 375–376). Keep authentic schema-1 state reproducible for dev devices.
- The verifier's ACCEPT predates this review. Any edits made in response need fresh verification.
- This report still needs recording as `plan-revision/2026-10-03-claude-code-plan-review.md`; I could not write it.
- Criterion 6 needs a check against the actual `AGENTS.md` text by someone with access, or paste it and I will check.

## Follow-up Opus 5.5 report

Exact reported canonical model: `claude-opus-5-5`, first-party provider; no fallback.
CLI exit 0; `is_error: false`; 35 turns; approximately 337 seconds; no permission denials.
The complete inherited AGENTS text was supplied in the prompt; not independently re-read from disk by Claude.
Verdict: ACCEPT WITH NONBLOCKING NOTES. No P0/P1 remains. Supplied checks are distinguished from Claude's inspection below.

Reading is finished; I've cross-checked the revised plan, orchestration, baseline, contract sections, decisions pointer, Gate 0B pointer and both logs against the initial report and the supplied AGENTS text. Report follows.

# Follow-up plan-revision review — 2026-10-03

**Verdict: ACCEPT WITH NONBLOCKING NOTES.** No P0 or P1. All three initial P1 gaps are closed without new contract surface, and all eleven P2 items are adopted or dispositioned with a reason. This is a planning review only, not a Gate 0 closure opinion.

Session model: `claude-opus-5-5`, no fallback. Read/Grep/Glob only; nothing run, edited or committed. I cannot write the log, so this report still needs recording in `plan-revision/2026-10-03-claude-code-plan-review.md`.

## Inspected

- **Read in full:** the plan, `GATE_0_ORCHESTRATION.md`, `GATE_0_BASELINE.md`, the Gate 0B log, the lead reconciliation log, the preserved initial report, the earlier verifier log, `models/catalog.json`, and the fixture-set `README.md`.
- **Contracts, by section:** header and version map, catalog v2 through publication/crash recovery (115–669, 781–1205, 1323–1472), and non-activation, landing and open evidence (1470–1557).
- **Decisions:** scope through G0B-002, and G0B-010 through the current-status pointer (200–237).
- **`INFERENCE_PROTOCOL_V2.md`:** the Protocol 2.1 amendment (296–365).
- **Grep/Glob:** `seed-simulator-model.sh`, `pocketlm_core.h`, the fixture tree, repo-wide `AGENTS.md` / `.env*`, and `process.env` uses.
- **Supplied, not read from disk:** the inherited `AGENTS.md` text in your prompt.

## Inspected vs reproduced

| Checked by me (read-only) | Supplied, not reproduced |
| --- | --- |
| Production catalog is still schema 1, one model | 173 cases / 30 files / 10 families `verify!` pass |
| Built ABI is still `0x00020100` | `git diff --check` pass |
| Frozen contract body has no seed/inbox/transport text; the only mention is landing line 1523 | Frozen body byte-identical to HEAD (earlier verifier's claim, pre-revision) |
| Both Mermaid graphs traced edge by edge | No build rerun |

## Initial P1 gaps

| Gap | Status | Evidence |
| --- | --- | --- |
| P1-1 Android migration | Resolved | Plan 450–453, 562–567, 585–586; orchestration 139–140; contracts 1506–1508. Android never writes production schema 1; real legacy migration is iOS-only; iOS fresh bootstrap is also exercised. Contract 446–448 is untouched. |
| P1-2 Seeding owner | Resolved | Plan 191–193, 282–283, 455–472, 522–523; orchestration 134–140; contracts 1523–1527. |
| P1-3 Switch vehicle | Resolved | Plan 568–583; contracts 1508–1512. |

- **Seeding seam against the frozen manager contract.** `ManagerMethod` (968–970), `CommandReceiptV1`, and the `startInstall` argument digest (1101) are unchanged. `DurableTransferV1` (1013–1027) has no URL or transport field, so transfer identity is the same whichever transport supplies bytes. Staging still needs an authorising transfer (1384–1385). Host scripts write inbox bytes only (plan 460–462), and the seam is absent from release (plan 468–469).
- **Switch vehicle.** Before 1.5B: explicit two-entry fixture catalog on real repository, filesystem, lease, receipt and preference code, with an ABI-level inference fake. After real 1.5B: a named actual-core subset on both platforms, with fake and real-core evidence reported separately.

## Initial P2 dispositions

- **Adopted (a, b, c, e, f, g, h, i, j, k):** verified at plan 332–336 and 367–370 (a), 537–538 (b), 75–80 with orchestration 181–183 (c), 290–292 (e), 686–687 (f), 528–530 (g), 116–119 with orchestration 295–300 (h), 397–399/503–504/549–550 (i), orchestration diagram and plan 596–598 (j), 540–541 (k).
- **Part of d not adopted, with a recorded reason:** contracts line 9 keeps "Open-evidence updated: 2026-08-23". That satisfies the AGENTS "note why not adopted" rule. The reason is slightly off, since that header describes the section now dated October at 1548, but editing it would break the frozen-body byte comparison.

## Your specific checks

- **No unload under exclusive lease:** plan step 7 now matches contracts 549–551 and the Protocol 2.1 amendment.
- **Actual path tests before activation:** in both the 4A exit (439–440) and the 4C exit (537–538).
- **Activation solely by bundled catalog `schemaVersion`:** plan 528–530 and contracts 1526–1527; no runtime flag.
- **G3B waits on the root-CMake sub-checkpoint only; 4A still needs full 3A:** plan 332–336, 367–370, 397.
- **Hardware, Linux/KVM and closure remain open:** orchestration 333–339, baseline 175–180, contracts 1540–1546.
- **40 GiB dispatch floor remains:** plan 116–119, orchestration 295–300, baseline 31–34.
- **Graphs match:** the plan graph has 14 nodes and 26 edges; the orchestration graph has 14 nodes and 21 edges. Both are acyclic, and every gate has the same prerequisite closure in each. The orchestration graph omits only transitively implied edges and merges 5A into the Android downloader node. Prose prerequisites for 4A, 4B, 4C, 4D, 5A and 5B agree with both.

## AGENTS conformity (against the supplied text)

- **Conforms:** Claude Code implements, with five total attempts (plan 824, 830, 845). A fresh verifier follows each changed attempt and makes no feature edits (825, 841). Both logs are read before acceptance, with the required paths and contents (849–851). Planning review precedes execution, with adopt-or-explain (833–835; lead log 99–141). The plan-revision log filenames match the required pattern.
- **Not addressed:** see P2-8.

## Findings

**P0:** none. **P1:** none.

**P2 (nonblocking; fix in text or carry into packets):**

1. **Legacy-state generator.** `seed-simulator-model.sh` is the only producer of authentic schema-1 state (it writes the active directory, line 144, after terminating the app, line 224). Plan 522–523 limits Simulator scripts to byte delivery, while 524–526 and 566–567 still depend on that writer through 4D step 2. Say it is retained unchanged until activation, then kept as a migration-test input generator. Also say legacy-migration evidence is Simulator-based, since the script is `simctl`-only and no device build has existed; a physical iPhone gets fresh bootstrap.
2. **Fixture catalog owner.** The frozen corpus's `catalog-v2-two-models.json` carries the real 491 MB and 1.1 GB identities, and the GGUF family is recipes. The small-GGUF two-entry catalog is therefore new test data. Name one shared owner and location outside the closed `fixture-set-v1` inventory, and require an isolated repository root for those builds.
3. **Release absence has no exit check.** Plan 468–469 states the rule, but no exit in 4A, 4C, 4D or Gate 6 proves the release artifact lacks the transport seam, fixture catalog, ABI fake and fault injection. Add a negative check. Separately, the 4D exit's "or be confined to a compiled test-only route" (590–591) should read "and".
4. **Overlap wording is looser than the contract.** Plan 369 says 3B "may overlap Gate 2"; contracts 1516–1517 say "only the tail of Gate 2". Plan 332 says "after Gate 1's root CMake change lands"; contracts 1514 and both graphs say after Gate 1. Align the plan to the stricter text.
5. **Sub-checkpoint evidence.** Plan 333–336 does not say what accepts the root-build sub-checkpoint. It is a code change, so it needs its own implementation and verifier logs and named checks.
6. **Android under bundled schema 1.** Behaviour is undefined. State that it fails closed, and that 4A's on-phone chat uses a test build embedding a one-entry v2 catalog with the real 0.5B identity.
7. **Seam details for the 4A/4C packets.** Inbox location outside the fixed root layout (contracts 567–580), backup exclusion (644–649), disk preflight for a 1.1 GB double copy, the transport selector and trigger, mapping failures to the closed error enum (795–803), and crash repair for a local transport (1155–1158). These bear on the unticked item at orchestration 338–339.
8. **AGENTS clauses with no disposition.** The repo has no project-local `AGENTS.md` and no `.env.example`, while the app reads `EXPO_PUBLIC_SENTRY_DSN`, `EXPO_PUBLIC_SENTRY_ENV` and `EXPO_PUBLIC_POCKETLM_RC_COMMIT`. AGENTS scopes both clauses to new projects, so applicability is your call; record it either way. Gate 6 signing credentials are also unrepresented beyond "never commit". The plan grandfathers pre-October code (817–819); AGENTS has no such clause, so confirm at closure.
9. **Stale records.** The verifier log's ACCEPT and "13 nodes / 24 edges" predate this revision. The Claude log status still reads "follow-up review pending".
10. **Minor.** Step 4 does not name the execution lane per platform. "Development/recovery route" (plan 40) overstates a route absent from release builds.

## Missed requirements and alternatives

- **Missed:** items 1, 3 and 8 above. None changes ordering or contracts.
- **Alternative considered:** Android could limit legacy handling to reader-level conformance plus fail-closed, avoiding a Kotlin journal executor that never runs in production (plan 444–445). The current choice keeps uniform corpus conformance and matches my initial recommendation; decide in the 4A packet.

## Remaining nonblocking risks

- I could not diff against HEAD, so "no frozen-body edit" rests on text inspection and the fresh verifier's byte comparison.
- Test-catalog builds and production builds on one device will disagree on `catalogDigest`; isolated roots avoid that.
- Migrated installs cannot downgrade (contracts 375–376), which is why item 1 matters.
- Hardware, Linux/KVM, Android disk capacity, the no-space worktree and packet estimates remain open, as the documents state.

**Final: ACCEPT WITH NONBLOCKING NOTES.**
