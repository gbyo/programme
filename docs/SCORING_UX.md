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

- **Primary block** — Goal, Shot, Save. Goal spans the first row; Shot and Save share the second. Shot asks for its outcome instead of encoding one in the action itself.
- **Secondary block** — Corner, Steal, Penalty Kick, Yellow, Red, More. Shorter tiles, still well past a 44pt target.
- **Pinned opponent bar** — the opponent's Goal / Shot / Corner, below the palette's scroll view and never below the fold.

Against a bottom bar, do **not** leave the lineup's `scrollEdgeEffectStyle` at `.automatic`. It resolves to a hard edge effect whose view sits over the last ~114pt of the list and swallows touches — the bottom rows look tappable, report as hittable, and do nothing. The lineup is half of the scorer's two-tap path, so that is fatal. `.soft` gives the same fade with no interactive overlay, and is set explicitly for that reason.

Nothing in the toolbar appears or disappears with availability either. Redo is always rendered in its place and disabled when there is nothing to redo, so pressing Undo never moves the controls beside it.

Palette and toolbar controls are stock system button styles (`.bordered`, `.borderedProminent`) with a semantic tint. Do not hand-draw a background, a border or a pressed state for something the system already provides: a control that looks native has to behave native.

### The two bars

Programme has exactly two bars, and both are real `ToolbarContent`:

- **Navigation bar, `.topBarLeading`** — Close Scorer, an icon-only `xmark` that leaves the scoring workspace without implying backwards navigation or finalizing the match.
- **Navigation bar, `.topBarTrailing`** — match management: Pause/Resume (icon only), End <period>, Start Match / Start <period>, and the options ellipsis. Pause, the period transition, and the menu are separate semantic toolbar groups; fixed `ToolbarSpacer`s tell SwiftUI where unrelated jobs separate so the system owns their Liquid Glass grouping. `MatchControlsToolbar` owns them.
- **Bottom bar** — the scoring controls. `ScoringToolbar` owns them.

Neither sets a button style, a border shape or a control size. The system decides how large a navigation-bar control is, how it looks pressed, how it tracks the pointer and what it does when the window is too narrow for all of it. The single exception is Start, which uses Programme's primary-action style because starting the match is the one prominent action on the screen — and that is still a stock system style.

The ellipsis is a native `Menu`, not a button that opens an intermediate match-management sheet. It exposes secondary commands and routes commands that need a workspace — lineup, opponent roster, clock adjustment, shootout, finalization — through the scorer's single `LiveSheet` presentation owner. The visible End/Start period action remains authoritative and is not duplicated in the menu.

The scoreboard is *not* a toolbar. Team names, score, clock, period text and the progress rule are genuinely custom bar content in `LiveHeader`, presented with `safeAreaBar(edge: .top)`; it is far taller than a navigation bar and must never be squeezed into a title. `LiveHeader` owns no controls and takes no action callbacks. The navigation bar carries no title and no fake back button. Its leading Close Scorer action is the navigation escape for this replacement workspace, and its background is hidden so the controls read as part of the scoreboard region instead of a second slab of material stacked above it.

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

## The Event Composer

The live scorer has four parts, and each has exactly one job:

| Part | Job |
| --- | --- |
| **Record** | start an event |
| **Lineup** | preselect the player an event will belong to |
| **Event Composer** | ask only for information that is genuinely missing |
| **Inspector** | statistics |
| **Review** | deferred and unknown details |

The composer is not a dashboard and never shows passive statistics. It appears when an event needs completing and gives its space back when nothing does. A mini stats panel in the middle of the scorer is how that area stopped having a purpose; the numbers have one home and it is the inspector, reached from the bottom bar in every layout.

### Record the primary fact first, then enrich

This is the rule that matters most. **A goal is a goal the moment the scorer says so.** The event is written, the score moves, the journal is flushed and the goal feedback fires *before* the composer asks who assisted. The assist is recorded as `.unidentified`, so:

- **Unassisted** revises the same event to no assist.
- **A player** revises the same event with that assist.
- **Assist Unknown**, or walking away entirely, leaves it unresolved and collected under Review.

A scorer who looks back at the pitch and never answers has still recorded the goal. The same applies to the optional shot location: the shot exists with its shooter and outcome before the map is offered, so skipping costs nothing.

The exception is a **penalty outcome**, which is a primary fact rather than enrichment — a penalty whose outcome is unknown is a score that may or may not have happened — so nothing is recorded until the scorer answers.

`LiveMatchSession.recordReturningID` hands back the identity of the event just appended; `resolveAssist` and `resolveShotLocation` revise that same event. Enrichment never appends a second event.

### Presentation

One composer, three presentations, chosen by what the environment can hold:

