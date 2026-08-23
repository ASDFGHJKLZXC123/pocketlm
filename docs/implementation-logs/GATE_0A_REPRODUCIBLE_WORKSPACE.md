# Gate 0A reproducible workspace evidence

Status: tooling, clean fast/iOS Simulator release, current local capacity, and
macOS arm64 Android package evidence accepted; G0-A remains open for the
assigned Linux/KVM lane.

Original evidence date: 2026-08-07.
Updated: 2026-08-23.

## Immutable Git chain

| Role | Commit | Evidence |
| --- | --- | --- |
| Approved code basis | `6f9de4a33d08a11ec37258b0d2cab1acab5f61a4` | `main` and `origin/main` were aligned before preservation |
| Gate 0 documentation preservation | `3425a50c20f758702316b2c0cb831240ffbdde44` | Sole parent is the approved basis; exactly nine documents were added |
| G0-A implementation | `2975d61d13903dd3cb5ee8518034427fe9d345be` | Sole parent is the preservation commit; exactly six approved files changed |
| G0-A acceptance evidence | `d6bdeb61f18a2f3651f96f4c7266016383b40d09` | Sole parent is the implementation commit; records the accepted clean lanes |

Through the 2026-08-07 acceptance, the original checkout remained at
`/Users/f8fq/coding projects/Unfinished/PocketLM` on `main` at the approved
basis. Its nine source documents remained untracked and byte-identical; it was
not stashed, cleaned, switched, moved, or rewritten during that acceptance.

On 2026-08-23 those nine blobs were rechecked against `3425a50`, preserved in a
recoverable stash, and the checkout moved to `codex/gate-0-consolidation` from
`d6bdeb6` without rewriting the accepted chain. Current evidence is recorded in
`GATE_0_CONSOLIDATION_2026-08-23.md`.

The preservation commit contains these exact source-byte SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `docs/plans/2026-07-28-android-adaptive-expansion.md` | `4bb712ec48a39bfa84be34dc24e2760cb717ebc3c81598b14360a8cb99f8dcff` |
| `docs/plans/2026-07-28-android-adaptive-expansion-review.md` | `be3b5402f4478f358ef7b43e94613cc7528afeb239c9bd1199ac92bbb9eb403e` |
| `docs/plans/2026-08-03-ios-adaptive-model-selection.md` | `24a563adeb167c33b855baee85a70c34b51d88fb85990ea40a21c357dccc62b6` |
| `docs/plans/2026-08-03-ios-adaptive-model-selection-review.md` | `4753ce5ce5b6b630b49b5bb29dbee5e6f405daa8e9bef496cc4b4860a7d66498` |
| `docs/plans/2026-08-07-ios-android-expansion-implementation-plan.md` | `cc75783a30375353c4ff27c28e8d0430eb4d773f9cfb1cded246354ac3b20d4a` |
| `docs/contracts/EXPANSION_GATE_0_CONTRACTS.md` | `78d6246af97154d4f1849b8abff7779f14be5e4b526bc861826d19782a394f1b` |
| `docs/implementation-logs/GATE_0_BASELINE.md` | `07eb8ea0a885a5d2af5a823ec81bf66b5436075956990e50025267f7ec0131c3` |
| `docs/implementation-logs/GATE_0_ORCHESTRATION.md` | `bd888378f297bac653350a8cf9ef281a027bd71fc2f9b2ae640d2e59608e2610` |
| `docs/implementation-logs/GATE_0_INDEPENDENT_REVIEW.md` | `302a6f6e6dd385c28301c3c303a6558d666312f5374548c959dd9935416c3df3` |

## No-space acceptance worktree (2026-08-07)

| Check | Result |
| --- | --- |
| Worktree | `/Users/f8fq/coding/PocketLM-G0A` |
| Branch | `codex/expansion-g0a` |
| Checkout predicate | PASS: physical path contains no spaces |
| Recursive submodule | `45cac7ca703fb9085eae62b9121fca01d20177f6`, detached and clean |
| Acceptance snapshot | Clean implementation commit `2975d61d13903dd3cb5ee8518034427fe9d345be` |
| Unrelated worktree | Stale/prunable `/private/tmp/PocketLM-M4R` record was left untouched |

Generated Pods, `node_modules`, CMake trees, and DerivedData from the original
space-containing checkout were not copied into this worktree. Dependencies and
native outputs used for acceptance were regenerated under the new physical
root.

The no-space acceptance worktree path was absent and its Git metadata was
prunable at the 2026-08-23 consolidation. This does not invalidate its recorded
clean-commit results, but it is not a current execution workspace.

## G0-A implementation scope

Commit `2975d61` changes exactly:

- new executable `scripts/with-pinned-node.sh`;
- new executable `scripts/tests/pinned_node_entrypoint_test.sh`;
- `scripts/verify-fast.sh` to include the launcher fixtures; and
- `README.md`, `docs/TOOLCHAIN.md`, and `docs/TROUBLESHOOTING.md` to route local
  Node-dependent commands through the launcher.

