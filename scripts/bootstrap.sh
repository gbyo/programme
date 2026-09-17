#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: Programme app development requires macOS." >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew is required. Install it from https://brew.sh, then rerun 'make bootstrap'." >&2
    exit 1
fi

printf 'Installing developer tools from Brewfile…\n'
brew bundle --file "$ROOT/Brewfile"

printf '\nPreparing pinned XcodeGen…\n'
mint bootstrap --mintfile "$ROOT/Mintfile"

printf '\nChecking the environment…\n'
bash "$ROOT/scripts/doctor.sh"

printf '\nGenerating Programme.xcodeproj…\n'
bash "$ROOT/scripts/xcodegen.sh" generate --spec "$ROOT/project.yml"

printf '\nProgramme is ready. Run `make open` or `make verify-fast`.\n'
