# Scoring UX

Programme's live workspace is designed for someone watching a soccer match, not someone filling out a form.

The core UX question is:

> Can the scorer record what just happened before the next play develops, without losing track of the field?

## Workspace priorities

The live screen keeps these immediately available:

- score
- period and clock
- active lineup
- frequent event actions
- substitution entry
- recent event
- undo/edit
- needs-review state

On wide iPad layouts the conceptual structure is lineup · centre stage · event palette. Narrower windows collapse secondary content before shrinking important touch targets.

The three layouts are chosen by `ViewThatFits`, not by device width. Each candidate declares the narrowest width at which it is still usable (its ideal width *is* its minimum), and the columns are given ranges rather than fixed sizes:

| Column | min | max |
| --- | --- | --- |
| Lineup | 220 | 300 |
| Centre stage | 340 | flexible, highest growth priority |
| Record | 290 | 380 |

A continuously resized Stage Manager window therefore changes layout where the content genuinely stops fitting, on any iPad. Do not reintroduce hard-coded breakpoints.

In a narrow window the Record/Lineup control is navigation between two pieces of content, not a value. It uses `TabsPickerStyle` on iPadOS 27 and the segmented style on iPadOS 26, so VoiceOver understands it as tabs where the platform allows.

## Stable controls

The primary event palette does not reorder itself based on usage. Muscle memory is more valuable than adaptive promotion during a match.

Frequency is expressed *statically*, in size and position, never in ordering:

- **Primary block** — Goal, Shot on Goal, Shot, Save, as a large 2×2 grid. These are almost every event in a match.
- **Secondary block** — Corner, Steal, Penalty Kick, Yellow, Red, More. Shorter tiles, still well past a 44pt target.
- **Pinned opponent bar** — the opponent's Goal / Shot / Corner, below the palette's scroll view and never below the fold. An opponent shot is how our goalkeeper's shots-faced and save percentage are recorded.

Against a bottom bar, do **not** leave the lineup's `scrollEdgeEffectStyle` at `.automatic`. It resolves to a hard edge effect whose view sits over the last ~114pt of the list and swallows touches — the bottom rows look tappable, report as hittable, and do nothing. The lineup is half of the scorer's two-tap path, so that is fatal. `.soft` gives the same fade with no interactive overlay, and is set explicitly for that reason.

Nothing in the toolbar appears or disappears with availability either. Redo is always rendered in its place and disabled when there is nothing to redo, so pressing Undo never moves the controls beside it.

Palette and toolbar controls are stock system button styles (`.bordered`, `.borderedProminent`) with a semantic tint. Do not hand-draw a background, a border or a pressed state for something the system already provides: a control that looks native has to behave native.

### The two bars

Programme has exactly two bars, and both are real `ToolbarContent`:

- **Navigation bar, `.topBarTrailing`** — match management: Pause/Resume (icon only), End <period>, Start Match / Start <period>, and the options ellipsis. `MatchControlsToolbar` owns them.
- **Bottom bar** — the scoring controls. `ScoringToolbar` owns them.

Neither sets a button style, a border shape or a control size. The system decides how large a navigation-bar control is, how it looks pressed, how it tracks the pointer and what it does when the window is too narrow for all of it. The single exception is Start, which uses Programme's primary-action style because starting the match is the one prominent action on the screen — and that is still a stock system style.

The scoreboard is *not* a toolbar. Team names, score, clock, period text and the progress rule are genuinely custom bar content in `LiveHeader`, presented with `safeAreaBar(edge: .top)`; it is far taller than a navigation bar and must never be squeezed into a title. `LiveHeader` owns no controls and takes no action callbacks. The navigation bar carries no title and no back button, and its background is hidden so the controls read as part of the scoreboard region instead of a second slab of material stacked above it.

Critical actions must not be:

- hover-only
- Pencil-only
- swipe-only
- tiny toolbar items
- hidden only in context menus

Touch is always sufficient.

## Two directions, same command

Common events should support either interaction order when practical:

```text
player → action
action → player
```

Both paths must resolve to the same domain command/event semantics rather than separate implementations. Keyboard shortcuts route through the same path as well, via `LiveActionRequest`.

When a player is armed, the Record column states who the next action will be credited to, with a one-tap Clear. The lineup highlight alone is not enough: by the time the scorer is aiming at Record, that row is out of their field of view.

### Who an event may be attributed to

`AttributionEngine` in ProgrammeCore answers "which players could legitimately be responsible for this?". The interface asks; it does not encode the rule.

| Category | Scope |
| --- | --- |
| Shot, goal, assist, penalty, own goal, corner, steal, foul, offside, goalkeeper change | on the field |
| Card | the available roster, including the bench |

Dismissed players are never offered. Bench rows stay visible in the lineup but do not arm for ordinary live play; they are reachable through Substitution and through More. An armed player who is not a legitimate candidate for the action just tapped falls through to the picker rather than being recorded.

`ValidationEngine` remains the safety net for events arriving from an import, an edit or a repaired file. The difference is that the normal interface now makes an impossible attribution unreachable rather than merely flagging it afterwards.

## Centre-stage event entry

Frequent event entry happens in the centre stage instead of stacking modal sheets over the live match. The score and clock should remain visually anchored while the scorer is choosing an outcome or player.

