# Programme

A soccer statistics application for iPadOS, built for the person standing beside
the field with three seconds to record what just happened before the ball is back
in play.

Programme is a scorebook, not a dashboard. It is designed so that a single
scorer can record an entire high-school match accurately while looking at the
iPad as little as possible, and so that the resulting statistics can be trusted
enough to publish.

---

## Contents

- [The central idea](#the-central-idea)
- [Architecture](#architecture)
- [Data model](#data-model)
- [The statistics engine](#the-statistics-engine)
- [Reliability and recovery](#reliability-and-recovery)
- [The scoring workspace](#the-scoring-workspace)
- [Tracked versus zero](#tracked-versus-zero)
- [Exports and MaxPreps](#exports-and-maxpreps)
- [Project layout](#project-layout)
- [Building and running](#building-and-running)
- [Testing](#testing)
- [Features requiring external configuration](#features-requiring-external-configuration)
- [Deliberate design decisions](#deliberate-design-decisions)

---

## The central idea

**Events are truth. Statistics are derived.**

Programme never stores a player's goal count. It stores that a shot happened, by
whom, with what outcome, at what moment — and derives everything else from the
ordered series of those events.

This is the decision the rest of the application follows from:

- Editing the time of a substitution recorded an hour ago automatically corrects
  both players' minutes, because minutes were never stored in the first place.
- Deleting a goal corrects the score, the scorer's total, the assister's total,
  the shot count, the shot-on-goal count, the goalkeeper's goals allowed, the
  save percentage and the game-winning goal, all at once, because none of them
  were ever written down independently.
- There is no code path by which a statistic can drift away from the events that
  justify it.

A goal is a shot outcome. A save is an opponent shot outcome. They cannot
contradict each other because they are the same fact recorded once.

---

## Architecture

```
SwiftUI view
  → LiveMatchSession (observable, main actor, in memory)
    → MatchCommand
      → MatchEngine.perform      validates, produces effects
        → [MatchEffect]
          ├─ applied in memory              (instant — same frame as the tap)
          ├─ appended to the recovery journal and flushed   (durable)
          └─ queued to MatchStore           (SwiftData, off the main actor)
            → StatEngine.snapshot           derives every number
            → ValidationEngine.issues       derives what needs review
              → UI updates
```

Four library modules plus the app target, with enforced dependency direction:

| Module | Depends on | Responsibility |
|---|---|---|
| `ProgrammeCore` | nothing | The rules. Events, engines, statistics, validation. No SwiftUI, no SwiftData, no persistence. |
| `ProgrammePersistence` | Core | SwiftData schema, the `@ModelActor` store, the recovery journal. |
| `ProgrammeExport` | Core | The `.programme` archive, CSV, PDF, MaxPreps entry summary, roster import. |
| `ProgrammeUI` | Core | Design tokens, the pitch drawing, Live Activity attributes, widget snapshot. |
| `Programme` (app) | all four | Composition, navigation, the scoring workspace. |

`ProgrammeCore` is a pure Swift module with no framework dependency beyond
Foundation. Every engine in it is a free function over value types: the same
events in always produce the same numbers out. This is what makes the domain
testable without a simulator, a database or a view.

### Concurrency

The project builds under Swift 6 language mode with complete concurrency
checking.

- SwiftData model objects never cross an actor boundary. `MatchMapper` translates
  them into `Sendable` value types (`MatchContext`, `PlayerSnapshot`,
  `MatchEvent`) at the edge, and the domain only ever sees those.
- Database work that should not block the interface runs on `MatchStore`, a
  `@ModelActor`.
- The single deliberate exception is documented in `LiveMatchSession`:
  ActivityKit's `Activity` is not annotated `Sendable`, so it is wrapped in a
  single `@unchecked Sendable` box rather than relaxing checking anywhere else.

---

## Data model

### Domain (value types, in `ProgrammeCore`)

```swift
MatchEvent
  id, matchID
  time: MatchTime        // period + seconds elapsed in that period
  sequence: Int          // total, stable ordering within a match
  recordedAt: Date       // wall clock, for recovery display only
  payload: EventPayload  // the enum below
  revision: Int
  voidedAt: Date?        // soft delete, so undo is trivial
  revisions: [EventRevision]  // audit trail
```

`EventPayload` is a closed enum: `lineupSet`, `periodStarted`, `periodEnded`,
`clockAdjusted`, `shot`, `corner`, `steal`, `foul`, `offside`, `card`,
`substitution`, `goalkeeperChanged`, `shootoutAttempt`, `matchFinalized`, `note`.

A `ShotEvent` carries the shooter, the outcome (`offTarget`, `blocked`,
`woodwork`, `saved`, `goal`), an optional assist, the goalkeeper facing it, an
optional pitch location, phase of play and an own-goal flag. Shots on goal are
**derived** from the outcome (`saved` or `goal`), never recorded separately.

`PlayerRef` distinguishes three things that are easy to conflate:

| Case | Meaning | Appears in Needs Review |
|---|---|---|
| `.player(id)` | Attributed | No |
| `.unidentified` | Our player, number not read — resolve later | **Yes** |
| `.untracked` | Deliberately not attributed (opponent in *Our Team* mode) | No |

### Persistence (SwiftData, in `ProgrammePersistence`)

`TeamModel`, `SeasonModel`, `PlayerModel`, `MatchModel`, `MatchEventModel`, with
`#Unique` and `#Index` on stable UUIDs and explicit cascade rules.

Two decisions worth knowing:

- **Event payloads are stored as versioned JSON**, with the scalar fields needed
  for sorting and filtering (period, seconds, sequence, category,
  awaits-attribution) denormalised into columns. Adding a new event kind is a
  code change, not a store migration, and an archive written by an older build
  still round-trips.
- **A match freezes its roster.** Renaming or removing a player next season never
  rewrites a match that was already played. A player with match history is
  archived rather than deleted.

`MatchModel` also carries a small denormalised cache (score, event count, review
count) purely so list screens render without deriving a season's worth of
statistics. It is refreshed from an authoritative snapshot and is never read as
truth.

---

## The statistics engine

### Playing time

Minutes come from `LineupEngine`, which walks the events and produces
`PlayingInterval`s — one per continuous stretch of a player being on the field,
and separately one per stretch in goal.

Periods are laid on a single continuous seconds axis using their **actual**
lengths, taken from `periodStarted` / `periodEnded` events, so a half that ended
early counts as the minutes actually played, and overtime accumulates on top of
regulation.

A red card ends a player's interval and is not replaced. Re-entry opens a second
interval. Nothing anywhere keeps a running per-player counter.

### Derived statistics

`StatEngine.snapshot(context:)` produces the complete derived state:
score, shootout score, lineup timeline, team lines, per-player lines, per-keeper
lines, completeness, review queue, result and game-winning goal.

Formulas are defined once, in Core, and tested:

| Statistic | Definition |
|---|---|
| Points | `goals × 2 + assists` |
| Shots on goal | shots with outcome `saved` or `goal` |
| SOG% | `shotsOnGoal / shots`, undefined with no shots |
| Saves | opponent shots with outcome `saved`, credited to the keeper in goal at that moment |
| Shots on goal faced | `saves + goalsAllowed`, by construction |
| Save% | `saves / shotsOnGoalFaced`, undefined when untested |
| GAA | `goalsAllowed × regulationLength / secondsPlayed`, using **that match's** rules |
| Game-winning goal | the `(loser's final total + 1)`-th goal by the winner, chronologically; a shootout never produces one |
| Shutout | a clean sheet played end to end by one keeper; a split clean sheet is recorded as a **shared** shutout for each, so season totals never overstate either |

Two conventions are worth stating explicitly because systems differ:

- An **own goal** counts for the other team, is never credited to a scorer as a
  goal or a shot, and is charged to the conceding goalkeeper as a shot on goal
  faced that was not saved — which keeps `saves + GA == SOG faced` true and save
  percentage coherent.
- The **goalkeeper decision** (W/L/T) goes to the keeper with the most minutes;
  equal minutes go to whoever finished the match in goal, and any remaining tie
  is broken by a stable identifier ordering. Nothing Programme derives is allowed
  to depend on the order a dictionary happens to enumerate in, and there is a
  test that asserts repeated derivation is identical.

### Validation

`ValidationEngine` continuously answers "is this match internally coherent?" and
classifies what it finds as `info`, `review` or `blocking`:

too many or too few active players · an event credited to a benched player ·
no goalkeeper on the field · a goalkeeper not in the lineup · goals allowed not
matching the score · duplicate or uneven substitutions · re-entry against the
ruleset · a goal assisted by its own scorer · events outside a period that was
played · a period never ended · unresolved attribution · events recorded in a
category the profile does not track.

Only `blocking` issues stand between a match and a clean finalization. Nothing
here interrupts live scoring — it all surfaces through the Review affordance in
the corner of the scoring bar.

---

## Reliability and recovery

Programme is an official-statistics tool. A stat keeper cannot be asked to
re-watch a match.

**Nothing about scoring requires the network.** No account, no server, no
CloudKit, no MaxPreps. A match works from kickoff to finalization entirely
offline.

**Every event is durable before the interface reports success.** Recording an
event:

1. applies to the in-memory `MatchContext` (the UI updates in the same frame),
2. is appended to a write-ahead journal and `fsync`ed,
3. is queued, in order, to the SwiftData store.

The journal is an append-only JSON-lines file per match, opening with a header
that carries the match descriptor and roster. That means **a match can be
reconstructed from its journal alone**, with no database — which is exactly what
happens if the store is ever damaged. A journal truncated mid-write by a dying
battery loses only the incomplete final line.

**On launch, Programme looks for unfinished matches** in both the database and
the journal directory and offers to resume them:

```
Resume Ninety Six vs Dixie
Last event 8:17 PM · 184 events safely stored
                                    [ Review ]  [ Resume ]
```

If the journal is ahead of the database — a crash between the durable append and
the store write — the journal wins and the store is repaired from it. An
unfinished match is never silently discarded.

A journal is only believed when it genuinely *extends* the stored match: every
event the database holds must appear in it, plus more. That is exactly what a
crash mid-write looks like. A journal that merely has *more* events but not
*those* events belongs to a different life of the same identifier — a re-import,
a restored backup — and is discarded rather than allowed to resurrect events that
were deliberately removed.

**The clock is never a tick counter.** Programme stores a `ClockAnchor`: elapsed
time at the last transition plus the wall-clock date the clock was started. The
displayed time is derived from those anchors. Locking the iPad, switching apps
for ten minutes, or dropping animation frames cannot corrupt match time. Clock
corrections are recorded as auditable events and deliberately do **not** rewrite
the timestamps of events already recorded.

---

## The scoring workspace

The workspace is laid out around three things and adapts by width, collapsing
less important content before shrinking any touch target:

| Width | Layout |
|---|---|
| ≥ 960pt | lineup · centre stage · palette |
| ≥ 680pt | lineup · palette (the stage takes over when an action needs it) |
| < 680pt | palette or lineup by segmented control; the stage takes over when needed |

**Two taps, in either direction.** Tap a player then an action, or an action then
a player. Both work, so nobody has to remember which one Programme expects. The
action palette's order never changes during a match — muscle memory is worth more
than any personalisation.

**Event entry happens in the centre panel, not in a sheet.** A modal over a live
match hides the score and the clock at exactly the moment the scorer needs them,
and puts a dismiss gesture between them and the next play.

**Deferred attribution is a first-class path, not an edge case.** "Player
unknown" is a full-width button on every player picker. The event is recorded
immediately, counts toward team totals, and lands in Needs Review to be settled
at halftime.

**Substitutions get the same priority as goals.** A dedicated mode shows on-field
and bench players in two columns, supports selecting several of each, and commits
them all at one timestamp. An impossible substitution is unreachable rather than
merely rejected. If the goalkeeper is coming off, the mode asks who takes the
gloves before it will commit.

**A shootout has its own screen.** It is not live play — there is time between
kicks and the scorer is reading names off a sheet — so it gets a dedicated view
that alternates sides, records each kick as its own event, and decides the result
without those kicks ever counting toward the score or a player's goal total.

**Undo is one tap and never asks for confirmation** — deleting an event recorded
two seconds ago is a correction, not a destructive act. Undo also reverses period
transitions, restoring the clock and phase, so a mis-tapped "End 1st" costs one
tap to fix. Deleting a whole match, by contrast, gets a real confirmation.

**The pitch earns its space.** It is a vector drawing (`Canvas`, real proportions)
that carries the shot map, accepts a touch or Apple Pencil tap to place a
location, and previews the prospective point under a hovering Pencil. Markers are
told apart by **shape** first — filled ring for a goal, filled circle for on
target, hollow circle for off, square for blocked, diamond for woodwork — so the
map reads with Differentiate Without Colour on. When a match is not tracking shot
locations, the centre carries the live team comparison instead of sitting empty.

**The clock lives in its own observable object.** That is a performance decision
with a user-visible consequence: a second ticking over invalidates only the views
that read the time, so the lineup, palette and pitch do not recompute once a
second while someone is trying to tap them.

---

## Tracked versus zero

This distinction runs through the entire application, because a published zero is
a claim and an untracked category is not.

Each match records a **stat profile** — which categories were being recorded.
Every statistic is surfaced as a `StatValue`, which is either `.count(n)`,
`.rate(x)`, `.notApplicable` or `.notTracked`. The `StatValueText` view is the
only thing in the app that renders a statistic, so a view cannot accidentally
format an `Int` and lose the distinction.

It is preserved end to end:

- **In a match** — the finalization screen lists every category as Complete,
  Needs Review or Not tracked.
- **In season totals** — a category contributes only from matches that tracked
  it, and the season page reports coverage ("Steals — 6 of 18 matches").
- **In exports** — a blank CSV cell means not tracked; `0` means zero. Every
  export states this in plain language.
- **Across an archive round trip** — the tracked set travels with the match.

Profiles ship as **Score Only**, **MaxPreps** (the default), **Standard** and
**Advanced**. The profile controls which quick actions appear and which follow-up
questions are asked, which is what makes recording a shot two taps rather than
five. Changing a profile later never changes what a played match meant.

---

## Exports and MaxPreps

Everything goes through one seam:

```swift
protocol StatExporter {
    func export(_ payload: ExportPayload) throws -> Data
}
```

Shipping implementations: **Programme Archive** (`.programme`), **MaxPreps Entry
Summary**, **Stat Sheet** (text), **Stat Sheet (PDF)**, **Box Score (CSV)**,
**Season Totals (CSV)**.

The PDF is typeset with Core Text — a real scorebook page with a box score,
goalkeeping table, timeline and completeness list — and has no UIKit dependency,
so it is testable.

### On MaxPreps

Programme treats MaxPreps as an **export destination, not a database**. It does
not scrape MaxPreps and it does not pretend to have an API that has not been
published.

Until official supplier requirements are available, Programme produces a
**MaxPreps Entry Summary**: players in jersey order, using MaxPreps' own stat
names and column order, so Team Admin entry is a straight transcription rather
than a hunt. Categories the match did not track print as `—`, with a line
explaining that a dash is unknown and not zero.

When an official specification is available, implementing it means adding one
type conforming to `StatExporter`. Nothing in the event model, the statistics
engine or the interface has to change.

### The `.programme` archive

A single versioned JSON document containing a manifest (format identifier, schema
version, generator, team, match count) and, per match, the descriptor, both
rosters, every event including voided ones and full revision history, the clock,
the phase and the tracked-category set.

It is forward-migratable by construction: unknown keys written by a newer build
are ignored, a newer schema version is refused with a message that says what to
do, and `ArchiveMigrator` has an explicit place for each future migration step.
Archives drag, AirDrop, attach to mail and drop back onto Programme to import,
via `Transferable`. On iPadOS 27 they also open as real documents from Files,
built on the current `Document` protocol rather than the deprecated
`FileDocument`.

---

## Project layout

```
Programme/
├── project.yml                     XcodeGen project definition
├── Packages/ProgrammeKit/
│   ├── Sources/
│   │   ├── ProgrammeCore/          Events, engines, statistics, validation, fixtures
│   │   ├── ProgrammePersistence/   SwiftData schema, @ModelActor store, recovery journal
│   │   ├── ProgrammeExport/        Archive, exporters, PDF, roster import
│   │   └── ProgrammeUI/            Design tokens, pitch, Live Activity, widget snapshot
│   └── Tests/
│       ├── ProgrammeCoreTests/
│       ├── ProgrammeExportTests/
│       └── ProgrammePersistenceTests/
└── App/
    ├── Programme/
    │   ├── AppIcon.icon            Icon Composer document
    │   ├── App/                    Entry point, AppModel, navigation, support
    │   ├── Live/                   The scoring workspace
    │   ├── Matches/                Today, matches, match detail, creation
    │   ├── Roster/                 Roster, players, CSV and camera import
    │   ├── Season/                 Season statistics and charts
    │   ├── Export/                 Export sheet, archive document
    │   ├── Settings/
    │   └── Intents/                App Intents, App Entities, Spotlight
    ├── ProgrammeWidgets/           Widgets and the match Live Activity
    └── ProgrammeUITests/
```

---

## Building and running

Requirements: Xcode 27 or later, iOS 26 deployment target (iOS 27 SDK).

```bash
brew install xcodegen      # once
xcodegen generate
open Programme.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Programme.xcodeproj -scheme Programme \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

`project.yml` is the source of truth for the project. Re-run `xcodegen generate`
after adding files.

### Launch arguments

Used by the UI tests, and useful for exploring:

| Argument | Effect |
|---|---|
| `-programme-uitest` | In-memory store, seeded with the sample team |
| `-programme-sample` | Seed the sample team into the real store |
| `-programme-open-live` | Also seed a match in progress and open the scorer |

They do nothing unless passed. The first-run screen also offers **Explore with a
Sample Team**, which loads the same fictional Ninety Six squad and four played
matches.

---

## Testing

The domain suite is the critical one, and it runs in under a second with no
simulator:

```bash
swift test --package-path Packages/ProgrammeKit
```

Coverage includes: a starter playing the full match · substitution out and back
in · several substitutions at one timestamp · minutes correct at every
substitution minute (parameterised) · goalkeeper replacement · period boundaries ·
overtime · a period that ended early · a dismissal ending an interval · editing a
substitution's time repairing both players' minutes · goal implying shot and shot
on goal · every shot outcome mapping (parameterised) · deleting a goal · converting
a saved shot to a goal without duplicating it · assist correction · own goals ·
penalties · cards · shootouts deciding a result without creating goals ·
save percentage (parameterised) · GAA · full and shared
shutouts · the goalkeeper decision, including that repeated derivation is
identical · results and the game-winning goal · both opponent tracking modes,
including that opponent players never leak into our totals · validation of
lineups, substitutions, benched players and re-entry · unknown-player resolution
revising rather than duplicating · clock anchors surviving a gap · clock
correction not rewriting history · undo and redo including period transitions ·
tracked zero versus not tracked · season aggregation and coverage · archive round trips,
schema gating and forward compatibility · CSV and MaxPreps output · roster
import · journal replay with no database · a journal truncated mid-write ·
recovery discovery · SwiftData persistence and archive import.

There is also an end-to-end test that plays the full acceptance scenario —
kickoff, a shot, a save, an assisted goal, a substitution, correcting that
substitution's time, an unidentified shot, halftime, resolving the attribution,
a re-entry, full time, finalization — and asserts every resulting number.

UI tests cover the highest-risk flows — opening the scorer, recording in both
tap directions, the single-tap opponent save, deferring attribution, undo without
confirmation, batched substitutions, the review queue, the event log and editing,
the halftime check, creating a match, the tracked-versus-zero distinction on a
finished match, and producing an export:

```bash
xcodebuild test -project Programme.xcodeproj -scheme Programme \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
```

If a bug is found in the engine, the fix is accompanied by a regression test. UI
snapshot tests are not treated as a substitute for domain tests.

---

## Features requiring external configuration

These are implemented but cannot be fully activated without capabilities that
belong to a developer account. Programme works completely without every one of
them, and none of them is on the path of recording a match.

| Feature | What it needs | Behaviour without it |
|---|---|---|
| **Widgets reading live data** | An App Group (`group.org.programme`) on the app and the widget extension | The app writes its widget snapshot to its own container; widgets render a "Open Programme" state rather than inventing data |
| **Live Activity** | `NSSupportsLiveActivities` (present) and a signed build; the simulator needs Live Activities enabled | `Activity.request` fails silently and scoring is unaffected |
| **Background maintenance** | `BGTaskSchedulerPermittedIdentifiers` (present) and a signed build | Journal pruning simply does not run; nothing about match correctness depends on it |
| **iCloud sync** | A CloudKit container and entitlement | `ProgrammeStore.container(cloudKit:)` takes the flag and defaults to `.none`. The architecture is in place — every event carries a stable UUID and a revision number, which is what makes conflicts explainable — but sync is deliberately not enabled, and scoring must never require it |
| **Camera roster import** | Camera permission (usage string present) | The button is hidden when `DataScannerViewController` is unavailable; CSV, paste and manual entry are unaffected |
| **MaxPreps supplier export** | Official MaxPreps import partner file specification | The MaxPreps Entry Summary is produced instead, and the seam for an official exporter is a single `StatExporter` conformance |

Nothing here is faked, stubbed to look real, or presented in the interface as
working when it is not.

---

## Deliberate design decisions

A few choices that look like omissions but are not:

- **The action palette never reorders.** No frequency-based promotion, no
  "recent actions". A scorer aiming from memory needs the Goal button to be where
  it was last week.
- **Shot outcome is chosen from the palette, not asked afterwards.** "Shot" and
  "Shot on Goal" are two buttons that create the same kind of event with
  different outcomes. That keeps common entry at two taps while leaving the data
  model with exactly one shot event.
- **Opponent events in *Our Team* mode are single taps** with no player
  attribution, which is the large workload reduction for a lone scorer. *Both
  Teams* mode uses the same engine and the same events — there is not a second
  scoring implementation. It adds an opponent roster (typed in, or pasted from a
  team sheet) and routes opponent events through the same player picker.
- **Formation is recorded, not enforced.** The starting lineup screen offers a
  formation for the matches where a coach wants it in the record, and a match is
  completely scoreable with it left unset. Dragging individual players into
  positions on the pitch is deliberately out of scope: Programme is a scorebook,
  not a tactics board, and the pitch's job during a match is the shot map.
- **Recording is never blocked by a rule violation.** A re-entry that the ruleset
  forbids still gets recorded and then flagged; the scorer is recording what
  happened. Only genuinely incoherent commands (substituting on a player who is
  already on) are refused, and the interface makes those unreachable anyway.
- **Finalizing makes a match read-mostly, not read-only.** Reopening it is one
  menu item, and every subsequent change is recorded as a revision.
- **No AI computes an official statistic.** Score, minutes, assists, save
  percentage and GAA are deterministic and derived in `ProgrammeCore`. If a
  generated match narrative is added later it will consume Programme's
  already-verified numbers, and the deterministic record stays authoritative.
- **The app icon is an Icon Composer document**, `App/Programme/AppIcon.icon`,
  not a folder of flattened PNGs. It is an open match programme with the pitch's
  centre circle straddling the fold — a scorebook rather than another soccer
  ball. Being a `.icon` means the system composes the layer, shadow, translucency
  and the light, dark and tinted appearances itself, so it behaves like a current
  iPadOS icon instead of a picture of one.
- **No analytics, no trackers, no account.** School and player data stays on the
  iPad. Exports are user-initiated. Nothing is uploaded on Programme's own
  initiative.
