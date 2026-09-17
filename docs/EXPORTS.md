# Imports, exports, and portable data

Programme treats exports as projections of verified match truth. Export code consumes domain snapshots/events; it does not independently recalculate official statistics from persistence models.

## Export seam

Export implementations conform to the shared exporter abstraction in `ProgrammeExport`.

Shipping output includes:

- `.programme` archive
- MaxPreps Entry Summary
- text/stat sheet
- PDF stat sheet
- box score CSV
- season totals CSV

A future official MaxPreps supplier format should be another exporter rather than a change to the event/stat engine.

## `.programme` archives

A Programme archive is the portable, versioned representation of recorded match data.

It contains enough information to reproduce the match independently of the local SwiftData store, including the match descriptor, frozen roster information, events, revisions/void state, clock/phase/finalization state, and tracked-category profile.

The archive manifest identifies the format/schema version and generator.

### Compatibility rules

- Preserve stable event/match/player identifiers needed for history reconstruction.
- New optional keys should remain ignorable by older compatible decoders when safe.
- A schema newer than the reader understands must fail clearly rather than being partially misread.
- Each incompatible format change gets an explicit migration/compatibility decision and tests.
- Round-trip tests must preserve tracked/not-tracked state and revision history.

Imported matches must be reattached safely to the destination library/team context rather than accidentally retaining persistence identifiers that only made sense in the origin database.

## MaxPreps

Programme treats MaxPreps as an export destination, not its source of truth.

Until an official supplier specification is available, Programme generates a **MaxPreps Entry Summary** laid out for quick manual transcription using the statistics Programme already derived.

Do not:

- scrape MaxPreps
- invent an undocumented API
- make scoring dependent on MaxPreps availability
- hard-code reverse-engineered behavior as a stable contract

When supplier documentation becomes available, keep the implementation isolated behind the exporter seam and add fixtures/compatibility tests for the official format.

## CSV

CSV output must preserve the semantic distinction between numeric zero and not tracked.

Typical convention:

- `0` = tracked and zero occurred
- blank cell = category was not tracked / value unknown

Document that convention in the exported file/context so downstream users do not interpret blank as zero.

Keep CSV column ordering stable once external users may depend on it. If a format changes incompatibly, version it or provide a migration path.

## PDF/stat sheets

The PDF is presentation of domain-derived data. It should never become a separate source of statistic formulas.

A PDF/export bug should be classified as either:

- wrong domain value (fix/test in ProgrammeCore), or
- correct value represented incorrectly (fix/test in ProgrammeExport).

Use fixture-based export tests for layout-independent content and targeted rendering verification when changing the PDF generator.

## Roster import

Roster import is a convenience boundary, not match truth.

Supported input paths can include CSV/paste and platform-assisted recognition, but ambiguous input should be reviewed before becoming the roster.

Normalize imported data deliberately:

- jersey number
- display/preferred name
- position(s)
- goalkeeper eligibility where represented

Do not silently infer sensitive or unnecessary personal information.

## Transferable and Files

Use Apple's transfer/document APIs so archives and exports naturally participate in Files, AirDrop, drag/drop, ShareLink, Mail, and other system destinations.

Programme's own data model must not depend on any one sharing surface.

## Export testing checklist

When changing export or archive code, cover as appropriate:

- known fixture values
- tracked zero vs not tracked
- own goals / goalkeeper effects
- substitutions and corrected minutes
- archive round trip
- schema-version gating
- import into a different team/library context
- revision/void history
- unknown/deferred attribution
- Unicode player/team names
- CSV escaping for commas, quotes, and line breaks

Do not approve an export change solely because the file opens; verify the represented numbers and semantics.
