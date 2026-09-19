#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEAM_ID="57CW34C9J4"
APP_ID="com.gbyo.Programme"
WIDGET_ID="$APP_ID.widgets"
WATCH_ID="$APP_ID.watchkitapp"
THUMBNAIL_ID="$APP_ID.thumbnails"
UI_TEST_ID="$APP_ID.uitests"
INTENT_TEST_ID="$APP_ID.intenttests"
ICLOUD_ID="iCloud.com.gbyo.programme"

fail() {
    printf '✗ Signing audit: %s\n' "$1" >&2
    exit 1
}

require_literal() {
    local file="$1"
    local text="$2"
    grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

require_literal project.yml "DEVELOPMENT_TEAM: $TEAM_ID"
require_literal project.yml "PRODUCT_BUNDLE_IDENTIFIER: $APP_ID"
require_literal project.yml "PRODUCT_BUNDLE_IDENTIFIER: $WIDGET_ID"
require_literal project.yml "PRODUCT_BUNDLE_IDENTIFIER: $WATCH_ID"
require_literal project.yml "PRODUCT_BUNDLE_IDENTIFIER: $THUMBNAIL_ID"
require_literal project.yml "PRODUCT_BUNDLE_IDENTIFIER: $UI_TEST_ID"
require_literal project.yml "PRODUCT_BUNDLE_IDENTIFIER: $INTENT_TEST_ID"
require_literal project.yml "$ICLOUD_ID"

companion="$(/usr/libexec/PlistBuddy -c 'Print :WKCompanionAppBundleIdentifier' App/ProgrammeWatch/Info.plist)"
[[ "$companion" == "$APP_ID" ]] || fail "Watch companion is $companion, expected $APP_ID"

icloud_service="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services:0' App/Programme/Programme.entitlements)"
[[ "$icloud_service" == "CloudKit" ]] || fail "generated entitlement is missing CloudKit"

icloud_container="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' App/Programme/Programme.entitlements)"
[[ "$icloud_container" == "$ICLOUD_ID" ]] || fail "generated entitlement uses $icloud_container, expected $ICLOUD_ID"

if [[ -d Programme.xcodeproj ]]; then
    settings="$(xcodebuild -project Programme.xcodeproj -scheme Programme -showBuildSettings -destination 'generic/platform=iOS Simulator' 2>/dev/null)"
    grep -Fq "DEVELOPMENT_TEAM = $TEAM_ID" <<< "$settings" || fail "generated project lost DEVELOPMENT_TEAM"
    for identifier in "$APP_ID" "$WIDGET_ID" "$WATCH_ID" "$THUMBNAIL_ID"; do
        grep -Fq "PRODUCT_BUNDLE_IDENTIFIER = $identifier" <<< "$settings" || fail "generated project lost bundle ID $identifier"
    done
    grep -Fq "CODE_SIGN_ENTITLEMENTS = App/Programme/Programme.entitlements" <<< "$settings" || fail "generated project lost Programme entitlements path"
fi

printf '✓ Signing configuration is reproducible.\n'
