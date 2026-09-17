# Programme documentation

Use these as the repository's deeper sources of truth. The root README stays intentionally concise.

- [Architecture](ARCHITECTURE.md) — event model, module boundaries, concurrency, determinism and stat derivation
- [Reliability and recovery](RELIABILITY.md) — write-ahead journal, clocks, undo, finalization and tracked-vs-zero
- [Scoring UX](SCORING_UX.md) — live workspace interaction rules and review criteria
- [Imports and exports](EXPORTS.md) — `.programme`, CSV/PDF, roster import and MaxPreps boundary
- [Development](DEVELOPMENT.md) — bootstrap, Make targets, formatting, CI, simulators and capability setup

For contribution rules, see [`../CONTRIBUTING.md`](../CONTRIBUTING.md). Coding agents should begin with [`../AGENTS.md`](../AGENTS.md).