| Environment | Layout | Composer |
| --- | --- | --- |
| Wide iPad | Lineup / Workspace / Record, all permanent | the middle column |
| iPad mini, constrained landscape, iPad portrait | Lineup / Record | takes the lineup's side while it has a question, and gives it straight back |
| Compact (iPhone, narrow Stage Manager) | Record / Lineup as tabs | a sheet, which transitions internally between questions |

Record never moves in any of them — that is the position muscle memory depends on.

The whole workspace has **exactly one `.sheet`**. The composer is a route through the same `LiveSheet` router as the event log, the lineup editor and finalization, so two presentations can never race each other and the router is the single unambiguous presentation owner. Within it, "Who scored? → Who assisted? → Where?" changes content rather than presenting three sheets in a stack; the sheet's identity is stable across composer steps for exactly that reason. Popovers are never used for Goal/Shot/Assist. Substitution is inline where there is room and uses the same sheet in compact, because it genuinely needs focused space.

The composer sheet uses `.presentationSizing(.page)` rather than a detent, which on a phone is the system's full-width, full-height page presentation instead of a panel floating in the middle of the screen. A step that is a multi-screen flow rather than a single question — substitution — brings its own `NavigationStack` and chrome, and the sheet does not wrap it in a second one.

Whether the composer is a sheet is a **product** rule before it is a layout rule: a phone always gets the sheet, and a narrow iPad window reaches the same behaviour through the platform's compact environment. An iPhone must never fall back to the iPad columns because of an unexpected size class.

In compact, tapping a player in Lineup switches back to Record automatically: having said *who*, the scorer's next tap is always *what*.

Compact is the platform's own `horizontalSizeClass`, not a width Programme invents. The choice between three columns and two is made by `ViewThatFits`.

## Centre-stage event entry

Frequent event entry happens in the centre stage instead of stacking modal sheets over the live match. The score and clock should remain visually anchored while the scorer is choosing an outcome or player.

Short secondary tasks may still use appropriate native sheets/popovers/inspectors where they do not disrupt live scoring.

## Shots and goals

A shot workflow records the shooter and outcome. There is one ordinary Shot action, followed by the neutral question *what happened?* with Goal / Saved / Off Target / Blocked / Post or Crossbar. The scorer can use either *player → Shot → outcome* or *Shot → player → outcome*. No shot event is written until both the shooter and outcome are known.

Goal remains a primary fast path, but Goal selected from the Shot outcome stage uses the same goal-recording path, including score feedback and assist handling. Save also remains primary because it records our goalkeeper stopping an opponent shot; that is a different observation from recording one of our attacking shots.

Typical outcomes include off target, blocked, woodwork, saved, and goal.

Detailed shot metadata such as location or phase of play is optional. The scorer must be able to complete a MaxPreps-oriented match without using the shot map.

Goal attribution should make scorer and assist selection fast. Most goals are unassisted, so Unassisted is a single full-width primary target across the top of the assist stage (and the Return key), not one option among several. "Assist Unknown" stays available as the quiet row underneath.

A penalty is an **attempt**, not a goal that has yet to be confirmed. The flow is *who took it* → *what happened* (Goal / Saved / Missed / Post or Crossbar), and neither the wording nor the state implies a goal until the outcome is chosen. A penalty goal is never assisted, so Programme does not ask.

Secondary event selection (second yellow, foul, offside, own goal, change goalkeeper) is a native `Menu`, not a sheet. Blocked and woodwork belong to Shot's outcome stage rather than More. Choosing a secondary event drops straight into the centre stage that asks who it belonged to. A sheet is only correct when the task genuinely deserves its own workspace — the lineup, the clock correction, finalization.

## Opponent events

In **Our Team** mode, opponent actions should capture only what Programme needs to derive our team's official statistics. Do not force player attribution Programme does not need.

The pinned opponent Shot stays the existing one-tap off-target team attempt in this mode. An on-target opponent attempt stopped by our goalkeeper is entered with the primary Save action, which keeps that common goalkeeper observation to one tap.

In **Both Teams** mode, the same event engine accepts an opponent roster and full attribution. Because opponent Shot already proceeds through that roster picker, it also uses the shared outcome stage so the attributed opponent attempt can be recorded accurately. Shot-location enrichment is symmetric in this mode: an attributed opponent shot is offered the same optional location step as our shots, because Both Teams means tracking both teams' shots, not just attributing them.

Do not build separate stat logic for the two modes.

## Deferred attribution

The scorer will sometimes see an event but miss the jersey number.

“Player unknown” is a first-class option. Programme records the event immediately, includes its team-level effect where appropriate, and marks attribution for later review.

At halftime or full time, the scorer can resolve the existing event. Resolving attribution must revise the event rather than add a duplicate.

## Substitutions

**A substitution is a pair, not two selections.** One player comes off and one specific player comes on *for them*. The draft is a list of those pairs — `SubstitutionPlan` in ProgrammeCore — and every candidate list is derived from it, so a player already spoken for on either side disappears from the choices rather than being rejected later.

