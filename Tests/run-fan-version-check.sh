#!/bin/bash
# Направление версии помощника вентиляторов: таблица версий, два клиента на разных версиях, и скрипт установки
# на подставных путях. Настоящих установок нет: ни AppleScript, ни пароля, ни launchctl, ни chown, ни SMC, пути в стенде.
# Папка стенда (удаляется): FAN_VERSION_CHECK_DIR, иначе $TMPDIR/fan-version-check. Нужен сертификат «Utilitumus Signing».
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${FAN_VERSION_CHECK_DIR:-${TMPDIR:-/tmp}/fan-version-check}"
SIGN_NAME="Utilitumus Signing"

# Подписанные нашим сертификатом бинарники с боевым identifier не оставляем.
trap 'rm -rf "$OUT"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; fails=$((fails + 1)); }

scripts/unlock-signing.sh
security find-identity -p codesigning | grep -q "\"$SIGN_NAME\"" || { echo "ПРОВАЛ: нет сертификата «${SIGN_NAME}»"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/src"
cp Tests/FanVersionCheck.swift "$OUT/src/main.swift"
# Со швом FAN_TEST_FAKE_SMC: метка службы тестовая, настоящая не ищется, даже если проверка ошибётся.
swiftc -target "$TARGET" -D FAN_TEST_FAKE_SMC -module-name FanVersionCheck -o "$OUT/check" "$OUT/src/main.swift" \
  Sources/Shared/FanLink.swift Sources/Kit/KitSigning.swift Sources/Kit/KitDefaults.swift Sources/Kit/Link/LinkProtocol.swift \
  Sources/Modules/Fans/FanHelperClient.swift Sources/Modules/Fans/FanHelperInstaller.swift Sources/Modules/Fans/LegacyFanHelper.swift Sources/Modules/Fans/UI/FanTypes.swift \
  -framework AppKit
"$OUT/check" logic

echo "== скрипт установки: понижения нет"
SB="$OUT/sb"
# stub <имя> <версия> <подпись> <identifier>: «помощник», отвечает на version и оставляет след запуска.
stub() {
  cat > "$OUT/src/stub.c" <<EOF
#include <stdio.h>
int main(void) {
    FILE *f = fopen("$SB.ran", "a");
    if (f) { fprintf(f, "$1\n"); fclose(f); }
    puts("$2");
    return 0;
}
EOF
  clang -target "$TARGET" -o "$OUT/$1" "$OUT/src/stub.c"
  codesign --force --options runtime --sign "$3" --identifier "$4" "$OUT/$1" 2>/dev/null
}
stub h3 3 "$SIGN_NAME" local.utilitumus.fan
stub h4 4 "$SIGN_NAME" local.utilitumus.fan
stub h5 5 "$SIGN_NAME" local.utilitumus.fan
stub h40 40 "$SIGN_NAME" local.utilitumus.fan
stub garbage abc "$SIGN_NAME" local.utilitumus.fan
stub rogue-adhoc 99 - local.utilitumus.fan
stub rogue-id 99 "$SIGN_NAME" local.utilitumus.fan.evil

reset() { # что уже стоит, пусто — ничего
  rm -rf "$SB" "$SB.ran"
  mkdir -p "$SB/tools" "$SB/daemons"
  for name in chown launchctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$name" "$SB" > "$SB/$name"
    chmod +x "$SB/$name"
  done
  : > "$SB/calls.log"
  [ -z "$1" ] || cp "$OUT/$1" "$SB/tools/local.utilitumus.fan"
  : > "$SB.ran"
}
run_script() { # источник версия-клиента
  local text
  text="$("$OUT/check" print-install "$OUT/$1" "$2" | sed \
    -e "s#/Library/PrivilegedHelperTools#$SB/tools#g" -e "s#/Library/LaunchDaemons#$SB/daemons#g" \
    -e "s#/bin/launchctl#$SB/launchctl#g" -e "s#/usr/sbin/chown#$SB/chown#g")"
  case "$text" in *"/Library/"*|*"/bin/launchctl"*|*"/usr/sbin/chown"*) echo "в скрипте остался настоящий путь"; exit 1 ;; esac
  /bin/sh -c "$text" >/dev/null 2>"$OUT/script.err"
}
installed_is() { cmp -s "$OUT/$1" "$SB/tools/local.utilitumus.fan"; }

downgrade() { # есть, ставим, клиент, описание
  reset "$1"
  if run_script "$2" "$3"; then
    bad "$4: установка прошла"
  elif ! grep -q 'более новая' "$OUT/script.err"; then
    bad "$4: нет причины отказа: $(cat "$OUT/script.err")"
  elif ! installed_is "$1" || [ -e "$SB/daemons/local.utilitumus.fan.plist" ] || grep -q launchctl "$SB/calls.log"; then
    bad "$4: служба тронута"
  elif [ -n "$(find "$SB/tools" -name '.install.*')" ]; then
    bad "$4: остался временный каталог"
  else
    ok "$4: отказ, файлы не тронуты, launchctl не вызван"
  fi
}
upgrade() { # есть, ставим, клиент, описание
  reset "$1"
  if ! run_script "$2" "$3"; then
    bad "$4: установка не прошла: $(cat "$OUT/script.err")"
  elif ! installed_is "$2" || ! grep -q 'launchctl bootstrap system' "$SB/calls.log"; then
    bad "$4: служба не встала"
  elif [ -n "$(find "$SB/tools" -name '.install.*')" ]; then
    bad "$4: остался временный каталог"
  else
    ok "$4: встала"
  fi
}
downgrade h5 h4 4 "стоит 5, клиент 4"
downgrade h40 h5 5 "стоит 40, клиент 5: сравнение числами, а не строками"
upgrade "" h4 4 "ничего не стоит, клиент 4"
upgrade h3 h4 4 "стоит 3, клиент 4"
upgrade h4 h5 5 "стоит 4, клиент 5"
upgrade h4 h4 4 "стоит та же версия: так чинятся права файлов"
upgrade garbage h4 4 "стоит непонятная версия"

# Служба на месте, но подпись не наша: root её не запускает, и своими 99 она установку не остановит.
for rogue in rogue-adhoc rogue-id; do
  reset "$rogue"
  if ! run_script h4 4; then
    bad "$rogue: установка не прошла: $(cat "$OUT/script.err")"
  elif grep -q "$rogue" "$SB.ran"; then
    bad "$rogue: непроверенный файл запущен из скрипта root"
  elif ! installed_is h4; then
    bad "$rogue: служба не встала"
  else
    ok "$rogue: чужой файл не запущен, служба заменена"
  fi
done

[ "$fails" -eq 0 ] || { echo "Провалов: $fails"; exit 1; }
echo "Направление версии: OK"
