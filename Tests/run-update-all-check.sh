#!/bin/bash
# «Обновить всё»: настоящие установщик, zip и codesign на архивах этого стенда, подставные launchctl и связь с утилитой.
# Сбой посередине, занятая утилита, двойной запуск, столкновение со Стором и переходом, не установленный модуль, снимки.
# /Applications, настоящие утилиты и их настройки не трогаются: всё в папке стенда, окна за экраном.
# Папка: UPDATE_ALL_CHECK_DIR, иначе $TMPDIR/update-all-check. PNG в png/ (и в UPDATE_ALL_PNG_DIR, если задана).
# Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${UPDATE_ALL_CHECK_DIR:-${TMPDIR:-/tmp}/update-all-check}"
BIN="update-all-stand"
SUITE="local.utilitumus.test.kit.updateall"
SIGN_NAME="Utilitumus Signing"
F="$OUT/fixtures"
EPOCH="$(sed -n 's/.*static let testPeerEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
EPOCH_KEY="$(sed -n 's/.*static let securityEpochKey = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -n "$EPOCH" ] && [ -n "$EPOCH_KEY" ] || { echo "ПРОВАЛ: нет метки выпуска стенда"; exit 1; }

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache update-all "$TARGET" KIT_TEST_DEFAULTS)"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work/Apps" "$F"

scripts/unlock-signing.sh
if ! security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  echo "ПРОВАЛ: нет сертификата «$SIGN_NAME»"
  exit 1
fi

echo 'int main(void) { return 0; }' | clang -x c -target "$TARGET" -o "$F/exe" -

# make <id> <Имя> <версия> <папка>: подписанный бандл утилиты, как у выпуска.
make_app() {
  local app="$4/$2.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$F/exe" "$app/Contents/MacOS/$2"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    echo "<key>CFBundleIdentifier</key><string>local.utilitumus.app.$1</string>"
    echo "<key>CFBundleExecutable</key><string>$2</string>"
    echo "<key>CFBundleShortVersionString</key><string>$3</string>"
    echo "<key>$EPOCH_KEY</key><string>$EPOCH</string>"
    echo '</dict></plist>'
  } > "$app/Contents/Info.plist"
  codesign --force --options runtime --sign "$SIGN_NAME" --identifier "local.utilitumus.app.$1" "$app" 2>/dev/null
}

# Стоит 1.0.0, в каталоге 2.0.0. `load` тоже стоит, но новой версии нужен центр новее. `stash` не стоит.
for pair in sound:Sound load:Load mixer:Mixer mouse:Mouse clipboard:Clipboard keyboard:Keyboard awake:Awake bots:Bots stash:Stash; do
  id="${pair%%:*}"; name="${pair##*:}"
  mkdir -p "$F/$id"
  make_app "$id" "$name" 2.0.0 "$F/$id"
  ditto -c -k --keepParent "$F/$id/$name.app" "$F/$id-2.0.0.zip"
  if [ "$id" != stash ]; then make_app "$id" "$name" 1.0.0 "$OUT/work/Apps"; fi
done

sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/UpdateAllCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift UtilitumusApp.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
# UtilitumusApp.swift у стенда свой, без @main.
HUB_LIST="$(scripts/hub-sources.sh)"
FILES=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift")
while IFS= read -r f; do case "$f" in */UtilitumusApp.swift) ;; *) FILES+=("$f") ;; esac; done <<<"$HUB_LIST"
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -Onone -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name UpdateAllStand -o "$OUT/$BIN" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$SUITE.plist" "$HOME/Library/Preferences/$BIN.plist"' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$F" "$OUT/work" "$OUT/png"
if [ -n "${UPDATE_ALL_PNG_DIR:-}" ]; then mkdir -p "$UPDATE_ALL_PNG_DIR"; cp "$OUT"/png/*.png "$UPDATE_ALL_PNG_DIR/"; fi