Short secondary tasks may still use appropriate native sheets/popovers/inspectors where they do not disrupt live scoring.

## Shots and goals

A shot workflow records the shooter and outcome. A goal is one shot outcome; it must not require separately incrementing Shot, SOG, and Goal.

Typical outcomes include off target, blocked, woodwork, saved, and goal.

Detailed shot metadata such as location or phase of play is optional. The scorer must be able to complete a MaxPreps-oriented match without using the shot map.

Goal attribution should make scorer and assist selection fast. Most goals are unassisted, so Unassisted is a single full-width primary target across the top of the assist stage (and the Return key), not one option among several. "Assist Unknown" stays available as the quiet row underneath.

A penalty is an **attempt**, not a goal that has yet to be confirmed. The flow is *who took it* → *what happened* (Goal / Saved / Missed / Post or Crossbar), and neither the wording nor the state implies a goal until the outcome is chosen. A penalty goal is never assisted, so Programme does not ask.

Secondary event selection (blocked, woodwork, second yellow, foul, offside, own goal, change goalkeeper) is a native `Menu`, not a sheet. Choosing one drops straight into the centre stage that asks who it belonged to. A sheet is only correct when the task genuinely deserves its own workspace — the lineup, the clock correction, finalization.

## Opponent events

In **Our Team** mode, opponent actions should capture only what Programme needs to derive our team's official statistics. Do not force player attribution Programme does not need.

In **Both Teams** mode, the same event engine accepts an opponent roster and full attribution.

Do not build separate stat logic for the two modes.

## Deferred attribution

The scorer will sometimes see an event but miss the jersey number.

“Player unknown” is a first-class option. Programme records the event immediately, includes its team-level effect where appropriate, and marks attribution for later review.

At halftime or full time, the scorer can resolve the existing event. Resolving attribution must revise the event rather than add a duplicate.

## Substitutions

Substitution entry is a dedicated high-speed mode with current players and bench players clearly separated.

Normal flow:

```text
OUT → IN → commit at current match time
```

Support multiple substitutions at one timestamp. Re-entry is represented as another playing interval when the rules allow it.

If a recorded substitution time is corrected later, the event changes and Programme derives a new lineup timeline; the user never manually repairs minute totals.

## Recent event and correction

The live workspace keeps the most recent meaningful event visible with immediate Undo/Edit/Event Log access.

Undo is one tap and does not ask for confirmation. A just-recorded event is a reversible correction, not a permanent destructive action.

Deleting an entire match is different and should use normal destructive confirmation.

## No teaching during play

TipKit is for a scorer who is not currently executing. While the clock is running, the live workspace shows no educational UI at all. Tips may appear pregame, at a break, or on browsing screens, and events may be donated at any time — but the visible tip surface waits.

## Review instead of interruption

Noncritical coherence problems surface through Needs Review rather than modal interruptions during play.

Typical review items:

- unidentified player
- event attributed while player appears benched
- lineup inconsistency
- goalkeeper issue
- category/profile mismatch

Period breaks and finalization are natural moments to surface the queue more prominently.

## Pitch

The pitch is a scalable vector drawing and must earn its space.

Useful roles:

- optional shot placement
- shot map
- attacking direction
- limited current context

It is not a tactics board. Do not require formation placement or arbitrary drawing to keep statistics.

Shot outcomes should be distinguishable by shape as well as color so the view works with Differentiate Without Color.

## Clock rendering

The clock has its own observable state so a second changing does not invalidate the entire live workspace. Views that do not display time should not recompute simply because the clock ticked visually.

## Accessibility

Live controls need generous hit targets, meaningful VoiceOver labels, Dynamic Type tolerance, keyboard accessibility where practical, and semantics that do not rely on color alone.

Keyboard shortcuts are accelerators, not alternate business logic. They invoke the same commands as touch.

Every live shortcut is declared **once**, in `ProgrammeCommands`, so the system's own menu and shortcut overlay teach them and nothing is bound twice:

| Key | Action |
| --- | --- |
| `space` | start/stop the clock |
| `g` | goal |
| `s` | shot on goal |
| `h` | shot |
| `v` | save |
| `c` | corner |
| `b` | substitution |
| `⌘Z` / `⇧⌘Z` | undo / redo |
| `⌘E` / `⌘K` | end period / start next period |

Do not add a competing `keyboardShortcut` to a view for an action the menu already owns.

Feedback is split by role: view-state changes (arming a player, selecting a substitution candidate, placing a shot) use SwiftUI `sensoryFeedback`; domain events (recorded, goal, undone, rejected) stay imperative in `LiveMatchSession`, where the meaning lives.

## Evaluating a UX change

For every live-scoring change, ask:

1. How many intentional taps does the common path require?
2. How long must the scorer look away from the field?
3. Does the control stay in a stable location?
4. Can partial information be recorded now and fixed later?
5. Is a mistaken tap cheap to undo?
6. Does it work with touch only?
7. Does it still work offline?
8. Does the UI remain understandable in portrait, narrow Stage Manager windows, dark mode, and accessibility sizes?

A feature is not an improvement if it makes the scorer slower during play merely to produce a richer dataset afterward.
