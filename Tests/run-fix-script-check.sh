#!/bin/bash
# scripts/fix.sh: отказы на подставных правках, таблица проверок, порядок шагов. Ничего не выкладывает и не запускает утилит:
# подставные репозиторий с локальным origin, gh, codesign, сборка и проверки; настоящие только fix.sh, fix-scope.sh, dev-scope.sh,
# release-app.sh, release.sh, check-no-seam.sh и with-check-lock.sh. Подпись не нужна. Сборка лаунчера (build.sh) подставная.
# Папка стенда: FIX_CHECK_DIR, иначе $TMPDIR/fix-script-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${FIX_CHECK_DIR:-${TMPDIR:-/tmp}/fix-script-check}"
FX="$OUT/repo"
ORIGIN="$OUT/origin.git"
GH_LOG="$OUT/gh.log"
GIT_LOG="$OUT/git.log"
CHECK_LOG="$OUT/checks.log"
RELEASE_MARK="$OUT/built.log"

fails=0
pass() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else bad "$what"; fi; }
same() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1: «${2}», ждали «${3}»"; fi; }
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/tmp" "$OUT/locks" "$FX/scripts"
: > "$GH_LOG"; : > "$GIT_LOG"; : > "$CHECK_LOG"; : > "$RELEASE_MARK"

echo "== скрипты без запуска"
for script in scripts/fix.sh scripts/fix-scope.sh scripts/release.sh Tests/run-fix-script-check.sh; do
  check "bash 3.2 -n $script" /bin/bash -n "$script"
  # bash 5 в UTF-8 считает кириллицу и кавычки «» частью имени: рядом с ними только ${VAR}.
  found="$(LC_ALL=C grep -nE "\\\$[A-Za-z0-9_]+$(printf '[\200-\377]')" "$script" || true)"
  same "$script: нет \$VAR вплотную к не-ASCII" "$found" ""
done
# Выкладка, подпись и каталог только в release-app.sh. Строки комментариев здесь не считаются.
CODE="$(grep -vhE '^[[:space:]]*#' scripts/fix.sh scripts/fix-scope.sh | sed -E 's/(fail|echo) ".*//')"
for word in 'gh ' 'git push' 'git tag' 'git commit' 'git merge' 'codesign' 'ditto' 'buildq' '--skip' '--force' '--no-check'; do
  if grep -qF -- "$word" <<<"$CODE"; then bad "в коде fix.sh есть «${word}»"; else pass "в коде fix.sh нет «${word}»"; fi
done
check "fix.sh зовёт выпуск утилиты" has scripts/fix.sh 'REL=scripts/release-app.sh'
check "fix.sh зовёт выпуск лаунчера" has scripts/fix.sh 'REL=scripts/release.sh'
check "выпуск идёт с ARGS" has scripts/fix.sh '"$REL" "${ARGS[@]}"'
check "проверки идут через замок" has scripts/fix.sh 'Tests/with-check-lock.sh'

