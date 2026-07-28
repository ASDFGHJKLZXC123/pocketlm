# Troubleshooting

Start with the exact failure boundary. PocketLM has separate host dependencies,
iOS build inputs, Simulator state, model verification, native session state,
and JavaScript presentation state; replacing files across boundaries usually
makes diagnosis harder.

## First checks

From the repository root:

```sh
git status --short
git submodule status --recursive
node --version
(cd app && corepack pnpm --version)
ruby --version
bundle --version
xcodebuild -version
cmake --version
ninja --version
```

Compare every value with [TOOLCHAIN.md](TOOLCHAIN.md). Do not use
`POCKETLM_ALLOW_UNPINNED_TOOLCHAIN=1` when validating a reproducible build.

## Checkout path contains spaces

`scripts/verify-release.sh` rejects paths with spaces because the pinned React
Native iOS code-generation path is not portable there.

Use a no-space checkout such as:

```sh
git clone --recursive \
  https://github.com/ASDFGHJKLZXC123/pocketlm.git \
  /private/tmp/PocketLM
```

Do not rename or move an active Pods/DerivedData build and assume it remains
valid. Reinstall pods and rebuild from fresh DerivedData in the new checkout.

## llama.cpp submodule is missing or dirty

Expected pin:

```text
45cac7ca703fb9085eae62b9121fca01d20177f6
```

Initialize the recursive checkout:

```sh
git submodule update --init --recursive
git submodule status --recursive
```

Do not update or patch the pin as a setup workaround. A changed dependency
requires the relevant build and runtime checks to be repeated.

## Node, pnpm, Ruby, or CocoaPods mismatch

PocketLM freezes:

- Node.js 22.23.1;
- pnpm 10.34.0 through Corepack;
- Ruby 3.4.4;
- Bundler 4.0.7; and
- CocoaPods 1.16.2.

Install dependencies only through the locked graphs:

```sh
(cd app && CI=1 corepack pnpm install --frozen-lockfile)
BUNDLE_FROZEN=true bundle install
(cd app/ios && bundle exec pod install --deployment)
```

Do not use an unpinned global `pod install` for a reproducible build.

## Release verification reports insufficient disk

The iOS lane requires at least 8 GiB free in the temporary-volume filesystem
before creating fresh DerivedData. The model and an installed Simulator also
need additional space.

Check:

```sh
df -h "${TMPDIR:-/tmp}"
```

Delete only build artifacts you own and can reproduce. Never delete the model
or user files merely to satisfy the check. `verify-release.sh` removes its own
temporary DerivedData on exit.

## Pods resolve differently or contain private checkout paths

Use deployment mode:

```sh
(cd app/ios && bundle exec pod install --deployment)
```

The release verifier rejects iOS dependency-resolution overrides and evaluated
local podspecs containing the checkout root. Clear external override
environment variables rather than editing the lockfile or generated podspec.

If a prior non-deployment install changed tracked files, inspect the diff and
restore only generated changes you created. Do not discard unrelated user
work.

## No iPhone 15 Pro / iOS 17.5 Simulator

List available devices:

```sh
xcrun simctl list devices available
```

Install the iOS 17.5 Simulator runtime through Xcode and create an iPhone 15
Pro device if needed. A different runtime may be useful for development but is
not the tested configuration.

