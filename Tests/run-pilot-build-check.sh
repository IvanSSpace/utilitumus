#!/bin/bash
# Сборка пилота и то, что обычная сборка от неё не зависит. /Applications только читается, ничего не запускается.
# Папка: PILOT_CHECK_DIR, иначе $TMPDIR/pilot-build-check. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${PILOT_CHECK_DIR:-${TMPDIR:-/tmp}/pilot-build-check}"
PILOT="$OUT/pilot"
RAW="$(grep -oE 'https://raw[^"]+catalog\.json' Sources/Kit/SatelliteCatalog.swift)"

fails=0
pass() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1: «${2}», ждали «${3}»"; fi; }
# has/lacks: вывод целиком в переменной, `strings | grep -q` при pipefail дал бы ложный ответ от SIGPIPE.
has() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else bad "$1: нет «${3}»"; fi; }
lacks() { if [[ "$2" == *"$3"* ]]; then bad "$1: есть «${3}»"; else pass "$1"; fi; }
# Только чтение: время изменения настоящих приложений.
apps_state() { stat -f '%N %m' /Applications/Utilitumus.app /Applications/Utilitumus 2>/dev/null || true; }

echo "== подмена только при компиляции"
CATALOG_SOURCE="$(cat Sources/Kit/SatelliteCatalog.swift)"
for word in ProcessInfo CommandLine getenv UserDefaults Kit.defaults environment; do
  lacks "SatelliteCatalog.swift не читает $word" "$CATALOG_SOURCE" "$word"
done
# Второе место сделано нарочно: в пилоте автомиграция выключена (ModuleMigration.swift), ровно одним `#if`.
FLAG_USERS="$(grep -rl 'KIT_PILOT_CATALOG\|KitPilotCatalog' Sources | LC_ALL=C sort)"
same "флаг только в SatelliteCatalog.swift и ModuleMigration.swift" "$FLAG_USERS" "$(printf '%s\n%s' Sources/App/Satellites/ModuleMigration.swift Sources/Kit/SatelliteCatalog.swift)"
same "в ModuleMigration.swift флаг один: #if без else (автомиграция выключена)" \
  "$(grep -c 'KIT_PILOT_CATALOG\|KitPilotCatalog' Sources/App/Satellites/ModuleMigration.swift)" "1"
DEFINED="$(grep -rn 'enum KitPilotCatalog' Sources || true)"
same "в исходниках определения нет: без флага и файла сборки пилота не собрать" "$DEFINED" ""
RELEASE="$(cat scripts/release.sh .github/workflows/ci.yml)"
lacks "выпуск и CI не передают источник пилота" "$RELEASE" "pilot"
# Строки с /Applications только для текста автору: heredoc печати и комментарии.
WRITES="$(sed '/^cat <<TEXT$/,/^TEXT$/d' scripts/build-pilot.sh | grep -n '/Applications' | grep -v '^[0-9]*:#' || true)"
same "build-pilot.sh не работает с /Applications" "$WRITES" ""
if output="$(NO_INSTALL= ./build.sh --pilot-catalog-source /nonexistent 2>&1)"; then bad "пилот без NO_INSTALL прошёл"; else has "пилот без NO_INSTALL: отказ" "$output" "NO_INSTALL"; fi
if output="$(NO_INSTALL=1 ./build.sh --что-то 2>&1)"; then bad "неизвестный аргумент прошёл"; else has "неизвестный аргумент: отказ" "$output" "Использование"; fi

echo "== сборка пилота"
rm -rf "$OUT"
mkdir -p "$OUT/src"
BEFORE="$(apps_state)"
scripts/build-pilot.sh "$PILOT" > "$OUT/pilot.log" 2>&1 || { cat "$OUT/pilot.log"; bad "build-pilot.sh упал"; exit 1; }
tail -14 "$OUT/pilot.log"
same "/Applications не тронут" "$(apps_state)" "$BEFORE"
CATALOG="$PILOT/catalog.json"
HUB="$PILOT/hub/Utilitumus.app"
same "версия центра пилота" "$(plutil -extract CFBundleShortVersionString raw -o - "$HUB/Contents/Info.plist")" "$(plutil -extract CFBundleShortVersionString raw -o - Info.plist)"
same "sha256 в каталоге — настоящий у архива" "$(plutil -extract apps.0.sha256 raw -o - "$CATALOG")" "$(shasum -a 256 "$PILOT/Awake.zip" | cut -d' ' -f1)"
same "minHub" "$(plutil -extract apps.0.minHub raw -o - "$CATALOG")" "0.6.0"
PILOT_STRINGS="$(strings -a "$HUB/Contents/MacOS/Utilitumus")"
has "центр пилота содержит путь к каталогу" "$PILOT_STRINGS" "$CATALOG"
lacks "центр пилота не ходит за настоящим каталогом" "$PILOT_STRINGS" "$RAW"
AWAKE_STRINGS="$(strings -a "$PILOT/app/Awake.app/Contents/MacOS/Awake")"
lacks "утилита собрана без флага: своя проверка обновлений смотрит настоящий каталог" "$AWAKE_STRINGS" "$CATALOG"

echo "== обычная сборка"
NO_INSTALL=1 BUILD_DIR="$OUT/plain" ./build.sh > "$OUT/plain.log" 2>&1 || { cat "$OUT/plain.log"; bad "обычная сборка упала"; exit 1; }
PLAIN_STRINGS="$(strings -a "$OUT/plain/Utilitumus.app/Contents/MacOS/Utilitumus")"
lacks "обычная сборка не содержит путь к каталогу пилота" "$PLAIN_STRINGS" "$CATALOG"
lacks "обычная сборка не содержит папку пилота" "$PLAIN_STRINGS" "$PILOT"
has "обычная сборка читает настоящий каталог" "$PLAIN_STRINGS" "$RAW"

echo "== центр прочитает то, что собрано"
# Те же вызовы, что у настоящего центра: URLSession по file://, разбор каталога, загрузка архива, подпись.
cat > "$OUT/src/main.swift" <<'SWIFT'
import CryptoKit
import Foundation

@main struct Check {
    static func main() async throws {
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: SatelliteCatalog.url))
        let app = try SatelliteCatalog.decode(data).apps[0]
        let (archive, _) = try await URLSession.shared.download(from: app.url)
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try KitSigning.run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
        defer { try? FileManager.default.removeItem(at: work) }
        try KitSigning.verifySignature(of: work.appendingPathComponent("Awake.app"), identifier: KitLink.bundleID(app.id), strict: true)
        print("\(app.id) \(app.version) \(digest == app.sha256)")
    }
}
SWIFT
swiftc -parse-as-library -target "$TARGET" -D KIT_PILOT_CATALOG -o "$OUT/reader" "$OUT/src/main.swift" "$PILOT/PilotCatalog.swift" \
  Sources/Kit/KitDefaults.swift Sources/Kit/KitSigning.swift Sources/Kit/SatelliteCatalog.swift $(find Sources/Kit/Link -name '*.swift')
same "каталог и архив читаются по file://, сумма и подпись сошлись" "$("$OUT/reader")" "awake 1.0.0 true"

if [ "$fails" -ne 0 ]; then echo "Провалов: $fails"; exit 1; fi
echo "СБОРКА ПИЛОТА: ВСЁ ОК"
