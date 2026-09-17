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

## Stable controls

The primary event palette does not reorder itself based on usage. Muscle memory is more valuable than adaptive promotion during a match.

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

Both paths must resolve to the same domain command/event semantics rather than separate implementations.

## Centre-stage event entry

Frequent event entry happens in the centre stage instead of stacking modal sheets over the live match. The score and clock should remain visually anchored while the scorer is choosing an outcome or player.

Short secondary tasks may still use appropriate native sheets/popovers/inspectors where they do not disrupt live scoring.

## Shots and goals

A shot workflow records the shooter and outcome. A goal is one shot outcome; it must not require separately incrementing Shot, SOG, and Goal.

Typical outcomes include off target, blocked, woodwork, saved, and goal.

Detailed shot metadata such as location or phase of play is optional. The scorer must be able to complete a MaxPreps-oriented match without using the shot map.

Goal attribution should make scorer and assist selection fast. Unassisted and unusual cases remain available without cluttering the normal path.

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
