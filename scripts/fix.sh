#!/bin/bash
# Быстрая правка одной утилиты или лаунчера: только их проверки и только их выпуск.
#   scripts/fix.sh mixer --note "Что изменилось" [--note "Ещё"] [--dry-run]
#   scripts/fix.sh hub --note "Что изменилось" [--note "Ещё"] [--dry-run]     (лаунчер)
#
# Порядок. Выкладка требует main, совпадающий с GitHub, это проверяет release-app.sh:
#   1. правка закоммичена, влита в main и запушена (этот скрипт ничего не сливает и не пушит сам);
#   2. scripts/fix.sh <id> --note "..." --dry-run, если нужен план без выкладки;
#   3. scripts/fix.sh <id> --note "...".
# Красная проверка оставляет правку в main, но к людям она не идёт: люди видят только то, что записано в каталог.
# Лаунчер: людям он идёт как релиз v<версия> с пометкой Latest, и в main версия с заметкой попадают при выпуске сами.
# Выпуск лаунчера (scripts/release.sh X.Y.Z --note ...) дописывает запись в Resources/WhatsNew.json (её читают окно «Что нового»
# и описание релиза), ставит версию в Info.plist, собирает, проверяет подпись и следы шва и только потом одним коммитом
# «Версия X» пушит это в main, ставит тег v<X> и выкладывает релиз. Поэтому правку лаунчера записывать в WhatsNew.json и менять
# версию руками не нужно; порядок тот же: правка в main и запушена, потом scripts/fix.sh hub --note "...".
# Сорвался релиз уже после пуша — scripts/release.sh X.Y.Z без --note: запись уже в main.
#
# Что делает:
#   1. Сравнивает HEAD с последним выпуском утилиты (тег <id>-v<версия из Catalog/catalog.json>) или лаунчера (тег v<версия из
#      Info.plist>). Правка чего-то кроме этой утилиты — отказ: Kit, центр, общий код и прочее идут через полный прогон
#      (scripts/release-all.sh или scripts/release.sh). Что чьё — scripts/dev-scope.sh, что можно — scripts/fix-scope.sh.
#      Правка чужой утилиты или центра, которая уже вышла своим выпуском, не мешает.
#      Для лаунчера отказ: Kit, Shared, помощники, код утилит, договор связи (*Wire.swift). Экраны Sources/Modules/*/UI лаунчер
#      компилирует сам, поэтому правка проходит с предупреждением: в окне самой утилиты её не будет до выпуска утилиты.
#   2. Версия — патч выше каталожной (у лаунчера — выше Info.plist). Sources/Apps/<Имя>/Info.plist не меняется: версию выпуска
#      утилиты задаёт аргумент release-app.sh.
#   3. Параллельно гонит проверки этой утилиты (таблица в scripts/fix-scope.sh) через Tests/with-check-lock.sh.
#      Красная проверка — выпуска нет, флага для обхода нет.
#   4. Зовёт scripts/release-app.sh (лаунчер: scripts/release.sh): сборка -O, подпись, поиск следов шва и дев-режима, каталог, выкладка, всё там.
#      С --dry-run тот же путь, но ничего не выкладывается и не меняется.
#   5. Печатает время по шагам.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "${UTILITUMUS_DEV_CACHE:-}" ] || { echo "UTILITUMUS_DEV_CACHE задан: выпуск только из обычной сборки (-O)." >&2; exit 1; }

fail() { echo "$1" >&2; exit 1; }
USAGE='Использование: scripts/fix.sh <id|hub> --note "Что изменилось" [--note "Ещё"] [--dry-run]'
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
secs() { perl -e 'printf "%.1f", $ARGV[0]-$ARGV[1]' "$2" "$1"; } # начало, конец

[ $# -ge 1 ] || fail "$USAGE"
ID="$1"
shift
DRY_RUN=""
NOTES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --note)
      # Как в release-app.sh: «--note --dry-run» не должен съесть флаг и превратить проверку в настоящий выпуск.
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then fail "После --note нужен текст заметки."; fi
      NOTES+=("$2")
      shift 2
      ;;
    *) fail "Неизвестный аргумент: ${1}. ${USAGE}" ;;
  esac
