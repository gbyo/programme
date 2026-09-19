# Development

Programme uses XcodeGen, Swift Package Manager, and the tools shipped with Xcode. The generated Xcode project is disposable; `project.yml` is the source of truth.

## Requirements

- macOS
- Xcode 27 or newer
- iOS simulator runtime with at least one iPad device
- Homebrew

Everything else needed for normal development is bootstrapped by the repo.

## First checkout

```bash
git clone https://github.com/gbyo/programme.git
cd programme
make bootstrap
make open
```

`make bootstrap`:

1. installs the `Brewfile` dependencies,
2. installs the XcodeGen version pinned in `Mintfile`,
3. runs the environment doctor,
4. generates `Programme.xcodeproj`.

XcodeGen is invoked through `scripts/xcodegen.sh` so local development and CI use the same pinned release.

Swift formatting comes from the active Xcode toolchain (`xcrun swift-format`) rather than a second formatter installation.

## Commands

```text
make bootstrap     set up a fresh checkout
make doctor        diagnose Xcode, Swift, Mint, XcodeGen and simulator setup
make generate      regenerate Programme.xcodeproj from project.yml
make open          generate and open the project
make test          run the fast ProgrammeKit package tests
make test-ui       run ProgrammeUITests on an available iPad simulator
make build         unsigned app + widget simulator build
make format        rewrite all tracked Swift files with swift-format
make lint          check Swift files changed from the development base
make lint-all      audit the entire Swift tree without modifying it
make verify-fast   doctor + changed-file formatting + package tests + app/widget build
make verify        full gate, including iPad UI tests
make clean         remove generated/local build artifacts
```

Use the narrowest useful command while iterating. `make verify-fast` is the normal pre-PR gate; `make verify` is expected when the scoring workspace or another UI-test-covered flow changed.

## Environment doctor

`make doctor` checks the problems most likely to waste development time:

- macOS host
- selected full Xcode rather than Command Line Tools
- required Xcode major version
- Swift available from that toolchain
- Xcode-provided swift-format
- Homebrew
- Mint
- pinned XcodeGen
- available iPad simulator
- `project.yml` parsing
- whether the generated project exists

If `xcode-select` points at Command Line Tools, fix it with:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

If your Xcode app has another name/path, use its `Contents/Developer` directory instead.

## XcodeGen

`Programme.xcodeproj` is ignored by Git and should never be hand-maintained.

The generated project leaves code signing enabled for interactive Xcode builds. Simulator
runs use an ad-hoc signature automatically; running on a physical device requires selecting
your development team for both the Programme app and ProgrammeWidgets extension in Xcode.
The command-line build and CI scripts pass `CODE_SIGNING_ALLOWED=NO` explicitly so their
simulator-only verification remains independent of developer accounts and signing assets.

After adding/moving targets or changing project settings:

```bash
make generate
```

Source files under configured source directories are discovered by XcodeGen, so ordinary new Swift files generally need no project-file edit.

Tool versions live in:

- `scripts/versions.sh` — values used by scripts
- `Mintfile` — XcodeGen package pin
- `Brewfile` — bootstrap dependencies

Keep the XcodeGen values synchronized when deliberately upgrading it.

## Formatting

Programme uses the `swift-format` binary bundled with Xcode and `.swift-format` at the repo root.

Programme adopted this policy after the first implementation was already written. To avoid mixing a whole-repository style rewrite into unrelated functional changes, formatting is enforced as a ratchet: **every Swift file touched by new work must conform**. Existing untouched files can be normalized separately over time.

Apply formatting to the entire tracked Swift tree:

```bash
make format
```

Check the Swift files changed from your development base, including staged and unstaged edits:

```bash
make lint
```

Audit the entire current tree without rewriting it:

```bash
make lint-all
```

CI uses the same changed-file rule against the pull request base (or the previous `main` commit for pushes). Formatting policy changes that cause broad source churn should be isolated from behavioral changes.

## Package/domain tests

```bash
make test
```

This runs:

```bash
swift test --package-path Packages/ProgrammeKit
```

It is the primary correctness suite and does not need a simulator.

New soccer/stat behavior should normally be proven here first.

## UI tests

```bash
make test-ui
```

`scripts/test-ui.sh` discovers an available iPad simulator dynamically. It prefers the model named in `scripts/versions.sh`, reuses a booted iPad when one exists, and otherwise selects another available iPad device.

To force a specific simulator:

