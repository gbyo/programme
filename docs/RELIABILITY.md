# Reliability and recovery

Programme is used to record facts that may not be reconstructable later. A scorer cannot be asked to remember a substitution from an hour ago because the app lost state.

The reliability model therefore assumes that the app can be backgrounded, killed, lose network access, or encounter a database write interruption during a live match.

## Offline first

The complete scoring path must work without:

- Wi-Fi or cellular data
- an account
- CloudKit
- MaxPreps
- widgets or Live Activities
- a server

Network-backed features are optional replication or presentation layers, never a prerequisite for recording a match.

## Durable event path

When the scorer records an event, Programme updates the in-memory match context immediately for responsiveness, writes the event to the recovery journal, and queues the corresponding SwiftData work.

The recovery journal is append-oriented and match-specific. It contains enough match/roster context to reconstruct an interrupted match even if the database is unavailable.

A partial final line caused by abrupt termination is ignored; completed earlier entries remain usable.

## Journal reconciliation

On startup, Programme examines unfinished database matches and open journals.

A journal is trusted as a crash-recovery extension only when it is a **strict extension** of the database's event identity set: all stored events are present and the journal contains additional events.

A journal that merely has more events but disagrees with the stored identity set may belong to another lifetime of that match identifier, such as a restored archive or re-import. It must not resurrect intentionally deleted/replaced events.

This rule exists because “journal has a larger count” is not sufficient evidence that the journal is newer truth.

## Interrupted matches

Programme never silently discards an unfinished match. If recoverable state exists, launch should offer a clear resume/review path with the match identity and number/time of safely stored events.

The user should be able to distinguish:

- a normal scheduled/completed match
- a match actively in progress
- a match interrupted by app/process termination
- a journal-only match recoverable without its SwiftData row

## Match clock

The clock is based on anchors, not repeated timer increments.

A clock anchor records the elapsed match time at the last transition and the wall-clock date when running began. Display time is derived from those anchors.

Consequences:

- dropped UI frames do not lose seconds
- switching apps does not stop elapsed match time unless the clock was paused
- locking the iPad does not corrupt the clock
- the clock view can refresh without making the rest of the scoring workspace recompute every second

Clock corrections are explicit/auditable and do not silently retime past events.

## Undo and revisions

A correction changes event truth and causes every projection to re-derive.

Examples:

- deleting a goal changes score, shots, SOG, player totals, keeper line, result, and possible game-winning goal
- changing a substitution time changes the lineup intervals and therefore both players' minutes
- resolving an unknown player revises attribution rather than creating a duplicate event

Undo/redo should operate at the event/domain level. Recent corrections do not require destructive-action confirmation.

## Tracked zero vs not tracked

A published zero is a factual claim. A category Programme was not recording is unknown.

Programme therefore carries tracked-category information with the match and uses a value representation that can distinguish numeric values, not applicable, and not tracked.

The distinction must remain visible in:

- live/final match stats
- finalization/completeness review
- season totals and coverage
- CSV cells
- PDF/stat sheets
- MaxPreps entry summary
- `.programme` archives

A later stat-profile change must not retroactively claim that an older match tracked a category it did not.

## Finalization

Finalization is a validation boundary, not a destructive freeze.

Before a clean finalization, Programme checks score/goal coherence, lineup state, player and goalkeeper minutes, unresolved attribution, goalkeeper statistics, and category completeness.

A finalized match is read-mostly. If reopened and corrected, the event/revision history remains explicit and all derived output is recalculated.

## Failure messaging

When a recoverable operation fails, UI copy should answer:

1. What did not work?
2. Is the match data safe?
3. What can the user do next?

For example: “Programme couldn't create the export. Your match is safe. Try exporting again.”

Do not expose raw database/framework errors as normal user-facing copy.

## Tests that protect this layer

Important regression coverage includes:

- journal replay with no database
- database behind journal after interrupted write
- truncated journal
- stale/disagreeing journal rejection
- clock gap/background behavior
- clock correction preserving historical event times
- undo/redo across ordinary events and period transitions
- archive round trips
- tracked-zero vs not-tracked preservation
- reopening/finalizing/correcting a completed match
