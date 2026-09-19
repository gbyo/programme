#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fast=false
if [[ "${1:-}" == "--fast" ]]; then
    fast=true
elif [[ -n "${1:-}" ]]; then
    echo "usage: scripts/verify.sh [--fast]" >&2
    exit 2
fi

printf '==> Environment\n'
bash "$ROOT/scripts/doctor.sh"

printf '\n==> Formatting (changed Swift files)\n'
bash "$ROOT/scripts/format.sh" --check-changed

printf '\n==> Package tests\n'
swift test --package-path Packages/ProgrammeKit

printf '\n==> Generate project\n'
bash "$ROOT/scripts/xcodegen.sh" generate --spec "$ROOT/project.yml"

printf '\n==> Signing configuration\n'
bash "$ROOT/scripts/signing-audit.sh"

printf '\n==> App + widget build\n'
xcodebuild build \
    -project Programme.xcodeproj \
    -scheme Programme \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

if [[ "$fast" == false ]]; then
    printf '\n==> UI tests\n'
    bash "$ROOT/scripts/test-ui.sh"
else
    printf '\nSkipping UI tests (--fast).\n'
fi

printf '\n✓ Programme verification passed.\n'
