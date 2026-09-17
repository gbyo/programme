#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! xcrun --find swift-format >/dev/null 2>&1; then
    echo "error: swift-format is not available from the selected Xcode toolchain." >&2
    echo "Run 'make doctor' to diagnose the active Xcode installation." >&2
    exit 1
fi

mode="format"
if [[ "${1:-}" == "--check" ]]; then
    mode="check"
elif [[ -n "${1:-}" ]]; then
    echo "usage: scripts/format.sh [--check]" >&2
    exit 2
fi

if [[ "$mode" == "check" ]]; then
    echo "Checking Swift formatting…"
    git ls-files -z '*.swift' \
        | xargs -0 xcrun swift-format lint --configuration "$ROOT/.swift-format" --strict
else
    echo "Formatting Swift sources…"
    git ls-files -z '*.swift' \
        | xargs -0 xcrun swift-format format --configuration "$ROOT/.swift-format" --in-place
fi