Normal flow:

```text
Substitution → Smith off → Jones on → Record
```

Two changes at once need no "add another" tap, because a completed pair puts the scorer straight back where the next one starts:

```text
Substitution → Smith → Jones → Brown → Davis → Record
```

The whole batch is still **one event at one match time**. At commit the pairs flatten in order:

```swift
playersOut = plan.pairs.map(\.playerOut)
playersIn  = plan.pairs.map(\.playerIn)
```

so `playersOut[n]` is the player `playersIn[n]` replaced. The stored schema is unchanged; the relationship is carried by the array order, which is what lets a multi-substitution narrate as `#13 Ferrer for #11 Trotter; #14 Hollis for #6 Kinard` rather than two lists the reader has to pair up.

`MatchEngine.validateSubstitution` still permits unequal counts, and it should: a side may legitimately play short, and the engine is also the gate for imports and edits. The *normal* interface simply never produces one. Narration handles the unequal case honestly (`… ; #6 Kinard off`) instead of forcing a pair.

Candidates always come from live lineup state rather than from the roster, so under unlimited re-entry a player who came off ten minutes ago is offered again from the bench. Re-entry is represented as another playing interval when the rules allow it.

Nothing about the lineup moves while a draft is being assembled, so Cancel discards it completely and Undo reverses the whole batch as one event. If a recorded substitution time is corrected later, the event changes and Programme derives a new lineup timeline; the user never manually repairs minute totals.

### Two presentations of one draft

| Environment | Shape |
| --- | --- |
| iPhone, and any compact window | A pushed `NavigationStack` inside the composer sheet: **Who is coming off?** → **Coming On** → back to the root, ready for the next pair |
| Regular-width iPad | **Coming Off** beside **Coming On**, where the right column only ever answers *for whom* |

On the phone the flow uses real navigation chrome, not a hand-built header: the title is `Substitution`, the navigation subtitle is the period and clock (`1st · 24:18`), Cancel is the leading action, and the trailing confirmation (`Record`, `Record 2`) appears only once at least one complete pair exists. The Coming On screen's subtitle is the relationship itself — `For #11 Trotter` — so it cannot be answered without knowing who it is for. Completed pairs sit in a **Ready** section above the remaining outgoing players and are removed with a native destructive `swipeActions`, or corrected by tapping the row.

On iPad the two columns keep the advantage of seeing the field and the bench at once, but the interaction is still pair-aware: tapping a player on the left makes them the active outgoing selection, the right column says `Coming on for #11 Trotter`, and tapping there forms the pair and clears the selection for the next one. The right column is secondary until it has a question to answer. There is no large `arrow.left.arrow.right`, no selectable tile grid, and no horizontal goalkeeper carousel.

Both presentations are `List`, `Section` and navigation destinations — system components, system separators, system swipe actions. The jersey number is the fastest identifier, so it is monospaced and given a stable width for names to align against. Programme's accent is used for selection and confirmation only.

### Goalkeeper replacement

Replacing the goalkeeper is a first-class exceptional step, not another picker stuffed under the main interface. If the batch takes the current goalkeeper off, it **cannot** commit until Programme is told who is in goal afterwards, because every later save is attributed from that answer.

Candidates are the players who will actually be on the field once every pending pair is applied — whoever stays on, plus whoever comes on. Recognised goalkeepers sort first and are marked, but Programme never assumes the incoming player takes the gloves because of a roster position. If a later pair invalidates the choice, it is cleared and asked again.

On the phone the question is pushed the moment the relevant pair completes, and answering it returns to the root. On iPad it takes over the right-hand column, in the same place the question would otherwise be answered.

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

Review and correction keep their hierarchy inside the task that opened them. Choosing an
unresolved event pushes **Assign Player** from Review, and choosing an event in Event Log pushes
**Edit Event**. Resolving, deleting, or finishing naturally returns to the same Review or Event Log
instead of replacing one sheet with another.

Shootout entry uses a native single-value player picker. There is time between kicks, only one
taker can be current, and the pushed choice list keeps the whole numbered roster readable on both
iPhone and iPad without turning the live scoring palette into a generic form.

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
| `s` | shot |
| `v` | save |
| `c` | corner |
| `b` | substitution |
| `⌘Z` / `⇧⌘Z` | undo / redo |
| `⌘E` / `⌘K` | end period / start next period |

Do not add a competing `keyboardShortcut` to a view for an action the menu already owns.

Feedback is split by role: view-state changes (arming a player, selecting a substitution candidate, placing a shot) use SwiftUI `sensoryFeedback` through Programme's shared `programmeSensoryFeedback` modifier; domain events (recorded, goal, undone, rejected) stay imperative in `LiveMatchSession`, where the meaning lives. Both paths obey the same app-wide Haptic Feedback preference. Native system controls keep their own platform-provided feedback.

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
