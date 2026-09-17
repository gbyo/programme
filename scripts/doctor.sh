#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.sh
source "$ROOT/scripts/versions.sh"

failures=0
warnings=0

ok() { printf '✓ %s\n' "$1"; }
warn() { printf '⚠ %s\n' "$1"; warnings=$((warnings + 1)); }
fail() { printf '✗ %s\n' "$1" >&2; failures=$((failures + 1)); }

printf 'Programme development environment\n\n'

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "Programme app development requires macOS."
else
    ok "macOS"
fi

if ! command -v xcode-select >/dev/null 2>&1; then
    fail "xcode-select is unavailable. Install Xcode."
else
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -z "$developer_dir" ]]; then
        fail "No active Xcode developer directory."
    elif [[ "$developer_dir" == *CommandLineTools* ]]; then
        fail "Command Line Tools are selected instead of Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    elif [[ ! -d "$developer_dir" ]]; then
        fail "Selected developer directory does not exist: $developer_dir"
    else
        ok "Xcode selected: $developer_dir"
    fi
fi

if command -v xcodebuild >/dev/null 2>&1; then
    xcode_version="$(xcodebuild -version 2>/dev/null | head -n 1 | awk '{print $2}')"
    xcode_major="${xcode_version%%.*}"
    if [[ "$xcode_major" =~ ^[0-9]+$ ]] && (( xcode_major >= PROGRAMME_REQUIRED_XCODE_MAJOR )); then
        ok "Xcode $xcode_version"
    else
        fail "Xcode ${PROGRAMME_REQUIRED_XCODE_MAJOR}+ is required; selected version is ${xcode_version:-unknown}."
    fi
else
    fail "xcodebuild is unavailable."
fi

if command -v swift >/dev/null 2>&1; then
    ok "$(swift --version 2>/dev/null | head -n 1)"
else
    fail "Swift is unavailable from the selected toolchain."
fi

if xcrun --find swift-format >/dev/null 2>&1; then
    formatter_version="$(xcrun swift-format --version 2>/dev/null | head -n 1 || true)"
    ok "swift-format${formatter_version:+: $formatter_version}"
else
    fail "swift-format is not available in the selected Xcode toolchain."
fi

if command -v brew >/dev/null 2>&1; then
    ok "Homebrew"
else
    fail "Homebrew is required for bootstrap. Install it from brew.sh, then run 'make bootstrap'."
fi

if command -v mint >/dev/null 2>&1; then
    ok "Mint $(mint version 2>/dev/null | head -n 1 || true)"
    xcodegen_output="$(bash "$ROOT/scripts/xcodegen.sh" --version 2>/dev/null || true)"
    if [[ "$xcodegen_output" == *"${PROGRAMME_XCODEGEN_VERSION}"* ]]; then
        ok "XcodeGen ${PROGRAMME_XCODEGEN_VERSION} (pinned)"
    else
        fail "Pinned XcodeGen ${PROGRAMME_XCODEGEN_VERSION} could not be run. Try 'make bootstrap'."
    fi
else
    fail "Mint is not installed. Run 'make bootstrap'."
fi

if command -v xcrun >/dev/null 2>&1 && xcrun simctl list devices available 2>/dev/null | grep -q 'iPad'; then
    ok "At least one iPad Simulator is available"
else
    fail "No available iPad Simulator was found. Install an iOS simulator runtime in Xcode Settings > Components."
fi

if [[ -f "$ROOT/project.yml" ]]; then
    if command -v mint >/dev/null 2>&1 && bash "$ROOT/scripts/xcodegen.sh" dump --spec "$ROOT/project.yml" >/dev/null 2>&1; then
        ok "project.yml parses successfully"
    else
        fail "project.yml could not be parsed by the pinned XcodeGen."
    fi
else
    fail "project.yml is missing."
fi

if [[ -d "$ROOT/Programme.xcodeproj" ]]; then
    ok "Generated Programme.xcodeproj is present"
else
    warn "Programme.xcodeproj has not been generated yet; run 'make generate'."
fi

printf '\n'
if (( failures > 0 )); then
    printf '%d problem(s), %d warning(s).\n' "$failures" "$warnings" >&2
    exit 1
fi

printf 'Environment looks good%s.\n' "$([[ $warnings -gt 0 ]] && printf ' (%d warning(s))' "$warnings" || true)"
