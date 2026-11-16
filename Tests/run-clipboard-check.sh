#!/bin/bash
# Проверка логики модуля «Буфер»: собирает Tests/ClipboardCheck.swift с нужными исходниками и запускает.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/clipboard-check"
mkdir -p "$OUT"

# Настоящая Связка ключей и настоящая история этой проверке недоступны: связка только в памяти.
status=0
FOUND="$(grep -nE 'SecItem(Copy|Add|Delete|Update)|ClipboardKeychain\.system|SystemClipboardKeyring|defaultDirectory|Application Support|history-key|NSPasteboard\.general' Tests/ClipboardCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка называет настоящую связку, каталог или буфер:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   проверка не называет настоящую связку, каталог истории и общий буфер" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Содержимое файла из записи открывается только через ClipFileAccess: путь сначала сверяется с защищёнными папками
# (Рабочий стол, Документы, Загрузки, Библиотека, тома), иначе macOS спросит разрешение. Кроме него читают только свои
# файлы истории (ClipboardStore, каталог хранилища) и значки программ по адресу из urlForApplication.
MODULE=(Sources/Modules/Clipboard/*.swift Sources/Modules/Clipboard/UI/*.swift)
READS="$(/usr/bin/grep -nE 'CGImageSourceCreateWithURL|CGImageSourceCreateIncremental|CGDataProviderCreateWithURL|CGImageDestinationCreateWithURL|NSImage\((contentsOf|byReferencing|contentsOfFile)|NS(Bitmap)?ImageRep\((contentsOf|imageRepWithContentsOf)|imageRep\(withContentsOf|NSData\(contents|Data\(contentsOf|FileHandle|InputStream|contentsOfFile|fopen\(|open\([^)]*O_RDONLY|mmap\(|\.mappedIfSafe|QLThumbnail|QLPreview|icon\(forFiles?' "${MODULE[@]}" || true)"
UNEXPECTED="$(printf '%s\n' "$READS" \
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/ClipboardStore\.swift:[0-9]+: .*Data\(contentsOf: (directory\.appendingPathComponent\(|indexURL\))' \
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/(ClipboardPanel|UI/ClipboardShared)\.swift:[0-9]+: +let icon = NSWorkspace\.shared\.icon\(forFile: url\.path\)$' \
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/ClipboardThumbnail\.swift:[0-9]+: +return CGImageSourceCreateWithURL\(url as CFURL' \
  | /usr/bin/grep -v '^$' || true)"
[ -z "$UNEXPECTED" ] || { echo "$UNEXPECTED"; echo "ПРОВАЛ: файл открывается мимо ClipFileAccess"; exit 1; }
for f in Sources/Modules/Clipboard/ClipboardPanel.swift Sources/Modules/Clipboard/UI/ClipboardShared.swift; do
  /usr/bin/grep -B1 'icon(forFile: url.path)' "$f" | /usr/bin/grep -q 'url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:' \
    || { echo "ПРОВАЛ: в $f значок по адресу не из urlForApplication"; exit 1; }
done
ACCESS="$(/usr/bin/awk '/^struct ClipFileAccess \{/,/^\}/' Sources/Modules/Clipboard/ClipboardThumbnail.swift)"
[ "$(printf '%s\n' "$READS" | /usr/bin/grep -c 'CGImageSourceCreateWithURL')" = 1 ] \
  && printf '%s\n' "$ACCESS" | /usr/bin/awk '/private static func openChecked\(/{f=1} f && /CGImageSourceCreateWithURL/{ok=1} END{exit !ok}' \
  || { echo "ПРОВАЛ: CGImageSourceCreateWithURL должен быть один и только в ClipFileAccess.openChecked"; exit 1; }
# Открытие только в imageSource и только после проверки по тексту, разбора ссылок и второй проверки.
[ "$(cat "${MODULE[@]}" | /usr/bin/grep -c 'openChecked')" = 2 ] \
  && [ "$(printf '%s\n' "$ACCESS" | /usr/bin/grep -c 'open(URL(')" = 1 ] \
  && printf '%s\n' "$ACCESS" | /usr/bin/awk '/func imageSource\(atPath/{f=1} f && /!protected\.contains\(path: path\)/{a=NR} f && /let real = resolved\(path\), !protected\.contains\(path: real\)/{b=NR}
       f && /return open\(URL\(fileURLWithPath: real\)\)/{c=NR} END{exit !(a && b && c && a < b && b < c)}' \
  || { echo "ПРОВАЛ: файл открывается не после проверки защищённых папок"; exit 1; }
echo "ok   файл из записи открывается только через ClipFileAccess и только после проверки защищённых папок"
# Без -parse-as-library: код верхнего уровня лежит в файле, который называется не main.swift.
# Инкрементальная сборка: кэш вне папки стенда, копия с тем же содержимым не меняет время изменения. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache clipboard)"
mkdir -p "$CACHE/src"
cmp -s Tests/ClipboardCheck.swift "$CACHE/src/main.swift" || cp Tests/ClipboardCheck.swift "$CACHE/src/main.swift"
FILES=("$CACHE/src/main.swift"
  Sources/Modules/Clipboard/UI/ClipboardModels.swift
  Sources/Modules/Clipboard/ClipboardStore.swift
  Sources/Modules/Clipboard/ClipboardThumbnail.swift
  Sources/Modules/Clipboard/ClipboardPasteboard.swift
  Sources/Modules/Clipboard/ClipboardPreview.swift)
incremental_flags "$CACHE" "${FILES[@]}"
rm -f "$OUT/check"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -module-name ClipboardCheck -o "$OUT/check" "${FILES[@]}" \
  -framework AppKit -framework CryptoKit -framework Security
"$OUT/check"
