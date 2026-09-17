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

lint_files() {
    local -a files=("$@")
    if (( ${#files[@]} == 0 )); then
        echo "No Swift files need a formatting check."
        return 0
    fi

    printf 'Checking Swift formatting (%d file%s)…\n' \
        "${#files[@]}" "$([[ ${#files[@]} -eq 1 ]] && echo '' || echo 's')"
    xcrun swift-format lint --configuration "$ROOT/.swift-format" --strict "${files[@]}"
}

if [[ "$mode" == "format" ]]; then
    echo "Formatting all tracked Swift sources…"
    mapfile -d '' files < <(git ls-files -z '*.swift')
    if (( ${#files[@]} > 0 )); then
        xcrun swift-format format --configuration "$ROOT/.swift-format" --in-place "${files[@]}"
    fi
    exit 0
fi

if [[ "$mode" == "check-all" ]]; then
    mapfile -d '' files < <(git ls-files -z '*.swift')
    lint_files "${files[@]}"
    exit 0
fi

# The repository adopted swift-format after its initial implementation. CI therefore
# ratchets formatting forward: every Swift file touched by a change must conform,
# without hiding functional work inside a one-time whole-tree formatting rewrite.
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

{
    git diff --name-only --diff-filter=ACMR "$base"...HEAD -- '*.swift'
    git diff --name-only --diff-filter=ACMR -- '*.swift'
    git diff --cached --name-only --diff-filter=ACMR -- '*.swift'
} | sort -u | while IFS= read -r path; do
    [[ -n "$path" && -f "$path" ]] && printf '%s\0' "$path"
done > "${TMPDIR:-/tmp}/programme-format-files-$$"

mapfile -d '' files < "${TMPDIR:-/tmp}/programme-format-files-$$"
rm -f "${TMPDIR:-/tmp}/programme-format-files-$$"
lint_files "${files[@]}"
