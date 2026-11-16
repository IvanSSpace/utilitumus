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
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/ClipboardThumbnail\.swift:[0-9]+: +try FileHandle\(forReadingFrom: url\)\.close\(\)$' \
  | /usr/bin/grep -v '^$' || true)"
[ -z "$UNEXPECTED" ] || { echo "$UNEXPECTED"; echo "ПРОВАЛ: файл открывается мимо ClipFileAccess"; exit 1; }
for f in Sources/Modules/Clipboard/ClipboardPanel.swift Sources/Modules/Clipboard/UI/ClipboardShared.swift; do
  /usr/bin/grep -B1 'icon(forFile: url.path)' "$f" | /usr/bin/grep -q 'url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:' \
    || { echo "ПРОВАЛ: в $f значок по адресу не из urlForApplication"; exit 1; }
done
ACCESS="$(/usr/bin/awk '/^struct ClipFileAccess \{/,/^\}/' Sources/Modules/Clipboard/ClipboardThumbnail.swift)"
# Открытие на пробу и источник ImageIO — оба по разу и только в ClipFileAccess.openChecked.
[ "$(printf '%s\n' "$READS" | /usr/bin/grep -c 'CGImageSourceCreateWithURL')" = 1 ] \
  && [ "$(printf '%s\n' "$READS" | /usr/bin/grep -c 'FileHandle')" = 1 ] \
  && printf '%s\n' "$ACCESS" | /usr/bin/awk '/private static func openChecked\(/{f=1} f && /CGImageSourceCreateWithURL/{a=1} f && /FileHandle\(forReadingFrom: url\)/{b=1} END{exit !(a && b)}' \
  || { echo "ПРОВАЛ: CGImageSourceCreateWithURL и FileHandle должны быть по одному и только в ClipFileAccess.openChecked"; exit 1; }
# Открытие только в imageSource и только после проверки по тексту, разбора ссылок и второй проверки. «Спрашиваемая» папка
# (Рабочий стол, Документы, Загрузки) разрешена только флагом (`granted`) или этим нажатием (`asking`), закрытая — никогда.
[ "$(cat "${MODULE[@]}" | /usr/bin/grep -c 'openChecked')" = 2 ] \
  && [ "$(printf '%s\n' "$ACCESS" | /usr/bin/grep -c 'open(URL(')" = 1 ] \
  && printf '%s\n' "$ACCESS" | /usr/bin/awk '/func imageSource\(atPath/{f=1} f && /let allowed = asking\.map \{ granted\.union\(\[\$0\]\) \} \?\? granted$/{z=NR}
       f && /let place = protected\.place\(path: path\)$/{a=NR} f && /if case \.ask\(let folder\) = place, !allowed\.contains\(folder\) \{ return \.needsAccess\(folder\) \}/{n=NR}
       f && /guard allows\(place, allowed\),$/{g=NR} f && /let real = resolved\(path, allowed: allowed\), allows\(protected\.place\(path: real\), allowed\)/{b=NR}
       f && /switch open\(URL\(fileURLWithPath: real\)\)/{c=NR} END{exit !(z && a && n && g && b && c && z < a && a < n && n < g && g < b && b < c)}' \
  && printf '%s\n' "$ACCESS" | /usr/bin/awk '/func resolved\(_ path: String, allowed:/{f=1} f && /guard allows\(protected\.place\(done\), allowed\) else \{ return nil \}/{a=NR}
       f && /readLink\(/{if (!r) r=NR} END{exit !(a && r && a < r)}' \
  && printf '%s\n' "$ACCESS" | /usr/bin/awk '/private func allows\(/{f=1} f && /case \.open: return true/{o=1} f && /case \.ask\(let folder\): return allowed\.contains\(folder\)/{k=1}
       f && /case \.closed: return false/{c=1} END{exit !(o && k && c)}' \
  || { echo "ПРОВАЛ: файл открывается не после проверки защищённых папок и доступа к «спрашиваемым»"; exit 1; }
echo "ok   файл из записи открывается только через ClipFileAccess и только после проверки защищённых папок"
# Доступ к «спрашиваемой» папке: флаг ставится только после миниатюры, сделанной по нажатию; набор «все папки» нигде не
# подставляется, доступ к файлам берётся только из флагов.
ALLCASES="$(/usr/bin/grep -nE 'ClipAskFolder\.allCases|granted: *Set\(' "${MODULE[@]}" || true)"
[ -z "$ALLCASES" ] || { echo "$ALLCASES"; echo "ПРОВАЛ: доступ ко всем «спрашиваемым» папкам сразу"; exit 1; }
GRANTS="$(cat "${MODULE[@]}" | /usr/bin/grep -c 'grantFolder(')"
[ "$GRANTS" = 2 ] && /usr/bin/awk '/private func finishPreview\(/{f=1} f && /case \.made:/{m=NR} f && /grantFolder\(folder\)/{g=NR} f && /case \.denied/{d=NR} END{exit !(m && g && d && m < g && g < d)}' \
  Sources/Modules/Clipboard/ClipboardController.swift \
  || { echo "ПРОВАЛ: флаг папки ставится не только после сделанной по нажатию миниатюры"; exit 1; }
/usr/bin/grep -qE 'var fileAccess: \(Set<ClipAskFolder>\) -> ClipFileAccess = \{ \.system\(granted: \$0\) \}$' Sources/Modules/Clipboard/ClipboardController.swift \
  && [ "$(/usr/bin/grep -c 'fileAccess(grantedFolders)' Sources/Modules/Clipboard/ClipboardController.swift)" = 3 ] \
  && [ "$(cat "${MODULE[@]}" | /usr/bin/grep -c 'fileAccess(')" = 3 ] \
  || { echo "ПРОВАЛ: доступ к файлам записей не из флагов папок"; exit 1; }
echo "ok   «спрашиваемые» папки: только флаг после нажатия или само нажатие"
# Прочие обращения к файлам по путям записей: метаданные и ссылки только в ClipFileAccess, «есть ли файл» — только
# после проверки защищённых папок (перенос карточки) или в своём каталоге истории.
META="$(/usr/bin/grep -nE 'resourceValues|destinationOfSymbolicLink|\.fileExists\(|isReadableFile|attributesOfItem|[^a-zA-Z_.]l?stat\(|checkResourceIsReachable|resolvingSymlinksInPath' "${MODULE[@]}" \
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/ClipboardThumbnail\.swift:[0-9]+: +(values = try url\.resourceValues\(forKeys: keys\)|ClipFileAccess\(protected: \.system, granted: granted, readLink: \{ try\? FileManager\.default\.destinationOfSymbolicLink\(atPath: \$0\) \},)$' \
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/ClipboardThumbnail\.swift:[0-9]+: +/// ' \
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/ClipboardPanelDrag\.swift:[0-9]+: +protected\.contains\(path: path\) \|\| FileManager\.default\.fileExists\(atPath: path\)$' \
  | /usr/bin/grep -vE '^Sources/Modules/Clipboard/ClipboardStore\.swift:[0-9]+: +while fm\.fileExists\(atPath: target\.path\) \{$' || true)"
[ -z "$META" ] || { echo "$META"; echo "ПРОВАЛ: обращение к файлу записи мимо проверки защищённых папок"; exit 1; }
echo "ok   метаданные и ссылки файлов записи только в ClipFileAccess, «есть ли файл» — после проверки папок"
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
