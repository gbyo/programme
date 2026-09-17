## What changed

<!-- Describe the user-visible or architectural change. -->

## Why

<!-- What problem does this solve? Link an issue when one exists. -->

## Verification

- [ ] `make verify-fast` passes locally
- [ ] UI tests were run when the scoring/browsing UI changed
- [ ] Tested relevant iPad width/orientation states when UI changed
- [ ] New or changed stat behavior has ProgrammeCore regression coverage
- [ ] Archive/export compatibility was considered when persisted/event data changed

## Architecture check

- [ ] Events remain the source of truth; no derived player/team totals are persisted as authoritative data
- [ ] ProgrammeCore does not import SwiftUI or SwiftData
- [ ] SwiftData model objects do not cross actor boundaries
- [ ] Tracked zero and not-tracked remain distinct
- [ ] A match can still be scored entirely offline

## Screenshots / recordings

<!-- For UI changes, include before/after screenshots or a short recording when useful. -->
