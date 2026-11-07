#!/bin/bash
# `AwakeController.start()` читает настройки заново. Сборка со швом KIT_TEST_DEFAULTS, настоящие настройки не трогаются.
# Не запускать вместе с run-awake-app-check.sh и run-awake-remote-check.sh: у них один suite.
# Папка стенда: AWAKE_SETTINGS_DIR, иначе $TMPDIR/awake-settings-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${AWAKE_SETTINGS_DIR:-${TMPDIR:-/tmp}/awake-settings-check}"
SUITE="local.utilitumus.test.kit"

cleanup() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
trap cleanup EXIT

mkdir -p "$OUT/src"
cp Tests/AwakeSettingsCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/main.swift" \
  Sources/Modules/Awake/AwakeController.swift Sources/Modules/Awake/UI/AwakeModel.swift Sources/Modules/Awake/UI/AwakeTypes.swift Sources/Kit/KitDefaults.swift \
  -framework IOKit
"$OUT/check"
