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
base=""
case "${1:-}" in
    "")
        mode="format"
        ;;
    --check)
        mode="check-all"
        ;;
    --check-changed)
        mode="check-changed"
        base="${2:-}"
        ;;
    *)
        echo "usage: scripts/format.sh [--check | --check-changed [base-ref]]" >&2
        exit 2
        ;;
esac

lint_nul_list() {
    local list="$1"
    if [[ ! -s "$list" ]]; then
        echo "No Swift files need a formatting check."
        return 0
    fi

    echo "Checking Swift formatting…"
    xargs -0 xcrun swift-format lint --configuration "$ROOT/.swift-format" --strict < "$list"
}

if [[ "$mode" == "format" ]]; then
    echo "Formatting all tracked Swift sources…"
    git ls-files -z '*.swift' \
        | xargs -0 xcrun swift-format format --configuration "$ROOT/.swift-format" --in-place
    exit 0
fi

if [[ "$mode" == "check-all" ]]; then
    list="$(mktemp "${TMPDIR:-/tmp}/programme-format.XXXXXX")"
    trap 'rm -f "$list"' EXIT
    git ls-files -z '*.swift' > "$list"
    lint_nul_list "$list"
    exit 0
fi

# Programme adopted swift-format after its initial implementation. CI ratchets
# formatting forward: every Swift file touched by a change must conform, without
# hiding functional work inside a one-time whole-tree formatting rewrite.
if [[ -z "$base" ]]; then
    if git rev-parse --verify --quiet origin/main >/dev/null; then
        base="$(git merge-base origin/main HEAD)"
    elif git rev-parse --verify --quiet HEAD^ >/dev/null; then
        base="HEAD^"
    else
        base="HEAD"
    fi
fi

if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "error: formatting base '$base' is not available locally." >&2
    echo "Fetch the base branch or pass a valid base ref." >&2
    exit 2
fi

list="$(mktemp "${TMPDIR:-/tmp}/programme-format.XXXXXX")"
trap 'rm -f "$list"' EXIT

{
    git diff --name-only --diff-filter=ACMR "$base"...HEAD -- '*.swift'
    git diff --name-only --diff-filter=ACMR -- '*.swift'
    git diff --cached --name-only --diff-filter=ACMR -- '*.swift'
} | sort -u | while IFS= read -r path; do
    [[ -n "$path" && -f "$path" ]] && printf '%s\0' "$path"
done > "$list"

lint_nul_list "$list"