The launcher reads the exact `.node-version` pin, requires Node and Corepack
from one verified `bin` directory, prefers an already-exact active runtime, and
then checks the exact NVM location. `POCKETLM_NODE_BIN` provides an explicit
verified override. The selected physical directory is rejected if it contains
the `PATH` separator, including through a symlink. The launcher never invokes
`corepack enable` and replaces itself with the requested command so arguments
and exit status are preserved.

An independent GPT-5.6 reviewer found no remaining P0, P1, or P2 issue in the
six-file implementation before commit.

## Resolved toolchain

| Tool | Accepted value |
| --- | --- |
| Node | 22.23.1 from `/Users/f8fq/.nvm/versions/node/v22.23.1/bin` |
| pnpm | 10.34.0, resolved by Corepack from `app/package.json` |
| Launcher shell | macOS `/bin/bash` 3.2.57 |
| Ruby | 3.4.4 from `/opt/homebrew/opt/ruby/bin` |
| Bundler | 4.0.7 |
| CocoaPods | 1.16.2 |
| CMake / Ninja | 4.4.0 / 1.13.2 |
| Xcode / Swift | 26.4.1 (17E202) / 6.3.1 |

The host can otherwise expose Node 25.9.0, pnpm 10.33.0, and
`/usr/bin/ruby` 2.6.10. Those are not accepted project inputs. Evidence commands
explicitly placed `/opt/homebrew/opt/ruby/bin` first in `PATH` and used the Node
launcher.

## Acceptance results

| Lane | Result |
| --- | --- |
| Launcher fixtures | PASS: 13/13 cases, including active/explicit/NVM/HOME resolution, lying or incomplete runtimes, direct and symlinked `PATH` separator cases, malformed pins, argument and exit propagation, and worktree immutability |
| Clean fast verification | PASS on `2975d61`: exact pins, frozen dependency graph, TypeScript, ESLint, 5 Jest suites / 51 tests, static iOS export, 16 provisioning runs / 57 assertions, 26 qualification runs / 113 assertions, and 13 launcher cases |
| Native all | PASS: fresh Debug/ASan and Release trees, 34/34 model-independent tests, both Objective-C++ bridge harnesses, and both bounded qualification timeout self-tests |
| Native TSan | PASS: 22/22 targeted concurrency tests |
| Clean iOS Simulator release | PASS on `2975d61`: locked Ruby and CocoaPods dependencies, 10,647,340 KiB disk preflight, fresh DerivedData, generic arm64 Simulator build across 115 targets, app validation, and final clean-result guard |

The iOS command was:

```sh
env PATH="/opt/homebrew/opt/ruby/bin:$PATH" \
  ./scripts/with-pinned-node.sh ./scripts/verify-release.sh ios
```

Third-party Sentry, Expo, React Native, screens, worklets, and script-phase
warnings were non-fatal. Xcode ended with `BUILD SUCCEEDED`, and the wrapper
ended with `verify-release ios passed with a clean result`.

## Capacity and open work

After the 2026-08-07 iOS acceptance and temporary DerivedData cleanup,
9,707,104 KiB was free
on the data volume at 2026-08-07 21:45 PDT. This is not adequate proof for the
local Android platform, NDK, CMake, arm64 image/AVD, model staging, and build
outputs. The project safety policy holds local Android installation until at
least 40 GiB is free; 50 GiB is preferred. This is a PocketLM orchestration
policy, not an Android platform requirement.

Image capacity and installation are host-scoped. The macOS arm64 lane owns the
normal arm64 image and, if locally available, the arm64 16 KiB image. The
normal and 16 KiB x86_64 images belong on the Linux/KVM lane. Physical arm64
feature and page-size evidence belongs on the enrolled phone. Installed
command-line tools 20 emitted an XML-schema warning, so the provisional remote
revision selections required a repeat with command-line tools 22 before they
could be trusted.

The 2026-08-23 refresh recorded 55,615,884 KiB (53.04 GiB) free, explicit
command-line tools 22.0 inventory, API-36 platform revision 2, NDK r28c, SDK
CMake 3.31.6, normal arm64 image revision 7, 16 KiB arm64 image revision 7, and
both corresponding PocketLM AVD definitions. It also recorded passing current
fast, native Debug/ASan, bridge, Release, TSan, and exact 0.5B model-backed
lanes. Gate evidence uses the deterministic explicit 22.0 path; the generic
`cmdline-tools/latest` path still selects 20.0 as a non-blocking host caveat.
Neither AVD has runtime evidence, and the assigned Linux/KVM x86_64 lanes remain
open.

The following are intentionally still open:

- iOS XCTest durability through two clean prebuilds;
- isolated `iphoneos-arm64` compile/link and physical-iPhone evidence;
- assigned Linux/KVM normal/16 KiB x86_64 image evidence;
- deterministic Android prebuild and emulator lanes;
- physical Android phone evidence; and
- golden contract fixtures and final Gate 0 closure review.

The accepted G0-A tooling resolves the reproducible-workspace and local
entry-point problem. The current refresh also resolves local capacity and the
macOS arm64 package-install sub-lane. G0-A remains open for its assigned
Linux/KVM evidence, and it does not authorize Gate 1 feature implementation
while Gate 0 is open.
