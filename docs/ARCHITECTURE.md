# Architecture

Programme is built around one rule:

> **Events are truth. Statistics are derived.**

A match is an ordered event log plus match metadata and rules. Score, minutes, player lines, goalkeeper lines, season totals, validation results, and exports are projections of that log. No view or database row independently owns an official total.

## Dependency direction

```text
ProgrammeCore                    no app-framework dependency
    ↑
ProgrammePersistence             SwiftData + recovery journal
ProgrammeExport                  archive/import/export
ProgrammeUI                      reusable platform UI
    ↑
ProgrammeCollaboration           optional CloudKit replication/sharing
    ↑
Programme app + widget extension composition and presentation
```

`Packages/ProgrammeKit/Package.swift` enforces the library boundaries.

### ProgrammeCore

Owns the deterministic domain:

- `MatchEvent` and event payloads
- `MatchEngine`
- `LineupEngine`
- `StatEngine`
- `ValidationEngine`
- `SeasonEngine`
- match rules and match time
- stat profiles and completeness
- value snapshots used across boundaries

It must remain testable without SwiftUI, SwiftData, a simulator, or network access.

### ProgrammePersistence

Owns durable app storage:

- SwiftData models and schema
- `@ModelActor` store
- model ↔ domain mapping
- recovery journal
- denormalized list-screen caches that are never authoritative

SwiftData model instances stay inside this layer. Actor boundaries use stable IDs and `Sendable` value types.

### ProgrammeExport

Owns portable representations:

- `.programme` archives
- CSV
- PDF/stat sheets
- MaxPreps entry summary
- roster import

Exporters consume verified domain snapshots rather than querying SwiftData or recalculating statistics themselves.

### ProgrammeUI

Owns reusable Apple-platform presentation pieces, including the vector pitch, visual tokens, Live Activity attributes, and statistic rendering helpers.

### ProgrammeCollaboration

Owns optional CloudKit replication, never truth or recovery:

- one custom record zone per Team, with UUID-derived record names
- source-truth-only record mapping (no derived totals, no device preferences)
- `CKSyncEngine` coordination with a durable file-backed outbox/inbox
- deterministic event merge policy (revision wins; same-revision conflicts
  surface for review, never wall-clock)

Cloud collaboration is optional replication. Recording and recovering a live
match never depends on CloudKit.

Signed/provisioned builds are required before any device syncs: the
`iCloud.org.programme.Programme` container must exist in the Developer
Portal with the Xcode iCloud capability enabled. Until then the sync
coordinator reports unavailable and every local behavior is unchanged.
Push-notification subscriptions for timely sync are future work; the engine
syncs on launch, foreground, and after staging without them.

## App shell

Programme is iPad-first, with one adaptive `TabView` (`.sidebarAdaptable`, modern
`Tab` API) providing exactly four top-level sections: **Home | Matches | Roster
| Stats**. SwiftUI renders those as a bottom tab bar on iPhone and an adaptable
tab bar/sidebar on iPad; there is no hand-built navigation chrome and no
device branching. Each section keeps its own `NavigationStack`/`NavigationPath`
(`AppSection` + `homePath`/`matchesPath`/`rosterPath`/`statsPath` in
`NavigationModel`, which describes where the user is, not how it is presented).

A **Team is the workspace** in which those sections operate — never a
destination. `TeamWorkspace` (owned by `AppModel`) holds one selected team,
that team's current season, and the Stats tab's viewed season. Every
team-scoped screen takes its `TeamID` explicitly and fetches scoped data
(`MatchModel.teamIdentifier`, the player→team relationship) at fetch time.
Switching teams keeps the section, clears pushed team-specific state, resolves
the new current season, resets the viewed season, and refreshes widgets.

Current season vs viewed season: the current season belongs to the team and
drives Home, New Match, default filtering, player stats and widgets. The viewed
season is temporary Stats/Matches viewing state; looking at an old season never
marks it current — only Team/Season management does.

The live scorer is not a tab. While a match is being scored, `LiveMatchView`
replaces the whole browsing shell; closing it returns to the same team,
section and navigation state. The match's `MatchContext` is the source of truth
while scoring, and recovery/journal handling always uses the match's own team
identity, never the selected workspace as a guess. Export and archive import
likewise carry explicit team identity. Widgets show the selected team.

## Event model

A `MatchEvent` has stable identity, match time, stable sequence ordering, recorded wall-clock date, revision/audit information, and a closed event payload.

Important properties:

- A goal is a shot outcome, not a second unrelated counter-changing event.
- A save is an opponent shot outcome.
- Substitutions change the lineup timeline; playing time is calculated from intervals.
- Unknown attribution is represented explicitly and can be resolved later.
- Soft deletion/revisions preserve the audit trail and make undo deterministic.
- Clock adjustments are events and do not silently rewrite already-recorded match facts.

## Command flow

The live app follows this shape:

```text
SwiftUI gesture / keyboard action
    ↓
LiveMatchSession
    ↓
MatchCommand
    ↓
MatchEngine performs validation and produces effects
    ↓
match context updates immediately
    ↓
recovery journal is appended/flushed
    ↓
SwiftData write is queued through MatchStore
    ↓
StatEngine + ValidationEngine derive a new snapshot
    ↓
UI renders the new state
```

The UI never repairs a total after an edit. If an earlier substitution changes time, the event history changes and `LineupEngine` produces a different set of intervals.

## Determinism

For the same match context and event sequence, Programme must always derive the same result.

Do not derive official output from:

- dictionary or set enumeration order
- task scheduling order
- wall-clock timing outside the explicit clock model
- SwiftData fetch order without an explicit sort
- UI state

When a tie needs a rule, define a stable tie-break and test repeated derivation.

## Statistics

`StatEngine` is the only authority for official derived statistics.

Examples:

- points = `goals × 2 + assists`
- SOG comes from shot outcomes
- saves and goals allowed determine goalkeeper SOG faced
- save percentage is undefined when a keeper faced no SOG
- GAA scales goals allowed by that match's configured regulation length
- game-winning goal is derived from the chronological scoring sequence

Ratios and totals are outputs, not stored facts.

## Tracked state

Programme records which categories a match was tracking. A statistic is therefore not just an integer; it can be a count/rate, not applicable, or not tracked.

This distinction must survive every layer:

```text
Match event/profile
→ snapshot
→ UI
→ season aggregation
→ CSV/PDF/archive/export
```

Never turn `not tracked` into numeric zero.

## Validation

`ValidationEngine` reports issues without becoming a second rule engine. It checks coherence of the recorded facts, such as lineup size, attribution to benched players, goalkeeper state, unresolved attribution, period boundaries, re-entry rules, and inconsistent event relationships.

Normal scoring is not interrupted for review-level issues. Blocking validation matters at clean finalization.

## Persistence notes

Event payloads are stored in a versioned form while sortable/filterable fields are denormalized into explicit columns. Match list caches may contain score/event/review summaries, but those values are convenience caches refreshed from authoritative derivation.

A played match freezes the roster identity it was played with so later roster edits do not rewrite history.

## Testing rule

When changing a domain rule, construct the smallest event sequence that demonstrates it and test the derived output in `ProgrammeCoreTests`. Tests for official statistics should not require a simulator.
