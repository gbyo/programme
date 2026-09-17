# Contributing to Programme

Programme is an official-statistics tool. Changes should optimize for correctness during a real match, quick correction when a scorer makes a mistake, and a codebase where the same event sequence always produces the same result.

## Start here

On a Mac with Xcode installed:

```bash
git clone https://github.com/gbyo/programme.git
cd programme
make bootstrap
make open
```

`make bootstrap` installs the small set of command-line dependencies in `Brewfile`, installs the pinned XcodeGen release from `Mintfile`, checks the active Xcode installation, and generates `Programme.xcodeproj` from `project.yml`.

Before opening a pull request:

```bash
make verify-fast
```

Run the full gate, including iPad UI tests, for scoring/UI changes:

```bash
make verify
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for all commands and troubleshooting.

## Architectural invariants

These are review rules, not suggestions.

1. **Events are truth. Statistics are derived.** Never persist a player's goal count, minute total, save percentage, score, or other derived value as authoritative state.
2. **ProgrammeCore owns soccer rules.** Views, exporters, persistence models, widgets, and intents do not independently calculate official statistics.
3. **ProgrammeCore stays independent.** It must not import SwiftUI or SwiftData. Domain tests should continue to run without a simulator or database.
4. **SwiftData models stay behind the persistence boundary.** Convert them to stable identifiers and `Sendable` value types before crossing actor boundaries.
5. **A tracked zero is not the same as not tracked.** Preserve this distinction in views, season aggregation, archives, CSV/PDF output, and future exporters.
6. **Scoring remains local-first.** Internet access, CloudKit, MaxPreps, widgets, or a server must never be required to record or recover a match.
7. **Corrections revise facts, not downstream totals.** Editing a substitution time changes the event timeline; the engines derive the corrected minutes.
8. **Archive/event compatibility is deliberate.** Event payload or archive schema changes require round-trip/migration coverage.
9. **Determinism matters.** Official output must never depend on dictionary/set enumeration, wall-clock scheduling, or other unstable ordering.
10. **Found stat-engine bugs get regression tests.** Prefer the smallest event sequence that proves the previous behavior was wrong.

## Repository layout

```text
App/Programme/                 application UI and composition
App/ProgrammeWidgets/          WidgetKit + Live Activity extension
App/ProgrammeUITests/          high-risk end-to-end UI flows
Packages/ProgrammeKit/
  Sources/ProgrammeCore/       events and deterministic engines
  Sources/ProgrammePersistence SwiftData + recovery journal
  Sources/ProgrammeExport/     archives/import/export
  Sources/ProgrammeUI/         reusable Apple-platform UI pieces
project.yml                    XcodeGen source of truth
```

Do not edit or commit `Programme.xcodeproj`; regenerate it with `make generate`.

## Development workflow

Create a focused branch from `main`. Keep a change small enough that its correctness can be explained and tested.

For domain changes, start in `ProgrammeCore` and add/adjust tests before wiring the result into UI. For UI-only changes, preserve the existing domain command/event path rather than introducing view-owned state that duplicates match truth.

Useful commands:

```bash
make doctor       # diagnose Xcode/tool/simulator setup
make generate     # regenerate Programme.xcodeproj
make test         # fast package/domain suite
make build        # unsigned simulator build
make test-ui      # iPad UI tests
make format       # apply swift-format
make lint         # check formatting without changing files
make verify-fast  # doctor + format + package tests + build
make verify       # same, plus UI tests
```

## Code style

Programme uses the `swift-format` binary shipped with the selected Xcode toolchain and the repository's `.swift-format` configuration.

Run:

```bash
make format
```

before committing Swift changes. CI checks formatting but does not rewrite a PR.

Avoid style-only rewrites mixed with behavior changes. If a formatter configuration change produces broad churn, make that a separate PR.

## Testing expectations

A change to an official statistic, lineup behavior, match rules, validation, tracked-state semantics, recovery, or archive import/export requires deterministic package coverage.

UI tests are reserved for the highest-risk user journeys: creating/opening a match, recording events, substitution, undo/edit, period transitions, review/finalization, and export.

When a test fails only on the simulator, preserve the `.xcresult` bundle. CI uploads it automatically when the UI-test job fails.

## Scoring UX changes

Evaluate scoring UX from the sideline, not as a normal form-based app. Ask:

- How many intentional taps does the common case require?
- Does the scorer have to stop watching play to answer a question?
- Are targets stable enough for muscle memory?
- Can incomplete attribution be deferred?
- Is a mistake cheap to undo or revise?
- Does the interaction still work with touch only?

Do not reorder the action palette based on usage frequency.

## Pull requests

Explain what changed, why, and how it was verified. UI PRs should include a screenshot or short recording when it helps review.

The PR template contains an architecture checklist. Do not check a box unless the statement is actually true for the change.

## Privacy in bug reports and fixtures

Do not commit or attach credentials, private school records, or real student personal data. Reduce bugs to fictional/sample data or sanitize a `.programme` archive before sharing it publicly.
