#!/bin/bash
# Релиз со своего Mac: собрать, подписать постоянным сертификатом и выложить
# в GitHub Releases. Без очереди на macOS-раннеры GitHub (там можно ждать
# десятки минут). Приложение у пользователей найдёт релиз само.
#   ./scripts/release.sh 0.2.2 [--note "Что изменилось" ...] [--dry-run]
# Без --note запись для версии должна уже лежать в Resources/WhatsNew.json в main. С --note скрипт дописывает её сам (запись
# вверху файла, до сборки: файл входит в бандл) и уносит в main вместе с версией одним коммитом «Версия X» — так зовёт
# scripts/fix.sh hub, без правок и ввода руками. Версия и запись попадают в main только после сборки, подписи и проверки следов
# шва: сорвалась сборка — main не тронут, а правки версии и заметок откатываются. Дальше по порядку: пуш main, тег, релиз.
# Сорвался релиз после пуша — запусти scripts/release.sh X без --note: запись уже в main.
# --dry-run проходит тот же путь, но коммит, пуш, тег и релиз только печатает; правки версии и заметок в конце откатываются.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "${UTILITUMUS_DEV_CACHE:-}" ] || { echo "UTILITUMUS_DEV_CACHE задан: выпуск только из обычной сборки (-O)." >&2; exit 1; }

fail() { echo "$1" >&2; exit 1; }
USAGE='Использование: ./scripts/release.sh X.Y.Z [--note "Что изменилось" ...] [--dry-run]'
VERSION="${1:?$USAGE}"
shift
DRY_RUN=""
NOTE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --note)
      # Иначе «--note --dry-run» съел бы флаг, и вместо проверки вышел бы настоящий выпуск.
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then fail "После --note нужен текст заметки."; fi
      NOTE_ARGS+=("$2")
      shift 2
      ;;
    # Опечатка в --dry-run не должна превращаться в настоящий выпуск.
    *) fail "Неизвестный аргумент: ${1}. ${USAGE}" ;;
  esac
done
TAG="v$VERSION"
REPO="IvanSSpace/utilitumus"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token --user IvanSSpace 2>/dev/null || true)}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Есть незакоммиченные изменения — сначала закоммить их." >&2
  exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Локальный main не совпадает с GitHub — сначала git push." >&2
  exit 1
fi
# Всё, что меняет репозиторий или GitHub, идёт через run: --dry-run проходит те же шаги в том же порядке.
run() {
  if [ -n "$DRY_RUN" ]; then
    echo "+ $*"
  else
    "$@"
  fi
}
restore() { git checkout -q -- Info.plist Resources/WhatsNew.json; }
if [ ${#NOTE_ARGS[@]} -gt 0 ]; then
  trap restore EXIT
  # Те же пределы, что в release-app.sh и SatelliteCatalog.cleanNotes. Запись вставляется текстом после «[»: остальной файл не меняется.
  python3 -I -c '
import json, sys, unicodedata
path, version, *notes = sys.argv[1:]
if len(notes) > 8:
    sys.exit("Заметок больше 8.")
for note in notes:
    if not note.strip():
        sys.exit("Пустая заметка.")
    if len(note) > 200:
        sys.exit("Заметка длиннее 200 знаков: %s" % note)
    if any(unicodedata.category(c) in ("Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp") for c in note):
        sys.exit("В заметке перевод строки или управляющий символ: %r" % note)
with open(path, encoding="utf-8") as f:
    text = f.read()
if any(e["version"] == version for e in json.loads(text)):
    sys.exit("В %s уже есть запись для %s: запусти без --note." % (path, version))
entry = json.dumps({"version": version, "items": notes}, ensure_ascii=False, indent=2)
entry = "\n".join("  " + line for line in entry.splitlines())
head, sep, rest = text.partition("[\n")
if head.strip() or not sep:
    sys.exit("%s начинается не с «[»." % path)
text = head + sep + entry + ",\n" + rest
json.loads(text)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
' Resources/WhatsNew.json "$VERSION" "${NOTE_ARGS[@]}"
fi
# Что нового — из Resources/WhatsNew.json: то же видят пользователи в приложении.
NOTES="$(python3 -c '
import json, sys
v = sys.argv[1]
e = next((e for e in json.load(open("Resources/WhatsNew.json")) if e["version"] == v), None)
print("\n".join("- " + (i["text"] if isinstance(i, dict) else i) for i in e["items"]) if e else "")
' "$VERSION")"
if [ -z "$NOTES" ]; then
  echo "Нет записи для $VERSION в Resources/WhatsNew.json — допиши, что изменилось." >&2
  exit 1
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "Релиз $TAG уже есть." >&2
  exit 1
fi

# Версия идёт в бандл из рабочей копии, в main — после проверок ниже, одним коммитом: иначе локальная сборка
# остаётся со старой версией и приложение предлагает «обновиться» назад.
trap restore EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" Info.plist

NO_INSTALL=1 ./build.sh
# Без постоянного сертификата у пользователей после обновления слетят разрешения.
if ! codesign -d -r- build/Utilitumus.app 2>&1 | grep -q "certificate leaf"; then
  echo "Сборка не подписана сертификатом «Utilitumus Signing» — релиз не выкладываю." >&2
  exit 1
fi
# Сборка со швом подписана тем же ключом и ушла бы к людям как настоящая: ищем следы шва в самом бандле.
scripts/check-no-seam.sh build/Utilitumus.app || { echo "В сборке следы тестового шва — релиз не выкладываю." >&2; exit 1; }
ditto -c -k --keepParent build/Utilitumus.app build/Utilitumus.zip

if ! { run git add Info.plist Resources/WhatsNew.json && run git commit -q -m "Версия $VERSION"; }; then
  fail "Не удалось закоммитить версию $VERSION: релиз не выложен."
fi
# Коммит есть: откатывать правки больше нечего (при --dry-run коммита нет, откат остаётся).
[ -n "$DRY_RUN" ] || trap - EXIT
run git push -q origin HEAD:main || fail "Не удалось запушить main: коммит «Версия ${VERSION}» остался только здесь, релиз не выложен."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || run git tag "$TAG"
run git push -q origin "$TAG"
run gh release create "$TAG" build/Utilitumus.zip -R "$REPO" --title "Utilitumus $TAG" --notes "$NOTES" --latest=true
if [ -n "$DRY_RUN" ]; then
  echo "Архив: build/Utilitumus.zip"
  echo "Ничего не выложено (--dry-run)."
else
  echo "Выложено: https://github.com/$REPO/releases/tag/$TAG"
fi
