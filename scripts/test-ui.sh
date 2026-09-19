#!/usr/bin/env bash
set -euo pipefail

# UI-test entry point for local runs (`make test-ui`) and CI.
#
# Behavior controls. Explicit values always win; when neither is set, CI
# defaults apply if PROGRAMME_CI=1 or GITHUB_ACTIONS=true, otherwise the run
# behaves as a plain local invocation.
#
#   PROGRAMME_TEST_DIAGNOSTICS=never|on-failure
#     CI default: never. Simulator sysdiagnose collection can stall a failing
#     run for ~600s after XCTest has already finished; failure evidence still
#     comes from XCTest messages, attached screenshots, and the .xcresult
#     bundle uploaded by CI. Local default: Xcode's own default.
#   PROGRAMME_PARALLEL_TEST_WORKERS=N
#     CI default: 3. XCTest distributes UI tests at the class level across
#     simulator clones. Three is the smallest worker count expected to give a
#     strong speedup on GitHub-hosted macOS runners without overloading their
#     finite CPU/memory; do not raise it without measuring on the real
#     xcode-27 runner. 0 disables parallel testing. Local default: unset, so
#     the scheme's parallelizable flag governs with Xcode's default workers.
#   PROGRAMME_UI_TEST_SCOPE=all|ipad|compact
#     CI default: ipad, which excludes the phone-only CompactScorerUITests
#     class via -skip-testing so the iPad run neither executes nor discovers
#     it. `compact` selects only that class (pair with
#     PROGRAMME_DEVICE_FAMILY=iphone). Local default: all.
#   PROGRAMME_DEVICE_FAMILY=ipad|iphone (default: ipad)
#     Selects which simulator family to run on.
#
# PROGRAMME_SIMULATOR_ID, PROGRAMME_XCRESULT_PATH, and extra arguments
# forwarded to `xcodebuild test` keep their existing meaning.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.sh
source "$ROOT/scripts/versions.sh"
cd "$ROOT"

section() {
    printf '==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

is_ci=false
if [[ "${PROGRAMME_CI:-}" == "1" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
    is_ci=true
fi

diagnostics="${PROGRAMME_TEST_DIAGNOSTICS:-}"
if [[ -z "$diagnostics" && "$is_ci" == true ]]; then
    diagnostics="never"
fi

workers="${PROGRAMME_PARALLEL_TEST_WORKERS:-}"
if [[ -z "$workers" && "$is_ci" == true ]]; then
    # Bounded on purpose: GitHub-hosted runners have finite CPU and memory,
    # and over-parallelizing simulator UI tests makes them slower or flakier.
    workers="3"
fi

scope="${PROGRAMME_UI_TEST_SCOPE:-}"
if [[ -z "$scope" && "$is_ci" == true ]]; then
    scope="ipad"
fi
if [[ -z "$scope" ]]; then
    scope="all"
fi

family="${PROGRAMME_DEVICE_FAMILY:-}"
if [[ -z "$family" ]]; then
    # The compact suite only runs on a phone; every other scope targets iPad.
    if [[ "$scope" == "compact" ]]; then
        family="iphone"
    else
        family="ipad"
    fi
fi

section "Generating Xcode project"
bash "$ROOT/scripts/xcodegen.sh" generate --spec "$ROOT/project.yml" >/dev/null

section "Selecting simulator (family: $family)"
simulator_id="${PROGRAMME_SIMULATOR_ID:-}"
if [[ -z "$simulator_id" ]]; then
    devices_json="$(mktemp)"
    trap 'rm -f "$devices_json"' EXIT
    xcrun simctl list devices available -j > "$devices_json"

    simulator_id="$(python3 - "$devices_json" "$PROGRAMME_DEFAULT_SIMULATOR_NAME" "$family" <<'PY'
import json
import sys

path, preferred, family = sys.argv[1], sys.argv[2], sys.argv[3]
prefix = "iPhone" if family == "iphone" else "iPad"
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

devices = []
for runtime, entries in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in entries:
        # Substring match: stock devices are "iPad Pro …", but custom devices
        # such as "Programme iPad mini" must also be found.
        if device.get("isAvailable") and prefix in device.get("name", ""):
            devices.append(device)

if not devices:
    raise SystemExit(1)

booted = next((d for d in devices if d.get("state") == "Booted"), None)
exact = next((d for d in devices if d.get("name") == preferred), None)
choice = booted or exact or devices[0]
print(choice["udid"])
PY
)" || {
        echo "error: no available $family Simulator found." >&2
        echo "Install an iOS simulator runtime in Xcode Settings > Components." >&2
        exit 1
    }
fi

section "Booting simulator $simulator_id"
xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b

result_args=()
if [[ -n "${PROGRAMME_XCRESULT_PATH:-}" ]]; then
    rm -rf "$PROGRAMME_XCRESULT_PATH"
    result_args=(-resultBundlePath "$PROGRAMME_XCRESULT_PATH")
fi

test_args=()
case "$scope" in
    ipad)
        test_args=(-skip-testing:ProgrammeUITests/CompactScorerUITests)
        ;;
    compact)
        test_args=(-only-testing:ProgrammeUITests/CompactScorerUITests)
        ;;
    all)
        test_args=(-only-testing:ProgrammeUITests)
        ;;
    *)
        echo "error: unknown PROGRAMME_UI_TEST_SCOPE '$scope' (expected all|ipad|compact)." >&2
        exit 2
        ;;
esac

parallel_args=()
if [[ -n "$workers" ]]; then
    if [[ "$workers" == "0" ]]; then
        parallel_args=(-parallel-testing-enabled NO)
    else
        parallel_args=(-parallel-testing-enabled YES -parallel-testing-worker-count "$workers")
    fi
fi

diagnostic_args=()
if [[ -n "$diagnostics" ]]; then
    diagnostic_args=(-collect-test-diagnostics "$diagnostics")
fi

section "Running UI tests (scope: $scope, diagnostics: ${diagnostics:-xcode-default}, workers: ${workers:-xcode-default})"
set -o pipefail
# macOS /bin/bash is 3.2: "${empty[@]}" fails under `set -u`, so suspend nounset here.
set +u
xcodebuild test \
    -project Programme.xcodeproj \
    -scheme Programme \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    "${test_args[@]}" \
    "${parallel_args[@]}" \
    "${diagnostic_args[@]}" \
    "${result_args[@]}" \
    "$@"
set -u