done
[ ${#NOTES[@]} -gt 0 ] || fail "Нет заметок: напиши через --note, что изменилось. ${USAGE}"
# Те же пределы, что в release-app.sh: он увидел бы плохую заметку только после всех проверок.
python3 -I -c '
import sys, unicodedata
notes = sys.argv[1:]
if len(notes) > 8:
    sys.exit("Заметок больше 8.")
for note in notes:
    if not note.strip():
        sys.exit("Пустая заметка.")
    if len(note) > 200:
        sys.exit("Заметка длиннее 200 знаков: %s" % note)
    if any(unicodedata.category(c) in ("Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp") for c in note):
        sys.exit("В заметке перевод строки или управляющий символ: %r" % note)
' "${NOTES[@]}"

# --- 1. Что менялось
T_START="$(now)"
APPS=""
for dir in Sources/Apps/*/; do
  name="$(basename "$dir")"
  APPS="$APPS $(printf '%s' "$name" | tr '[:upper:]' '[:lower:]'):$name"
done
. scripts/dev-scope.sh
. scripts/fix-scope.sh

HUB=""
[ "$ID" != hub ] || HUB=1
if [ -n "$HUB" ]; then
  NAME="лаунчер"
  OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
  TAG="v$OLD_VERSION"
else
  NAME="$(name_of "$ID")" || fail "Нет такой утилиты: ${ID}. Есть:$(for p in $APPS; do printf ' %s' "${p%%:*}"; done) и hub (лаунчер)"
  OLD_VERSION="$(fix_catalog_version "$ID")"
  [ -n "$OLD_VERSION" ] || fail "${ID} ещё нет в каталоге: первый выпуск идёт через scripts/release-all.sh."
  TAG="$ID-v$OLD_VERSION"
fi
CHECKS="$(fix_checks_of "$ID")" || fail "Для ${ID} нет строки в таблице проверок scripts/fix-scope.sh."
VERSION="$(fix_next_patch "$OLD_VERSION")"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Нет тега ${TAG} последнего выпуска: не с чем сравнить. Сначала git fetch --tags."
HUB_TAG="v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
# Запись для новой версии пишет сам выпуск лаунчера: готовая запись означает чужую правку или оборвавшийся выпуск.
if [ -n "$HUB" ] && grep -qF "\"version\": \"$VERSION\"" Resources/WhatsNew.json; then
  fail "В Resources/WhatsNew.json уже есть запись для ${VERSION}: убери её или, если релиз оборвался после пуша, запусти scripts/release.sh ${VERSION}."
fi

# --no-renames: перенос файла из Kit в модуль виден как правка обоих мест.
if [ -n "$HUB" ]; then
  fix_classify_hub <<<"$(git diff --name-only --no-renames "$TAG" HEAD)"
else
  fix_classify "$ID" <<<"$(git diff --name-only --no-renames "$TAG" HEAD)"
fi
if [ ${#FIX_REFUSED[@]} -gt 0 ]; then
  echo "Отказ: с ${TAG} менялось не только ${NAME}." >&2
  for line in "${FIX_REFUSED[@]}"; do echo "  $line" >&2; done
  fail "Здесь быстрый путь не годится: нужен полный прогон проверок и обычный выпуск, scripts/release-all.sh (утилиты и центр) или scripts/release.sh (центр)."
fi
[ ${#FIX_OWN[@]} -gt 0 ] || fail "С ${TAG} в ${NAME} ничего не менялось: выпускать нечего."
WHOSE="утилиты"
[ -z "$HUB" ] || WHOSE="лаунчера"
echo "Выпуск ${NAME} ${OLD_VERSION} → ${VERSION}. Файлы ${WHOSE} с ${TAG} (${#FIX_OWN[@]}):"
for line in "${FIX_OWN[@]}"; do echo "  $line"; done
[ ${#FIX_SKIPPED[@]} -eq 0 ] || echo "Не мешают выпуску: ${#FIX_SKIPPED[@]} (проверки, скрипты разработки, каталог, уже вышедшее)."
if [ -n "$HUB" ]; then
  if [ ${#FIX_SCREENS[@]} -gt 0 ]; then
    echo "Внимание: экран лаунчера компилируется и в окно утилиты. Эта правка будет видна только в лаунчере, в окне утилиты — после выпуска утилиты:"
    for line in "${FIX_SCREENS[@]}"; do echo "  $line"; done
  fi
else
  SCREENS_CHANGED="$(fix_screen_files "${FIX_OWN[@]}")"
  if [ -n "$SCREENS_CHANGED" ]; then
    echo "Внимание: вкладку в лаунчере рисует центр своей копией экрана. Эта правка будет видна только в окне утилиты, во вкладке — после выпуска центра:"
    echo "$SCREENS_CHANGED" | sed 's/^/  /'
  fi
fi

# Голосу нужен движок в Vendor: если его нет, все проверки упали бы поодиночке. Обычно это проверка одной метки, без сети.
if [ -z "$HUB" ] && grep -q 'Vendor/' "Sources/Apps/$NAME/manifest.json"; then scripts/fetch-sherpa.sh >/dev/null; fi

# Те же условия, что в release-app.sh, только до проверок, а не после: минуты ждать не за чем.
[ -z "$(git status --porcelain)" ] || fail "Есть незакоммиченные изменения — сначала закоммить их, влей в main и запушь."
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  fail "HEAD не совпадает с origin/main. Порядок такой: правка влита в main, git push, потом scripts/fix.sh. Сам скрипт не сливает и не пушит."
fi
T_CHANGES="$(now)"

# --- 2. Проверки, параллельно. Что не может идти вместе, разводит замок.
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/fix-${ID}.XXXXXX")"
echo "Проверки: $CHECKS $FIX_COMMON_CHECKS"
for check in $CHECKS $FIX_COMMON_CHECKS; do
  (
    s="$(now)"
    status=0
    Tests/with-check-lock.sh /bin/bash "Tests/$check.sh" > "$LOGS/$check.log" 2>&1 </dev/null || status=$?
    echo "$status $(secs "$s" "$(now)")" > "$LOGS/$check.rc"
  ) &
done
wait

RED=""
for check in $CHECKS $FIX_COMMON_CHECKS; do
  read -r status elapsed < "$LOGS/$check.rc"
  if [ "$status" -eq 0 ]; then
    printf '  ok      %7s с  %s\n' "$elapsed" "$check"
  else
    printf '  ПРОВАЛ  %7s с  %s (код %s)\n' "$elapsed" "$check" "$status"
    RED="$RED $check"
  fi
done
T_CHECKS="$(now)"
if [ -n "$RED" ]; then
  for check in $RED; do
    echo "--- $check, конец журнала ($LOGS/$check.log)" >&2
    tail -20 "$LOGS/$check.log" >&2
  done
  fail "Красные проверки:${RED}. Выпуск не идёт."
fi

# --- 3. Выпуск. build-app.sh печатает «Собрано:» в конце сборки: по этой строке время делится на сборку и выкладку.
if [ -n "$HUB" ]; then
  REL=scripts/release.sh
  ARGS=("$VERSION")
else
  REL=scripts/release-app.sh
  ARGS=("$ID" "$NAME" "$VERSION")
fi
for note in "${NOTES[@]}"; do ARGS+=(--note "$note"); done
[ -z "$DRY_RUN" ] || ARGS+=(--dry-run)
status=0
"$REL" "${ARGS[@]}" 2>&1 </dev/null | while IFS= read -r line; do
  printf '%s\n' "$line"
  case "$line" in "Собрано: "*) now > "$LOGS/built-at" ;; esac
done || status=$?
T_END="$(now)"
T_BUILT="$T_END"
[ ! -f "$LOGS/built-at" ] || T_BUILT="$(<"$LOGS/built-at")"

echo
echo "Время по шагам:"
printf '%8s с  определение изменений\n' "$(secs "$T_START" "$T_CHANGES")"
printf '%8s с  проверки, %s шт. параллельно\n' "$(secs "$T_CHANGES" "$T_CHECKS")" "$(echo $CHECKS $FIX_COMMON_CHECKS | wc -w | tr -d ' ')"
printf '%8s с  сборка -O\n' "$(secs "$T_CHECKS" "$T_BUILT")"
if [ -n "$DRY_RUN" ]; then
  printf '%8s с  выкладка: --dry-run, только подпись, архив, каталог и план; на GitHub ничего не ушло\n' "$(secs "$T_BUILT" "$T_END")"
else
  printf '%8s с  выкладка\n' "$(secs "$T_BUILT" "$T_END")"
fi
printf '%8s с  всего\n' "$(secs "$T_START" "$T_END")"
[ "$status" -eq 0 ] || fail "release-app.sh остановился с кодом ${status}, журнал выше."
rm -rf -- "$LOGS"
