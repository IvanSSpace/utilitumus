#!/bin/bash
# «Студия» от начала до конца: настоящие запуск процесса и сеть до 127.0.0.1, родной экран на SwiftUI, вместо Студии
# Tests/fake-studio.py во временной папке на случайном порту. Опрос только при открытом экране, снимок утилит и значки, дело
# выбранной, действия с телами страницы, отказы сервера строками, «В браузере» по одноразовому коду, выключение гасит свой сервер
# и не трогает чужой. Снимки экрана: <папка вывода>/png/*.png.
# Настоящая Студия, порт 47870 и её .cache не трогаются. Настройки только в своём тестовом suite.
#   Tests/run-studio-screen-check.sh [папка-вывода]    по умолчанию $TMPDIR/studio-screen-check-out
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"
OUT="${1:-${T%/}/studio-screen-check-out}"
BIN="${STUDIO_SCREEN_DIR:-${T%/}/studio-screen-check-bin}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.studio-screen"

# Рабочая папка: только своя временная. rm -rf разрешён, когда путь доказанно из mktemp под $TMPDIR.
WORK="$(mktemp -d "${T%/}/studio-screen-check.XXXXXX")"
case "$WORK" in "${T%/}"/studio-screen-check.*) ;; *) echo "ПРОВАЛ: странная рабочая папка $WORK"; exit 1 ;; esac
cleanup() {
  # Подставная Студия, если проверка оборвалась: только процессы из этой папки.
  [ ! -f "$WORK/studio-folder/.cache/server.json" ] || {
    PID="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$WORK/studio-folder/.cache/server.json" 2>/dev/null || true)"
    [ -z "$PID" ] || kill "$PID" 2>/dev/null || true
  }
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
  rm -rf "$WORK"
}
trap cleanup EXIT

# Случайный свободный порт: просим систему, не берём 47870.
PORT="$(/usr/bin/python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
[ "$PORT" != 47870 ] || { echo "ПРОВАЛ: выпал порт настоящей Студии"; exit 1; }

mkdir -p "$WORK/studio-folder"
chmod 700 "$WORK/studio-folder"
cp Tests/fake-studio.py "$WORK/studio-folder/fake_studio.py"
cat > "$WORK/studio-folder/studio" <<'STUDIO'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
exec /usr/bin/python3 -I fake_studio.py
STUDIO
chmod 755 "$WORK/studio-folder/studio"
chmod 644 "$WORK/studio-folder/fake_studio.py"
# Подставной сервер берёт лог из окружения: утилита окружение не передаёт, поэтому путь лежит рядом с ним.
sed -i '' "s#os.environ\\[\"FAKE_STUDIO_LOG\"\\]#os.environ.get(\"FAKE_STUDIO_LOG\", \"$WORK/requests.log\")#" "$WORK/studio-folder/fake_studio.py"
grep -q "$WORK/requests.log" "$WORK/studio-folder/fake_studio.py" || { echo "ПРОВАЛ: подставной сервер не получил путь к логу"; exit 1; }

mkdir -p "$BIN/src" "$OUT/png"
cp Tests/StudioScreenCheck.swift "$BIN/src/StudioScreenCheck.swift"
swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$BIN/check" "$BIN/src/StudioScreenCheck.swift" \
  Sources/Modules/Studio/*.swift Sources/Modules/Studio/UI/*.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort) \
  -framework SwiftUI -framework AppKit
"$BIN/check" "$WORK" "$OUT/png" "$PORT"
echo "Снимки: $OUT/png"
