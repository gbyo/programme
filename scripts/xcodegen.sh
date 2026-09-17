#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.sh
source "$ROOT/scripts/versions.sh"

if ! command -v mint >/dev/null 2>&1; then
    echo "error: Mint is not installed. Run 'make bootstrap' first." >&2
    exit 1
fi

exec mint run "yonaskolb/XcodeGen@${PROGRAMME_XCODEGEN_VERSION}" xcodegen "$@"
