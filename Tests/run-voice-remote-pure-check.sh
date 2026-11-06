#!/bin/bash
# «Голос» как утилита без процессов: строгий разбор действий, хвосты загрузки, ответ на мусор. Без микрофона, клавиши, сети и настоящих моделей.
# Дом подменён, настройки в тестовом suite. Проверка с настоящей подписанной утилитой и пикселями — отдельно.
set -euo pipefail
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}"; OUT="${VOICE_REMOTE_DIR:-${T%/}/voice-remote-pure}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
rm -rf "$OUT"; mkdir -p "$OUT/home"
trap 'defaults delete local.utilitumus.test.kit.voice-pure 2>/dev/null || true; rm -f "$HOME/Library/Preferences/local.utilitumus.test.kit.voice-pure.plist"' EXIT
swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name VoiceRemotePure -o "$OUT/check" \
  Tests/VoiceRemotePureCheck.swift Sources/Modules/Voice/*.swift Sources/Kit/*.swift Sources/Kit/Link/*.swift \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox
env HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" KIT_TEST_SUITE=local.utilitumus.test.kit.voice-pure "$OUT/check"