echo "== таблица проверок: настоящие файлы"
APPS=""
for dir in Sources/Apps/*/; do
  name="$(basename "$dir")"
  APPS="$APPS $(printf '%s' "$name" | tr '[:upper:]' '[:lower:]'):$name"
done
. scripts/dev-scope.sh
. scripts/fix-scope.sh
same "утилит 12" "$(echo $APPS | wc -w | tr -d ' ')" 12
for pair in $APPS; do
  id="${pair%%:*}"
  if ! row="$(fix_checks_of "$id")" || [ -z "$row" ]; then bad "нет строки для $id"; continue; fi
  for name in $row; do
    check "$id: есть Tests/$name.sh" test -f "Tests/$name.sh"
  done
  # Новая проверка с именем утилиты не должна выпасть из быстрого пути молча.
  for file in Tests/run-"$id"-*.sh; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .sh)"
    case " $row " in *" $name "*) pass "$id: в строке $name" ;; *) bad "$id: $name нет в таблице" ;; esac
  done
done
for name in $FIX_COMMON_CHECKS; do check "общая: есть Tests/$name.sh" test -f "Tests/$name.sh"; done
for name in $(fix_checks_of hub); do check "hub: есть Tests/$name.sh" test -f "Tests/$name.sh"; done
check "hub: в таблице есть оболочка и следы шва" test "$(fix_checks_of hub | tr ' ' '\n' | grep -cE '^(run-hub-shell-check|run-seam-check)$')" -eq 2
if fix_checks_of nosuch >/dev/null; then bad "таблица ответила на чужой id"; else pass "чужого id в таблице нет"; fi

# --- Стенд
cp scripts/fix.sh scripts/fix-scope.sh scripts/dev-scope.sh scripts/release-app.sh scripts/release.sh scripts/check-no-seam.sh "$FX/scripts/"
mkdir -p "$FX/Resources" "$FX/Tests" "$FX/Catalog" "$FX/Sources/Kit" "$FX/Sources/App/Satellites" "$FX/Sources/Shared" "$FX/docs"
cp Tests/with-check-lock.sh "$FX/Tests/"
cp Sources/Kit/KitSigning.swift "$FX/Sources/Kit/"
cp Info.plist "$FX/Info.plist"
echo 'build/' > "$FX/.gitignore"
HUB="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
for name in Mixer Awake Voice; do
  mkdir -p "$FX/Sources/Apps/$name" "$FX/Sources/Modules/$name"
  echo '{}' > "$FX/Sources/Apps/$name/manifest.json"
  echo "// $name" > "$FX/Sources/Modules/$name/${name}Controller.swift"
  echo "// $name" > "$FX/Sources/Modules/$name/${name}View.swift"
  echo "// $name" > "$FX/Sources/Modules/$name/${name}Wire.swift"
done
mkdir -p "$FX/Sources/Modules/Mixer/UI"
echo "// экран" > "$FX/Sources/Modules/Mixer/UI/MixerView.swift"
echo "// связь" > "$FX/Sources/Modules/Mixer/UI/MixerWire.swift"
printf '[\n  {\n    "version": "%s",\n    "items": [\n      "старое"\n    ]\n  }\n]\n' "$HUB" > "$FX/Resources/WhatsNew.json"
echo '// экран' > "$FX/Sources/App/Satellites/RemoteMixerPage.swift"
echo '// общий' > "$FX/Sources/App/Satellites/RemoteModulePage.swift"
echo '// центр' > "$FX/Sources/App/UtilitumusApp.swift"
echo '// общий' > "$FX/Sources/Shared/SMC.swift"
echo '# пилот' > "$FX/scripts/build-pilot.sh"
echo '# доки' > "$FX/docs/a.md"
# Проверка стенда пишет своё имя в журнал. FAKE_RED — кому покраснеть.
for name in run-mixer-eq-check run-mixer-remote-check run-mixer-wire-check run-awake-app-check run-awake-remote-check run-awake-settings-check \
  run-voice-remote-check run-voice-remote-pure-check run-voice-security-check run-voice-wire-check run-module-defaults-guard $(fix_checks_of hub); do
  cat > "$FX/Tests/$name.sh" <<EOF
#!/bin/bash
echo "$name" >> "$CHECK_LOG"
[ "\${FAKE_RED:-}" != "$name" ]
EOF
done
# Подставная сборка лаунчера: бандл из Info.plist и WhatsNew.json рабочей копии, в журнал — версия и первая запись, которые она увидела.
cat > "$FX/build.sh" <<EOF
#!/bin/bash
set -euo pipefail
cd "\$(dirname "\$0")"
rm -rf build
mkdir -p build/Utilitumus.app/Contents/MacOS build/Utilitumus.app/Contents/Resources
printf 'чистый бинарник' > build/Utilitumus.app/Contents/MacOS/Utilitumus
cp Info.plist build/Utilitumus.app/Contents/Info.plist
cp Resources/WhatsNew.json build/Utilitumus.app/Contents/Resources/
echo "hub-build \$(plutil -extract CFBundleShortVersionString raw -o - Info.plist) \$(plutil -extract 0.version raw -o - Resources/WhatsNew.json) \$(plutil -extract 0.items.0 raw -o - Resources/WhatsNew.json)" >> "$RELEASE_MARK"
echo "Собрано: build/Utilitumus.app"
EOF
cat > "$FX/scripts/build-app.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "\$*" >> "$RELEASE_MARK"
app="\$4/\$2.app"
mkdir -p "\$app/Contents/MacOS"
printf 'чистый бинарник' > "\$app/Contents/MacOS/\$2"
echo "Собрано: \$app"
EOF
python3 -I -c '
import json, sys
json.dump({"schema": 1, "apps": [
    {"id": i, "version": "1.1.0", "minHub": "0.6.0", "url": "u", "sha256": "s", "sizeMB": 1, "notes": ["x"]}
    for i in ("mixer", "awake", "voice")]}, open(sys.argv[1], "w"), indent=2)' "$FX/Catalog/catalog.json"
find "$FX/scripts" "$FX/Tests" -type f -exec chmod +x {} +
chmod +x "$FX/build.sh"

# Подставные программы. Настоящим gh и git в стенде не дотянуться до GitHub: origin локальный.
cat > "$OUT/bin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$GH_LOG"
case "\$1 \$2" in
  "auth token") exit 1 ;;
  "release view") exit 1 ;;
esac
EOF
cat > "$OUT/bin/git" <<EOF
#!/bin/bash
echo "git \$*" >> "$GIT_LOG"
exec /usr/bin/git "\$@"
EOF
# release.sh ищет в выводе codesign -d строку про сертификат.
printf '#!/bin/bash\necho "certificate leaf" >&2\nexit 0\n' > "$OUT/bin/codesign"
chmod +x "$OUT/bin/gh" "$OUT/bin/git" "$OUT/bin/codesign"

G=(/usr/bin/git -C "$FX" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.invalid)
/usr/bin/git init -q -b main "$FX"
/usr/bin/git init -q --bare -b main "$ORIGIN"
"${G[@]}" remote add origin "$ORIGIN"
"${G[@]}" config user.name Test
"${G[@]}" config user.email test@example.invalid
"${G[@]}" config core.hooksPath /dev/null
"${G[@]}" config commit.gpgsign false
"${G[@]}" add -A
"${G[@]}" commit -q -m fixture
for tag in mixer-v1.1.0 awake-v1.1.0 voice-v1.1.0 "v$HUB"; do "${G[@]}" tag "$tag"; done
"${G[@]}" push -q origin main --tags
BASE="$("${G[@]}" rev-parse HEAD)"

fix() { (cd "$FX" && env PATH="$OUT/bin:$PATH" TMPDIR="$OUT/tmp" CHECK_LOCK_DIR="$OUT/locks" ${EXTRA_ENV:+$EXTRA_ENV} scripts/fix.sh "$@" </dev/null 2>&1); }
clear_logs() { : > "$GH_LOG"; : > "$GIT_LOG"; : > "$CHECK_LOG"; : > "$RELEASE_MARK"; }
# Правка в main стенда и push: как перед настоящим запуском. Теги остаются на старом месте.
commit_change() { # файлы...
  local file
  "${G[@]}" reset -q --hard "$BASE"
  for file in "$@"; do
    mkdir -p "$(dirname "$FX/$file")"
    # Правка не должна сломать сам файл: JSON и plist читает скрипт, журнал проверки исполняет bash.
    case "$file" in
      *.json) echo "" >> "$FX/$file" ;;
      *.plist) echo "<!-- правка -->" >> "$FX/$file" ;;
      *) echo "# правка" >> "$FX/$file" ;;
    esac
  done
  "${G[@]}" add -A
  "${G[@]}" commit -q -m "правка"
  "${G[@]}" push -q -f origin main
}
ORIGIN_TAGS() { /usr/bin/git -C "$ORIGIN" tag | tr '\n' ' '; }
TAGS_BEFORE="$(ORIGIN_TAGS)"

NOTE=(--note "Заметка")
# Отказ: код не 0, текст на месте, ни проверок, ни сборки, ни gh release.
refused() { # описание, текст в выводе, файлы правки
  local what="$1" pattern="$2" output status=0
  shift 2
  commit_change "$@"
  clear_logs
  output="$(fix mixer "${NOTE[@]}" --dry-run)" || status=$?
  if [ "$status" -eq 0 ]; then bad "${what}: прошло"; echo "$output"
  elif ! grep -qF -- "$pattern" <<<"$output"; then bad "${what}: нет «${pattern}»"; echo "$output"
  elif [ -s "$CHECK_LOG" ] || [ -s "$RELEASE_MARK" ]; then bad "${what}: отказ после проверок или сборки"
  else pass "$what"; fi
}
allowed() { # описание, файлы правки
  local what="$1" output status=0
  shift
  commit_change "$@"
  clear_logs
  output="$(fix mixer "${NOTE[@]}" --dry-run)" || status=$?
  if [ "$status" -eq 0 ]; then pass "$what"; else bad "${what}: код $status"; echo "$output"; fi
}

echo "== отказы на подставных правках"
refused "Kit: отказ и обычный путь" "scripts/release-all.sh" Sources/Kit/KitSigning.swift
refused "Kit: причина" "Kit входит в сборку" Sources/Kit/Theme.swift
refused "центр: отказ" "это лаунчер" Sources/App/UtilitumusApp.swift
refused "центр: обычный путь" "scripts/release.sh" Sources/App/UtilitumusApp.swift
refused "Info.plist центра: отказ" "это лаунчер" Info.plist
refused "чужой модуль: отказ" "чужой утилиты awake" Sources/Modules/Awake/AwakeController.swift
refused "чужая Apps: отказ" "чужой утилиты awake" Sources/Apps/Awake/manifest.json
refused "помощник чужой утилиты: отказ" "чужой утилиты voice" Sources/VoiceHelper/main.c
refused "экран в лаунчере: отказ и лаунчер" "экран mixer в лаунчере: нужен и выпуск лаунчера" Sources/App/Satellites/RemoteMixerPage.swift
refused "общий экран в лаунчере: отказ" "общий код экранов" Sources/App/Satellites/RemoteModulePage.swift
refused "Shared: отказ" "общий код вентиляторов" Sources/Shared/SMC.swift
refused "служба вентиляторов: отказ" "служба вентиляторов" Sources/FanHelper/main.swift
refused "скрипт выпуска: отказ" "этим собирается" scripts/release-app.sh
refused "договор связи: отказ" "договор связи" Sources/Modules/Mixer/MixerWire.swift
refused "свой файл и Kit: отказ" "Kit входит в сборку" Sources/Modules/Mixer/MixerController.swift Sources/Kit/Theme.swift
refused "неизвестный файл: отказ" "не файл этой утилиты" Новый/файл.txt
refused "только проверки: выпускать нечего" "выпускать нечего" Tests/run-mixer-wire-check.sh
# Перенос из Kit в модуль не прячется за новым именем.
"${G[@]}" reset -q --hard "$BASE"
"${G[@]}" mv Sources/Kit/KitSigning.swift Sources/Modules/Mixer/KitSigning.swift
"${G[@]}" commit -q -m "перенос"
"${G[@]}" push -q -f origin main
clear_logs
status=0; output="$(fix mixer "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -ne 0 ] && grep -qF "Kit входит в сборку" <<<"$output"; then pass "перенос из Kit в модуль: отказ"; else bad "перенос из Kit в модуль прошёл: $output"; fi

echo "== что можно"
allowed "свой модуль" Sources/Modules/Mixer/MixerController.swift
allowed "своя Apps" Sources/Apps/Mixer/manifest.json
allowed "свой модуль рядом с проверками, доками и скриптом разработки" Sources/Modules/Mixer/MixerController.swift \
  Tests/run-mixer-wire-check.sh docs/a.md scripts/build-pilot.sh Catalog/catalog.json

# Чужая правка, уже вышедшая своим выпуском: не помеха. Без этого выпуск второй утилиты всегда упирался бы в первую.
commit_change Sources/Modules/Mixer/MixerController.swift Sources/Modules/Awake/AwakeController.swift
"${G[@]}" tag -f awake-v1.1.0 HEAD >/dev/null
clear_logs
status=0; output="$(fix mixer "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -eq 0 ]; then pass "чужая правка, уже выпущенная: не мешает"; else bad "чужая выпущенная правка: $output"; fi
"${G[@]}" tag -f awake-v1.1.0 "$BASE" >/dev/null
# То же для центра: файл совпадает с выпуском центра.
commit_change Sources/Modules/Mixer/MixerController.swift Sources/App/UtilitumusApp.swift
"${G[@]}" tag -f "v$HUB" HEAD >/dev/null
clear_logs
status=0; output="$(fix mixer "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -eq 0 ]; then pass "центр, уже выпущенный: не мешает"; else bad "выпущенный центр: $output"; fi
"${G[@]}" tag -f "v$HUB" "$BASE" >/dev/null

echo "== --dry-run: что запускается и чего нет"
commit_change Sources/Modules/Mixer/MixerController.swift Sources/Modules/Mixer/MixerView.swift
clear_logs
HEAD_BEFORE="$("${G[@]}" rev-parse HEAD)"
CATALOG_BEFORE="$(shasum -a 256 "$FX/Catalog/catalog.json")"
PLAN="$OUT/plan.txt"
fix mixer --note "Первая" --note "Вторая" --dry-run > "$PLAN" 2>&1 || { cat "$PLAN"; bad "--dry-run упал"; }
same "проверки только этой утилиты" "$(LC_ALL=C sort "$CHECK_LOG" | tr '\n' ' ')" "run-mixer-eq-check run-mixer-remote-check run-mixer-wire-check run-module-defaults-guard "
same "версия: патч выше каталожной" "$(cut -d' ' -f1-3 "$RELEASE_MARK")" "mixer Mixer 1.1.1"
same "сборка без шва: четыре аргумента" "$(awk '{print NF}' "$RELEASE_MARK")" 4
check "предупреждение про экран в лаунчере" has "$PLAN" "вкладку в лаунчере рисует центр"
check "план: тег новой версии" has "$PLAN" "+ git tag mixer-v1.1.1"
check "план: gh release create только напечатан" has "$PLAN" "+ gh release create mixer-v1.1.1"
check "gh: нет release create" lacks "$GH_LOG" "release create"
check "gh: нет release upload" lacks "$GH_LOG" "release upload"
check "git: нет push" lacks "$GIT_LOG" "push"
check "git: нет commit" lacks "$GIT_LOG" "commit"
check "git: нет tag с именем" lacks "$GIT_LOG" "git tag "
same "--dry-run: HEAD на месте" "$("${G[@]}" rev-parse HEAD)" "$HEAD_BEFORE"
same "--dry-run: origin на месте" "$(/usr/bin/git -C "$ORIGIN" rev-parse main)" "$HEAD_BEFORE"
same "--dry-run: теги origin на месте" "$(ORIGIN_TAGS)" "$TAGS_BEFORE"
same "--dry-run: каталог на месте" "$(shasum -a 256 "$FX/Catalog/catalog.json")" "$CATALOG_BEFORE"
same "--dry-run: дерево чисто" "$("${G[@]}" status --porcelain)" ""
for step in "определение изменений" "проверки, 4 шт." "сборка -O" "выкладка" "всего"; do
  check "время: $step" has "$PLAN" "$step"
done
NEW_CATALOG="$(sed -n 's/^Каталог: //p' "$PLAN")"
same "новый каталог: версия" "$(plutil -extract apps.0.version raw -o - "$NEW_CATALOG")" 1.1.1
same "новый каталог: заметки" "$(plutil -extract apps.0.notes.1 raw -o - "$NEW_CATALOG")" "Вторая"

echo "== красная проверка: выпуска нет"
clear_logs
status=0; output="$(EXTRA_ENV=FAKE_RED=run-mixer-wire-check fix mixer "${NOTE[@]}" --dry-run)" || status=$?
check "код не 0" test "$status" -ne 0
check "названа красная" grep -qF "Красные проверки: run-mixer-wire-check" <<<"$output"
same "сборки не было" "$(cat "$RELEASE_MARK")" ""
check "все проверки успели отработать" test "$(wc -l < "$CHECK_LOG" | tr -d ' ')" -eq 4

echo "== порядок и аргументы"
args_refused() { # описание, текст, аргументы
  local what="$1" pattern="$2" output status=0
  shift 2
  clear_logs
  output="$(fix "$@")" || status=$?
  if [ "$status" -ne 0 ] && grep -qF -- "$pattern" <<<"$output" && [ ! -s "$CHECK_LOG" ] && [ ! -s "$RELEASE_MARK" ]; then pass "$what"; else bad "$what (код $status): $output"; fi
}
args_refused "обхода проверок нет" "Неизвестный аргумент" mixer "${NOTE[@]}" --skip-checks
args_refused "опечатка в --dry-run не выкладывает" "--dryrun" mixer "${NOTE[@]}" --dryrun
args_refused "--note не съедает --dry-run" "--note" mixer --note --dry-run
args_refused "без заметок нет выпуска" "Нет заметок" mixer --dry-run
args_refused "длинная заметка: отказ до проверок" "длиннее" mixer --note "$(printf 'ы%.0s' $(seq 1 201))" --dry-run
args_refused "перевод строки в заметке: отказ до проверок" "управляющий" mixer --note $'две\nстроки' --dry-run
args_refused "нет такой утилиты" "Нет такой утилиты" nosuch "${NOTE[@]}" --dry-run
echo untracked > "$FX/untracked"
args_refused "грязное дерево: отказ" "незакоммиченные" mixer "${NOTE[@]}" --dry-run
rm "$FX/untracked"
"${G[@]}" commit -q --allow-empty -m ahead
args_refused "HEAD впереди origin/main: порядок в тексте" "правка влита в main, git push" mixer "${NOTE[@]}" --dry-run
"${G[@]}" reset -q --hard HEAD~1
check "gh release create не вызывался" lacks "$GH_LOG" "release create"

echo "== настоящий путь на локальном origin и подставном gh"
commit_change Sources/Modules/Mixer/MixerController.swift
clear_logs
status=0; output="$(fix mixer "${NOTE[@]}")" || status=$?
if [ "$status" -ne 0 ]; then bad "настоящий путь упал: $output"; fi
check "gh release create вызван с новым тегом" has "$GH_LOG" "release create mixer-v1.1.1"
check "тег выпуска в origin" grep -qx "mixer-v1.1.1" <<<"$(/usr/bin/git -C "$ORIGIN" tag)"
same "каталог в origin обновлён" "$(/usr/bin/git -C "$FX" show origin/main:Catalog/catalog.json | plutil -extract apps.0.version raw -o - -)" 1.1.1
# Следующая правка той же утилиты: новая база, каталог в разнице не мешает.
clear_logs
status=0; output="$(fix mixer "${NOTE[@]}" --dry-run)" || status=$?
check "сразу после выпуска выпускать нечего" grep -qF "mixer-v1.1.1 в Mixer ничего не менялось" <<<"$output"
echo "// вторая" >> "$FX/Sources/Modules/Mixer/MixerController.swift"
"${G[@]}" commit -q -am "вторая правка"
"${G[@]}" push -q origin main
clear_logs
status=0; output="$(fix mixer "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -eq 0 ]; then pass "вторая правка: каталог в разнице не мешает"; else bad "вторая правка: $output"; fi
same "вторая правка: версия ещё на патч выше" "$(cut -d' ' -f3 "$RELEASE_MARK")" 1.1.2

echo "== лаунчер: scripts/fix.sh hub"
HUB_CHECKS="$(fix_checks_of hub) $FIX_COMMON_CHECKS"
hub_refused() { # описание, текст в выводе, файлы правки
  local what="$1" pattern="$2" output status=0
  shift 2
  commit_change "$@"
  clear_logs
  output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
  if [ "$status" -eq 0 ]; then bad "${what}: прошло"; echo "$output"
  elif ! grep -qF -- "$pattern" <<<"$output"; then bad "${what}: нет «${pattern}»"; echo "$output"
  elif [ -s "$CHECK_LOG" ] || [ -s "$RELEASE_MARK" ]; then bad "${what}: отказ после проверок или сборки"
  else pass "$what"; fi
}
hub_refused "лаунчер, Kit: отказ" "Kit входит в сборку" Sources/Kit/Theme.swift
hub_refused "лаунчер, Kit: обычный путь" "scripts/release-all.sh" Sources/Kit/KitSigning.swift
hub_refused "лаунчер, свой файл и Kit: отказ" "Kit входит в сборку" Sources/App/UtilitumusApp.swift Sources/Kit/Theme.swift
hub_refused "лаунчер, утилита: отказ" "код утилиты mixer" Sources/Modules/Mixer/MixerController.swift
hub_refused "лаунчер, Apps утилиты: отказ" "код утилиты awake" Sources/Apps/Awake/manifest.json
hub_refused "лаунчер, помощник: отказ" "помощник утилиты" Sources/VoiceHelper/main.c
hub_refused "лаунчер, Shared: отказ" "общий код вентиляторов" Sources/Shared/SMC.swift
hub_refused "лаунчер, договор связи: отказ" "договор связи" Sources/Modules/Mixer/UI/MixerWire.swift
hub_refused "лаунчер, скрипт сборки утилит: отказ" "этим собирается" scripts/release-app.sh
hub_refused "лаунчер, неизвестный файл: отказ" "не файл лаунчера" Новый/файл.txt
hub_refused "лаунчер, только проверки: выпускать нечего" "выпускать нечего" Tests/run-sidebar-check.sh
# Перенос из Kit в экран не прячется за новым именем.
"${G[@]}" reset -q --hard "$BASE"
"${G[@]}" mv Sources/Kit/KitSigning.swift Sources/Modules/Mixer/UI/KitSigning.swift
"${G[@]}" commit -q -m "перенос"
"${G[@]}" push -q -f origin main
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -ne 0 ] && grep -qF "Kit входит в сборку" <<<"$output"; then pass "лаунчер, перенос из Kit: отказ"; else bad "перенос из Kit в лаунчере прошёл: $output"; fi

# Правка лаунчера: проходит, --dry-run проверяет, собирает с новой версией и записью и ничего не меняет.
commit_change Sources/App/UtilitumusApp.swift
clear_logs
HEAD_BEFORE="$("${G[@]}" rev-parse HEAD)"
PLAN="$OUT/hub-plan.txt"
fix hub --note "Первая" --note "Вторая" --dry-run > "$PLAN" 2>&1 || { cat "$PLAN"; bad "hub --dry-run упал"; }
same "лаунчер: проверки из таблицы" "$(LC_ALL=C sort "$CHECK_LOG" | tr '\n' ' ')" "$(printf '%s\n' $HUB_CHECKS | LC_ALL=C sort | tr '\n' ' ')"
NEXT="${HUB%.*}.$(( ${HUB##*.} + 1 ))"
same "лаунчер: сборка видит версию и запись" "$(cat "$RELEASE_MARK")" "hub-build $NEXT $NEXT Первая"
check "лаунчер: нет предупреждения про экран" lacks "$PLAN" "компилируется и в окно утилиты"
check "лаунчер: план коммита версии" has "$PLAN" "+ git commit -q -m Версия $NEXT"
check "лаунчер: план пуша main" has "$PLAN" "+ git push -q origin HEAD:main"
check "лаунчер: план тега" has "$PLAN" "+ git tag v$NEXT"
check "лаунчер: план релиза с Latest" has "$PLAN" "--latest=true"
check "лаунчер: gh release create только напечатан" lacks "$GH_LOG" "release create"
check "лаунчер: git без push" lacks "$GIT_LOG" "push"
check "лаунчер: git без commit" lacks "$GIT_LOG" "commit"
check "лаунчер: git без tag" lacks "$GIT_LOG" "git tag "
same "лаунчер --dry-run: HEAD на месте" "$("${G[@]}" rev-parse HEAD)" "$HEAD_BEFORE"
same "лаунчер --dry-run: origin на месте" "$(/usr/bin/git -C "$ORIGIN" rev-parse main)" "$HEAD_BEFORE"
same "лаунчер --dry-run: версия на месте" "$(plutil -extract CFBundleShortVersionString raw -o - "$FX/Info.plist")" "$HUB"
same "лаунчер --dry-run: дерево чисто (версия и запись откатились)" "$("${G[@]}" status --porcelain)" ""
for step in "определение изменений" "проверки, $(echo $HUB_CHECKS | wc -w | tr -d ' ') шт." "сборка -O" "выкладка" "всего"; do
  check "лаунчер, время: $step" has "$PLAN" "$step"
done

# Экран утилиты компилируется и в лаунчер: проходит с предупреждением, если утилита ещё не выпустила эту правку.
commit_change Sources/Modules/Mixer/UI/MixerView.swift
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -eq 0 ] && grep -qF "компилируется и в окно утилиты" <<<"$output" && grep -qF "Sources/Modules/Mixer/UI/MixerView.swift" <<<"$output"; then
  pass "лаунчер, экран: проходит с предупреждением"
else
  bad "лаунчер, экран (код $status): $output"
fi
"${G[@]}" tag -f mixer-v1.1.0 HEAD >/dev/null
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -eq 0 ] && ! grep -qF "компилируется и в окно утилиты" <<<"$output"; then pass "лаунчер, экран уже в выпуске утилиты: без предупреждения"; else bad "лаунчер, экран выпущен (код $status): $output"; fi
"${G[@]}" tag -f mixer-v1.1.0 "$BASE" >/dev/null

# Утилита уже выпустила свою правку своим выпуском: лаунчеру она не мешает.
commit_change Sources/App/UtilitumusApp.swift Sources/Modules/Mixer/MixerController.swift
"${G[@]}" tag -f mixer-v1.1.0 HEAD >/dev/null
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -eq 0 ]; then pass "лаунчер, выпущенная правка утилиты: не мешает"; else bad "лаунчер, выпущенная утилита: $output"; fi
"${G[@]}" tag -f mixer-v1.1.0 "$BASE" >/dev/null

echo "== лаунчер: порядок и красные проверки"
commit_change Sources/App/UtilitumusApp.swift
clear_logs
status=0; output="$(EXTRA_ENV=FAKE_RED=run-sidebar-check fix hub "${NOTE[@]}" --dry-run)" || status=$?
check "лаунчер, красная: код не 0" test "$status" -ne 0
check "лаунчер, красная: названа" grep -qF "Красные проверки: run-sidebar-check" <<<"$output"
same "лаунчер, красная: сборки не было" "$(cat "$RELEASE_MARK")" ""
check "лаунчер, красная: все проверки успели отработать" test "$(wc -l < "$CHECK_LOG" | tr -d ' ')" -eq "$(echo $HUB_CHECKS | wc -w | tr -d ' ')"
check "лаунчер, красная: коммитов и тегов нет" lacks "$GIT_LOG" "commit"
same "лаунчер, красная: дерево чисто" "$("${G[@]}" status --porcelain)" ""
clear_logs
status=0; output="$(fix hub --dry-run)" || status=$?
if [ "$status" -ne 0 ] && grep -qF "Нет заметок" <<<"$output" && [ ! -s "$CHECK_LOG" ] && [ ! -s "$RELEASE_MARK" ]; then pass "лаунчер без заметки: отказ до проверок"; else bad "лаунчер без заметки (код $status): $output"; fi
clear_logs
status=0; output="$(fix hub --note --dry-run)" || status=$?
if [ "$status" -ne 0 ] && grep -qF "После --note" <<<"$output" && [ ! -s "$CHECK_LOG" ]; then pass "лаунчер: --note не съедает --dry-run"; else bad "лаунчер --note --dry-run (код $status): $output"; fi
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --skip-checks)" || status=$?
if [ "$status" -ne 0 ] && grep -qF "Неизвестный аргумент" <<<"$output" && [ ! -s "$CHECK_LOG" ] && [ ! -s "$RELEASE_MARK" ]; then pass "лаунчер: обхода проверок нет"; else bad "лаунчер --skip-checks (код $status): $output"; fi
"${G[@]}" commit -q --allow-empty -m ahead
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -ne 0 ] && grep -qF "правка влита в main, git push" <<<"$output" && [ ! -s "$CHECK_LOG" ]; then pass "лаунчер: HEAD впереди origin/main, порядок в тексте"; else bad "лаунчер HEAD впереди (код $status): $output"; fi
"${G[@]}" reset -q --hard HEAD~1
# Запись для новой версии уже лежит: выпуск не должен дописывать вторую.
"${G[@]}" reset -q --hard "$BASE"
sed -i '' "s/\"version\": \"$HUB\"/\"version\": \"$NEXT\"/" "$FX/Resources/WhatsNew.json"
echo "// правка" >> "$FX/Sources/App/UtilitumusApp.swift"
"${G[@]}" commit -q -am "запись уже есть"
"${G[@]}" push -q -f origin main
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
if [ "$status" -ne 0 ] && grep -qF "уже есть запись для $NEXT" <<<"$output" && [ ! -s "$CHECK_LOG" ]; then pass "лаунчер: готовая запись версии: отказ до проверок"; else bad "лаунчер готовая запись (код $status): $output"; fi

echo "== лаунчер: настоящий путь на локальном origin и подставном gh"
commit_change Sources/App/UtilitumusApp.swift
clear_logs
status=0; output="$(fix hub --note "Исправлено: окно" --note "Ещё одно")" || status=$?
if [ "$status" -ne 0 ]; then bad "лаунчер, настоящий путь упал: $output"; fi
check "лаунчер: gh release create с новым тегом и Latest" has "$GH_LOG" "release create v$NEXT build/Utilitumus.zip"
check "лаунчер: релиз с Latest" has "$GH_LOG" "--latest=true"
check "лаунчер: тег в origin" grep -qx "v$NEXT" <<<"$(/usr/bin/git -C "$ORIGIN" tag)"
same "лаунчер: в origin версия в Info.plist" "$(/usr/bin/git -C "$FX" show origin/main:Info.plist | plutil -extract CFBundleShortVersionString raw -o - -)" "$NEXT"
same "лаунчер: в origin запись сверху" "$(/usr/bin/git -C "$FX" show origin/main:Resources/WhatsNew.json | plutil -extract 0.items.1 raw -o - -)" "Ещё одно"
same "лаунчер: прежняя запись на месте" "$(/usr/bin/git -C "$FX" show origin/main:Resources/WhatsNew.json | plutil -extract 1.version raw -o - -)" "$HUB"
same "лаунчер: сборка видела версию и запись" "$(cut -d' ' -f1-3 "$RELEASE_MARK")" "hub-build $NEXT $NEXT"
same "лаунчер: тег указывает на origin/main" "$(/usr/bin/git -C "$ORIGIN" rev-parse "v$NEXT^{commit}")" "$(/usr/bin/git -C "$ORIGIN" rev-parse main)"
same "лаунчер: после выпуска дерево чисто" "$("${G[@]}" status --porcelain)" ""
clear_logs
status=0; output="$(fix hub "${NOTE[@]}" --dry-run)" || status=$?
check "лаунчер: сразу после выпуска выпускать нечего" grep -qF "ничего не менялось" <<<"$output"

if [ "$fails" -ne 0 ]; then
  echo "Провалов: $fails"
  exit 1
fi
rm -rf "$OUT"
echo "scripts/fix.sh: OK"