Use the exact-UDID resolver in the root
[README quick start](../README.md#quick-start), then boot the
resolved destination:

```sh
open -a Simulator
xcrun simctl boot "$POCKETLM_SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$POCKETLM_SIMULATOR_UDID" -b
```

## Model download fails

The source URL, revision, size, hash, and required GGUF metadata come only from
`models/catalog.json`.

Retry the verified fetch:

```sh
./scripts/fetch-models.sh
```

If a complete cached file exists but fails verification, the script will not
silently replace it. Inspect the failure, then explicitly replace it:

```sh
./scripts/fetch-models.sh --force
```

The expected file is 491,400,032 bytes with SHA-256:

```text
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
```

Never commit a GGUF or bypass verification.

## App says “Seed model to begin”

The app does not download models in the UI. It requires a booted Simulator, an
installed `com.pocketlm.app`, and the host-verified model.

Run:

```sh
./scripts/seed-simulator-model.sh
```

If more than one booted Simulator has PocketLM installed, pass the exact UDID:

```sh
./scripts/seed-simulator-model.sh --udid SIMULATOR_UDID
```

The seeder verifies the host file before touching the sandbox, terminates the
app before replacement, verifies the copied partial and final files, writes a
catalog-derived manifest, and applies backup exclusion.

Use `--force` only after the script reports that an installed model is invalid.

## App is not installed for seeding

Build and install PocketLM before running the seeder. The README quick-start
commands are in the root [README](../README.md).

First resolve `POCKETLM_SIMULATOR_UDID` with the README's exact-device block in
the same terminal. Then confirm the container exists:

```sh
xcrun simctl get_app_container \
  "$POCKETLM_SIMULATOR_UDID" \
  com.pocketlm.app \
  data
```

## Model status is invalid

Do not hand-edit the sandbox manifest. Rerun the seeder with the authenticated
source. A verified model with missing/stale metadata is repaired without
recopying all 491 MB; an invalid model requires explicit `--force`.

The runtime boundary checks catalog identity, size, GGUF magic, manifest, and
chat-template identity. The UI does not recompute the full SHA-256 in Hermes.

## UI reports CPU fallback

This is expected in the qualified Simulator build. Metal is compiled into the
target, but `POCKETLM_SIMULATOR_CPU_ONLY=1` forces inference to CPU with zero
offloaded layers and K/Q/V offload disabled.

Do not change the policy or relabel the badge to claim Metal. Physical-device
Metal behavior is outside the tested scope.

## Generation is busy

The public contract permits only one accepted request per session. A second
request while work is queued, prefilling, decoding, or finishing is rejected
synchronously with `-2` and emits no event.

The chat UI owns a synchronous submission lock and should not admit overlap.
If normal UI interaction repeatedly exposes BUSY:

1. preserve the exact steps and logs;
2. wait for the current terminal or use awaited Unload;
3. do not add delays or clear the ownership lock locally; and
4. treat a reproducible overlap as a product defect.

If the qualification runner reports BUSY after an interrupted run, wait for
the matching terminal or unload the session before retrying. An interrupted
run must never be treated as complete.

## Cancel appears to wait

Cancel is complete only when the matching native terminal arrives. The UI
keeps ownership while the request is cancelling.

The recorded cancellation timing measured immediately-before-native-cancel to
listener delivery in a CPU-only Simulator, not touch-to-screen latency. Do not
compare it with visual UI timing or physical-device behavior.

If cancellation does not terminate, use Unload; unload cancels, joins the
worker, flushes terminal delivery, removes the session, and then resolves.

## Sentry says DSN is not configured

This is expected. PocketLM tests that missing DSN skips initialization safely.
No DSN, organization, project, or auth token is committed.

Do not add credentials merely to silence the message. Sentry ingestion,
delivery, source-map/dSYM upload, and native symbolication are unsupported in
the current project.

## Build emits many warnings

Native dependencies may emit many warnings. “Clean build” in PocketLM means a
reproducible clean-checkout build with zero errors and no generated repository
diff; it does not mean warning-free.

Treat a new error as a blocker. Compare warning changes carefully, but do not
describe the retained build as warning-clean.

## Verification changes the worktree

All shared verification entry points snapshot Git status and fingerprints.
They fail if their work changes the repository.

Inspect:

```sh
git status --short
git diff --check
```

Generated `node_modules`, Pods, CMake trees, DerivedData, Expo output, model
files, and runtime artifacts must remain ignored or outside the repository.
Preserve unrelated local changes.

## Collecting diagnostics safely

Useful diagnostics include:

- exact Git commit and tree;
- tool versions;
- Simulator device/runtime/build;
- bundle identifier and build mode;
- model catalog ID and SHA-256;
- selected backend diagnostics;
- exact verification command and exit status; and
- privacy-reviewed application logs.

Do not commit credentials, GGUF bytes, raw Instruments traces/XML, private
absolute paths, process addresses, Simulator data-container paths, or
unreviewed crash/runtime logs.