```bash
PROGRAMME_SIMULATOR_ID=<UDID> make test-ui
```

To save an Xcode result bundle:

```bash
PROGRAMME_XCRESULT_PATH=/tmp/ProgrammeUITests.xcresult make test-ui
```

CI uses that path and uploads the `.xcresult` only when the UI-test job fails.

## Intent tests

`App/ProgrammeIntentTests` (`ProgrammeIntentTests` target in `project.yml`,
run as part of the `Programme` scheme's test action) covers the App Intents
layer in two layers:

- `EntityQueryTests` / `IntentNavigationTests` exercise the real
  `ProgrammeIntentProvider` and the real `AppModel.open(_:)` routing against
  an ephemeral two-team store. They run on every deployment target, because
  `@Dependency`-bound query/intent types trap when called directly
  in-process outside the intent perform flow.
- `ProgrammeUITests/AppIntentsTestingTests` runs equivalent behaviors through
  Apple's `AppIntentsTesting` framework (iOS 27+) from the UI-test process.
  Each test independently seeds the launched application process through a
  debug-only, non-discoverable test intent, and verifies framework results or
  state read back from that process rather than an ephemeral test-process
  `AppModel`. This includes Spotlight/Siri query paths.

Known environment limitation: in the Xcode 27.0 simulator runtime Apple's
own `AppIntentsLiveEntityService` XPC service traps
(`__XPC_API_MISUSE__` in `XPCPeerRequirement.hasEntitlement`, visible in
`~/Library/Logs/DiagnosticReports`) as soon as a test client connects, with
ad-hoc and real Apple Development signing alike. Framework calls that fail
with that transport error skip loudly instead of failing; the
provider-level tests above still prove the behavior. Wherever the platform
service works (newer runtime, real device), the framework tests execute for
real — no test changes needed.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and pull requests.

Jobs:

- **Package tests** — fast ProgrammeKit suite
- **Swift formatting** — changed Swift files must satisfy `swift-format lint --strict`
- **App + widget build** — generate the Xcode project and build unsigned for the simulator
- **iPad UI tests** — always on `main`; on PRs only when app/source/project/tooling paths that can affect behavior changed

Superseded runs for the same PR/ref are cancelled automatically.

CI uses GitHub's `xcode-27` hosted runner because the app is built against the Xcode 27 toolchain while targeting iOS 26+. The runner label is currently provided by GitHub as an Apple-silicon hosted runner; if GitHub retires/renames it, update the workflow and this documentation together.

## Launch arguments

The app supports development/test launch arguments already used by UI tests:

| Argument | Effect |
|---|---|
| `-programme-uitest` | in-memory store seeded for UI tests |
| `-programme-sample` | seed the sample team into the normal store |
| `-programme-open-live` | also seed/open a live match |

Keep test-only behavior explicit and opt-in.

## External capabilities

These features need Apple/developer-service configuration but must never block ordinary local scoring development:

| Feature | Needs | Without it |
|---|---|---|
| widgets reading shared live data | App Group on app + extension | widget shows a safe open-app state |
| Live Activity | signed build/capability | scoring continues normally |
| background maintenance | signed/capability setup | cleanup/retry work simply does not run |
| iCloud sync | CloudKit container/entitlements | local-first store only |
| camera roster recognition | supported device/camera permission | manual/CSV/paste import remains available |
| official MaxPreps supplier export | supplier format specification | MaxPreps Entry Summary remains available |

Never fake these capabilities in development builds.

## Common troubleshooting

### Xcode isn't selected

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
make doctor
```

### Project is missing/stale

```bash
make generate
```

### Simulator name changed

Usually nothing needs changing; `make test-ui` discovers an available iPad. If simulator runtimes are missing entirely, install one from Xcode Settings > Components.

### Mint/XcodeGen is broken or stale

```bash
brew bundle --file Brewfile
mint bootstrap --mintfile Mintfile
make doctor
```

### CI-only UI test failure

Download the `ProgrammeUITests-xcresult` artifact from the failed Actions run and open it in Xcode. The artifact is retained briefly on purpose rather than storing large result bundles indefinitely.

## Generated files and commits

Do not commit:

- `Programme.xcodeproj`
- DerivedData/build output
- `.xcresult`
- local SPM build directories

The current `.gitignore` covers these.

## Privacy

The repository is public. Do not commit real student data, credentials, signing material, private school records, or unsanitized match archives. Use the fictional sample fixtures for tests and screenshots whenever possible.
