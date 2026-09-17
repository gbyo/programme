# Development scripts

These scripts back the public `make` targets. Prefer the Makefile for normal use so developers and CI share the same entry points.

- `bootstrap.sh` — first-checkout setup
- `doctor.sh` — local environment diagnostics
- `xcodegen.sh` — pinned XcodeGen wrapper
- `format.sh` — apply/check Xcode-provided swift-format
- `test-ui.sh` — select an iPad simulator and run UI tests
- `verify.sh` — compose the local verification gate
- `versions.sh` — shared tool-version constants

Scripts are invoked with `bash` deliberately, so their executable file mode is not required for a checkout to work.
