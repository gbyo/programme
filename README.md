# Programme

**A native soccer scorebook for iPadOS, built for the person beside the field who has a few seconds to record what just happened before play moves on.**

Programme is designed for accurate high-school soccer statistics without turning the iPad into a dashboard the scorer has to stare at. It keeps the live workflow fast, works offline, recovers interrupted matches, and derives every official statistic from the event history that justifies it.

## The central idea

> **Events are truth. Statistics are derived.**

Programme never treats a player's goal count, minute total, save percentage, or the match score as independent authoritative data.

If a substitution recorded at 35:00 is corrected to 31:00, Programme changes the event timeline and derives different playing intervals. Both players' minutes become correct automatically; there is no downstream total to repair.

A goal is a shot outcome. A save is an opponent shot outcome. Deleting or revising one event updates every statistic that depends on it.

## What Programme includes

- iPad-first live scoring workspace with stable, large touch targets
- player → action and action → player entry paths
- goals, assists, shots, SOG, saves, corners, cards, steals, penalties and shootouts
- automatic playing time from lineup/substitution events, including re-entry
- deferred **Player unknown** attribution and a Needs Review workflow
- one-tap undo plus event revision/history
- configurable match rules, periods, overtime and clock correction
- goalkeeper minutes, saves, save%, GAA, shutouts and W/L derivation
- tracked-zero vs **not tracked** semantics carried through every screen/export
- season totals and coverage
- roster/season storage with frozen match history
- vector shot map with touch and Apple Pencil support
- `.programme` archives, CSV, PDF/stat sheets and MaxPreps Entry Summary
- write-ahead recovery journal for interrupted matches
- widgets, Live Activity, App Intents and Spotlight integration where capabilities permit
- light/dark/accessibility-aware native SwiftUI design

## Architecture

Programme is split into four library modules plus the app:

| Module | Depends on | Role |
|---|---|---|
| `ProgrammeCore` | nothing app-specific | events, match/lineup/stat/validation/season engines |
| `ProgrammePersistence` | Core | SwiftData schema, `@ModelActor` store, recovery journal |
| `ProgrammeExport` | Core | archives, CSV/PDF, MaxPreps summary, roster import |
| `ProgrammeUI` | Core | shared visual components, pitch, Live Activity/widget data |
| `Programme` | all four | SwiftUI app composition and scoring experience |

The important boundary is enforced in code: `ProgrammeCore` has no SwiftUI or SwiftData dependency, and official statistics are defined and tested there once.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the event model, concurrency boundaries, determinism rules and statistics engine.

## Reliability

Programme is local-first. A match can be scored from kickoff through finalization with no account, network, CloudKit, server, or MaxPreps access.

Every live event is protected by an append-oriented recovery journal in addition to the SwiftData store. On launch, interrupted matches are discovered and offered for resume instead of being silently discarded.

The clock uses persisted anchors rather than incrementing an integer once per second, so locking the iPad or briefly switching apps does not corrupt match time.

See [docs/RELIABILITY.md](docs/RELIABILITY.md).

## Scoring UX

Programme's live workspace is optimized around minimum glance time:

- the action palette never reorders itself
- frequent actions remain large and stable
- event entry happens in the live workspace instead of hiding the score/clock behind stacked modals
- substitutions have a dedicated fast path
- unknown attribution can be deferred until halftime
- recent-event Undo/Edit stays visible
- noncritical inconsistencies go to Needs Review instead of interrupting play

See [docs/SCORING_UX.md](docs/SCORING_UX.md).

## Imports and exports

All exports consume the same domain-derived match data. Programme does not scrape MaxPreps or pretend an undocumented API exists.

Until an official supplier format is available, Programme produces a **MaxPreps Entry Summary** for fast manual transcription. The exporter boundary is isolated so an official supplier format can be added without changing match/stat logic.

The versioned `.programme` archive is the portable representation used for backup/transfer/import.

See [docs/EXPORTS.md](docs/EXPORTS.md).

## Quick start for development

Requirements: macOS, Xcode 27+, and an installed iOS simulator runtime.

```bash
git clone https://github.com/gbyo/programme.git
cd programme
make bootstrap
make open
```

`make bootstrap` installs the small Homebrew dependency set, prepares the pinned XcodeGen version, diagnoses the selected Xcode/toolchain, and generates `Programme.xcodeproj`.

`project.yml` is the source of truth. The generated Xcode project is intentionally gitignored.

### Common commands

```bash
make doctor       # diagnose local Xcode/tool/simulator setup
make generate     # regenerate the Xcode project
make test         # fast ProgrammeKit tests
make build        # unsigned app + widget simulator build
make test-ui      # iPad UI tests
make format       # apply Xcode's swift-format
make lint         # check formatting
make verify-fast  # normal pre-PR gate
make verify       # full gate including UI tests
```

The domain suite runs without a simulator. UI tests select an available iPad simulator dynamically rather than requiring one exact device model.

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for CI, troubleshooting, launch arguments and externally configured capabilities.

## Testing

Programme has deterministic package tests covering the match/stat engines, playing-time corrections, goalkeeper calculations, validation, recovery, archive round trips, exports, tracked-state semantics and the complete acceptance scenario.

UI tests cover the highest-risk interaction paths, including live scoring in both tap directions, opponent saves, deferred attribution, undo/edit, batched substitutions, review, period breaks, match creation and export.

If an engine bug is found, the fix gets a regression test.

## Repository layout

```text
programme/
├── AGENTS.md
├── CONTRIBUTING.md
├── Makefile
├── Brewfile
├── Mintfile
├── project.yml
├── scripts/
├── docs/
├── Packages/ProgrammeKit/
│   ├── Sources/
│   │   ├── ProgrammeCore/
│   │   ├── ProgrammePersistence/
│   │   ├── ProgrammeExport/
│   │   └── ProgrammeUI/
│   └── Tests/
└── App/
    ├── Programme/
    ├── ProgrammeWidgets/
    └── ProgrammeUITests/
```

The app icon is kept as the original Icon Composer document at `App/Programme/AppIcon.icon`, so current iPadOS composes its layers/appearances instead of Programme shipping a flattened imitation of a system icon.

## Capabilities that require external configuration

The core app works without these. Signed/capability-enabled builds are needed for some system integrations such as shared widget data, Live Activities/background maintenance, and optional CloudKit sync. An official MaxPreps supplier exporter additionally requires MaxPreps' supplier file specification.

Those paths are gated rather than faked; the ordinary local scoring/export experience remains functional without them.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md). It documents the architectural invariants, test expectations, scoring-UX review rules, formatting workflow and privacy expectations for this public repository.

Coding agents should read [AGENTS.md](AGENTS.md), which intentionally acts as a short map into the deeper documentation rather than duplicating it.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Reliability and recovery](docs/RELIABILITY.md)
- [Scoring UX](docs/SCORING_UX.md)
- [Imports and exports](docs/EXPORTS.md)
- [Development and CI](docs/DEVELOPMENT.md)
- [Contributing](CONTRIBUTING.md)
