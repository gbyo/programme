# Programme agent guide

Use this file as a map, not as a replacement for the repository documentation.

## Read first

- [README.md](README.md) — product overview and quick start
- [CONTRIBUTING.md](CONTRIBUTING.md) — invariants and review expectations
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — event model and module boundaries
- [docs/RELIABILITY.md](docs/RELIABILITY.md) — recovery, clocks, tracked-vs-zero
- [docs/SCORING_UX.md](docs/SCORING_UX.md) — live-match interaction rules
- [docs/EXPORTS.md](docs/EXPORTS.md) — archives/import/export seams
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — commands, CI, tooling, capabilities

## Non-negotiable architecture

- Events are truth; official statistics are always derived.
- Do not persist mutable goal/minute/save/etc. totals as authoritative state.
- ProgrammeCore owns match/stat/lineup/validation rules and must not import SwiftUI or SwiftData.
- SwiftData model objects do not cross actor boundaries; map them to stable IDs and Sendable values.
- A tracked zero and a category that was not tracked are different states everywhere.
- Scoring and recovery must work with no network, account, CloudKit, MaxPreps, or server.
- Editing an old event must cause downstream statistics to re-derive; never repair derived totals manually.
- Official output must be deterministic. Never depend on dictionary/set enumeration order.

## Commands

```bash
make bootstrap    # first checkout
make doctor       # diagnose Xcode/tool/simulator setup
make test         # package/domain tests
make build        # simulator build
make test-ui      # iPad UI tests
make lint         # formatting check
make format       # apply formatting
make verify-fast  # normal pre-PR gate
make verify       # full gate including UI tests
```

`project.yml` is the Xcode project source of truth. Never hand-edit or commit `Programme.xcodeproj`.

## Change expectations

- If a domain bug is fixed, add a focused regression test.
- If event/archive schema changes, add round-trip or migration tests.
- UI changes to scoring should preserve stable targets, touch-only operation, deferred attribution, cheap correction, and minimum glance time.
- Do not mix broad style-only rewrites into behavioral changes.
- Do not add a network dependency to the path of recording a match.
- Do not invent or scrape a MaxPreps API.
- Do not use AI/LLMs to calculate official statistics.

## Definition of done

Run the narrowest relevant tests while iterating, then `make verify-fast` before finishing. Run `make verify` when live scoring, match navigation, exports, or other UI-test-covered behavior changed. If a tool or entitlement prevents a check, say exactly which check could not run and why.
