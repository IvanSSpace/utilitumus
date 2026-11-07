#!/bin/bash
# Состояние, действия и экран «Вентиляторы»: настоящие контроллеры и экран, поддельные SMC, служба и установщик.
# В сборке нет ни SMC.swift, ни FanHelperClient.swift, ни FanHelperInstaller.swift: ниже это проверяется и по nm.
# База пикселей: старый FansView из коммита FANS_BASE_REF (по умолчанию тот, что был до модели) с той же подделкой.
# Папка стенда: FANS_WIRE_DIR, иначе $TMPDIR/fans-wire-check. FANS_SKIP_BASE=1: базу не пересобирать, если она уже снята.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${FANS_WIRE_DIR:-${TMPDIR:-/tmp}/fans-wire-check}"
BASE_REF="${FANS_BASE_REF:-509cdb3}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
NAME=fans-wire-check
# Свой suite вместо общего local.utilitumus.test.kit: FanConfigs и настройки игр пишет ещё run-update-order-check.
export KIT_TEST_SUITE="local.utilitumus.test.kit.fans-wire"

mkdir -p "$OUT/src" "$OUT/home" "$OUT/base" "$OUT/new"
OUT="$(cd "$OUT" && pwd -P)"
trap 'for d in "$NAME" "$KIT_TEST_SUITE"; do defaults delete "$d" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$d.plist"; done' EXIT

# Инкрементальная сборка: у базы и у нового экрана свой кэш с копиями подставных файлов. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
. Tests/lib/incremental-sync.sh
cp Tests/FansWireCheck.swift "$OUT/src/main.swift"
KIT="Sources/Kit/Components.swift Sources/Kit/KitDefaults.swift Sources/Kit/Module.swift Sources/Kit/ModuleCategory.swift Sources/Kit/ModuleControls.swift Sources/Kit/ModuleInfo.swift Sources/Kit/PageActive.swift Sources/Kit/PrivateLog.swift Sources/Kit/KitIdentity.swift Sources/Kit/Link/LinkProtocol.swift Sources/Kit/KitSigning.swift Sources/Kit/Link/LinkWire.swift Sources/Kit/ScrollThumb.swift Sources/Kit/SegmentedControl.swift Sources/Kit/Theme.swift Sources/App/Design/Pages.swift"
FANS="Sources/Shared/FanLink.swift Sources/Modules/Fans/FanController.swift Sources/Modules/Fans/FanControllerWire.swift Sources/Modules/Fans/BuiltInFansModel.swift Sources/Modules/Fans/FanGate.swift Sources/Modules/Fans/GameModeController.swift Sources/Modules/Fans/UI/FanTypes.swift Sources/Modules/Fans/UI/GameDetection.swift Sources/Modules/Fans/UI/FansModel.swift Sources/Modules/Fans/UI/FansWire.swift"
FLAGS=(-target "$TARGET" -D KIT_TEST_DEFAULTS -framework AppKit -framework SwiftUI)

if [ -z "${FANS_SKIP_BASE:-}" ] || [ ! -f "$OUT/base/normal.rgba" ]; then
  /usr/bin/git show "$BASE_REF:Sources/Modules/Fans/FansView.swift" > "$OUT/src/OldFansView.swift"
  mkdir -p "$OUT/bin-base"
  rm -f "$OUT/bin-base/$NAME"
  CACHE="$(incremental_cache fans-wire-base KIT_TEST_DEFAULTS FANS_BASELINE)"
  incremental_sync "$OUT/src" "$CACHE/src"
  # shellcheck disable=SC2206
  FILES=("$CACHE/src/main.swift" "$CACHE/src/OldFansView.swift" $KIT $FANS)
  incremental_flags "$CACHE" "${FILES[@]}"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} "${FLAGS[@]}" -D FANS_BASELINE -module-name FansBaseline -o "$OUT/bin-base/$NAME" "${FILES[@]}"
  rm -f "$OUT"/base/*
  CFFIXED_USER_HOME="$OUT/home" "$OUT/bin-base/$NAME" pixels "$OUT/base" "$OUT/home"
fi

mkdir -p "$OUT/bin-new"
rm -f "$OUT/bin-new/$NAME"
CACHE="$(incremental_cache fans-wire KIT_TEST_DEFAULTS)"
incremental_sync "$OUT/src" "$CACHE/src"
# shellcheck disable=SC2206
FILES=("$CACHE/src/main.swift" Sources/Modules/Fans/UI/FansView.swift Sources/Modules/Fans/BuiltInFansView.swift $KIT $FANS)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} "${FLAGS[@]}" -module-name FansWireCheck -o "$OUT/bin-new/$NAME" "${FILES[@]}"

if nm -u "$OUT/bin-new/$NAME" | grep -E 'IOConnect|IOService|NSXPCConnection|NSAppleScript'; then
  echo "ПРОВАЛ: стенд мог бы дойти до настоящего SMC, службы или AppleScript"
  exit 1
fi
echo "ok   nm: нет вызовов SMC, XPC и AppleScript"

CFFIXED_USER_HOME="$OUT/home" "$OUT/bin-new/$NAME" check "$OUT/base" "$OUT/new" "$OUT/home"
