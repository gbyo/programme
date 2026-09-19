#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.sh
source "$ROOT/scripts/versions.sh"
cd "$ROOT"

bash "$ROOT/scripts/xcodegen.sh" generate --spec "$ROOT/project.yml" >/dev/null

simulator_id="${PROGRAMME_SIMULATOR_ID:-}"
if [[ -z "$simulator_id" ]]; then
    devices_json="$(mktemp)"
    trap 'rm -f "$devices_json"' EXIT
    xcrun simctl list devices available -j > "$devices_json"

    simulator_id="$(python3 - "$devices_json" "$PROGRAMME_DEFAULT_SIMULATOR_NAME" <<'PY'
import json
import sys

path, preferred = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

devices = []
for runtime, entries in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in entries:
        if device.get("isAvailable") and device.get("name", "").startswith("iPad"):
            devices.append(device)

if not devices:
    raise SystemExit(1)

booted = next((d for d in devices if d.get("state") == "Booted"), None)
exact = next((d for d in devices if d.get("name") == preferred), None)
choice = booted or exact or devices[0]
print(choice["udid"])
PY
)" || {
        echo "error: no available iPad Simulator found." >&2
        echo "Install an iOS simulator runtime in Xcode Settings > Components." >&2
        exit 1
    }
fi

xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b

result_args=()
if [[ -n "${PROGRAMME_XCRESULT_PATH:-}" ]]; then
    rm -rf "$PROGRAMME_XCRESULT_PATH"
    result_args=(-resultBundlePath "$PROGRAMME_XCRESULT_PATH")
fi

set -o pipefail
# macOS /bin/bash is 3.2: "${empty[@]}" fails under `set -u`, so suspend nounset here.
set +u
xcodebuild test \
    -project Programme.xcodeproj \
    -scheme Programme \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    -only-testing:ProgrammeUITests \
    "${result_args[@]}" \
    "$@"
set -u
