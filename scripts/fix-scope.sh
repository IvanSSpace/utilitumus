# Для scripts/fix.sh и Tests/run-fix-script-check.sh, подключается через `.` после scripts/dev-scope.sh: можно ли выпустить
# правку одной утилитой и какие проверки её касаются. Нужны APPS (id:Имя через пробел) и текущая папка в корне репозитория.

# Проверки утилиты. Берём те, что собирают или запускают сам модуль (run-<id>-* и смотрящие в его исходники):
# run-tool-spawn и run-own-identity читают Sources/Modules/Load, run-own-identity ещё и Stash, run-fn-restore — InputSources.swift.
# run-seam-check здесь не нужен: он проверяет механизм шва (Kit, build-app.sh, check-no-seam.sh), а их правка и так отказ;
# следы шва в самом бандле ищет release-app.sh. run-stand-isolation-check остаётся полному прогону: его снимок настоящих мест
# может покраснеть от настоящих работающих утилит, а обхода здесь нет. Во время стенда охраняет Kit.assertStandPath.
fix_checks_of() {
  case "$1" in
    awake) echo run-awake-app-check run-awake-remote-check run-awake-settings-check ;;
    bots) echo run-bots-remote-check ;;
    browser) echo run-browser-routing-check run-browser-link-handler-check run-browser-remote-check ;;
    clipboard) echo run-clipboard-check run-clipboard-key-check run-clipboard-remote-check run-clipboard-wire-check ;;
    fans) echo run-fan-gate-check run-fan-helper-check run-fan-version-check run-fans-remote-check run-fans-wire-check ;;
    keyboard) echo run-fn-restore-check run-keyboard-remote-check run-keyboard-wire-check ;;
    load) echo run-load-remote-check run-load-safety-check run-load-wire-check run-own-identity-check run-tool-spawn-check ;;
    mixer) echo run-mixer-remote-check run-mixer-wire-check ;;
    mouse) echo run-mouse-remote-check run-mouse-wire-check ;;
    sound) echo run-sound-remote-check run-sound-wire-check ;;
    stash) echo run-own-identity-check run-stash-module-check run-stash-remote-check run-stash-title-check run-stash-wire-check ;;
    voice) echo run-voice-remote-check run-voice-remote-pure-check run-voice-security-check run-voice-wire-check ;;
    # Лаунчер (fix.sh hub): оболочка и следы утилит в ней, боковая панель, дашборд и меню-бар, значки меню (раздел настроек), Стор,
    # обновление центра и утилит, следы шва в бандле. Окна настроек целиком проверкой не охвачено: menu-icons снимает раздел «Значки в меню»,
    # auto-update — раздел «Обновления».
    hub) echo run-hub-shell-check run-sidebar-check run-dashboard-routing-check run-menu-icons-check run-store-catalog-check run-update-bundle-check run-update-all-check run-auto-update-check run-seam-check ;;
    *) return 1 ;;
  esac
}
# Для всех: одна секунда на grep, а настройка мимо Kit.defaults выглядит у человека как потеря настроек.
FIX_COMMON_CHECKS="run-module-defaults-guard"

fix_catalog_version() { # id; пусто, если записи нет
  /usr/bin/python3 -I -c '
import json, sys
catalog = json.load(open("Catalog/catalog.json", encoding="utf-8"))
print(next((a["version"] for a in catalog["apps"] if a["id"] == sys.argv[1]), ""))' "$1"
}

fix_next_patch() { # версия; 1.1 и 1.1.0 дают 1.1.1
  /usr/bin/python3 -I -c '
import sys
parts = [int(x) for x in sys.argv[1].split(".")]
parts += [0] * (3 - len(parts))
parts[-1] += 1
print(".".join(map(str, parts)))' "$1"
}

# Файл такой же, как в этом выпуске: чужая правка уже у людей, этому выпуску она не мешает.
fix_released_in() { # тег, файл
  git rev-parse -q --verify "refs/tags/$1" >/dev/null && git diff --quiet "$1" HEAD -- "$2"
}

# Список изменённых файлов на входе. FIX_OWN — файлы этой утилиты, FIX_SKIPPED — не мешают выпуску,
# FIX_REFUSED — «файл — почему нельзя». HUB_TAG — тег выпущенного центра.
# Неизвестное — отказ: новый файл, который мог бы войти в сборку, не должен пройти молча.
fix_classify() { # id
  local id="$1" file owner version
  FIX_OWN=(); FIX_SKIPPED=(); FIX_REFUSED=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      # В бандл утилиты это не входит (scripts/build-app.sh читает только свои папки, Kit и манифест). Каталог меняет каждый выпуск,
      # а проверки и скрипты разработки — почти каждая ветка: иначе отказ был бы всегда, вплоть до общего выпуска.
      Catalog/catalog.json | README.md | docs/* | Tests/* | .github/* | .gitignore | \
        scripts/dev.sh | scripts/dev-scope.sh | scripts/fix.sh | scripts/fix-scope.sh | scripts/release-all.sh | scripts/release.sh | \
        scripts/build-pilot.sh | scripts/test-app-layout.sh | scripts/test-fn-tap.sh | scripts/list-layouts/*)
        FIX_SKIPPED+=("$file") ;;
      Sources/Kit/*) FIX_REFUSED+=("$file — Kit входит в сборку всех утилит и центра") ;;
      Sources/Shared/*) FIX_REFUSED+=("$file — общий код вентиляторов, он есть и в службе, и в центре") ;;
      Sources/FanHelper/*) FIX_REFUSED+=("$file — служба вентиляторов выходит вместе с центром") ;;
      scripts/*) FIX_REFUSED+=("$file — этим собирается и выпускается каждая утилита") ;;
      Sources/App/Satellites/Remote*)
        if fix_released_in "$HUB_TAG" "$file"; then
          FIX_SKIPPED+=("$file")
        elif owner="$(dev_scope_screen_owner "$file")"; then
          FIX_REFUSED+=("$file — экран ${owner} в лаунчере: нужен и выпуск лаунчера")
        else
          FIX_REFUSED+=("$file — общий код экранов в лаунчере: нужен и выпуск лаунчера")
        fi ;;
      Sources/App/* | Info.plist | build.sh | install.sh | Resources/* | local.utilitumus.plist)
        if fix_released_in "$HUB_TAG" "$file"; then
          FIX_SKIPPED+=("$file")
        else
          FIX_REFUSED+=("$file — это лаунчер, в выпуске ${HUB_TAG} такого ещё нет")
        fi ;;
      Sources/Apps/*/* | Sources/Modules/*/* | Sources/VoiceHelper/* | Sources/LinkHelper/*)
        dev_scope_classify <<<"$file"
        owner="${PICK[0]:-}"
        if [ "$owner" = "$id" ]; then
          case "$file" in
            # Состояние и действия этого файла читает своей копией центр, а сверка копий двух сторон ни одной проверкой не видна:
            # стенды собирают обе стороны из одного дерева.
            *Wire.swift) FIX_REFUSED+=("$file — договор связи с лаунчером: нужен и выпуск лаунчера") ;;
            *) FIX_OWN+=("$file") ;;
          esac
        elif [ -z "$owner" ]; then
          FIX_REFUSED+=("$file — ничей файл")
        else
          version="$(fix_catalog_version "$owner")"
          if [ -n "$version" ] && fix_released_in "$owner-v$version" "$file"; then
            FIX_SKIPPED+=("$file")
          else
            FIX_REFUSED+=("$file — правка чужой утилиты ${owner}, ещё не выпущена")
          fi
        fi ;;
      *) FIX_REFUSED+=("$file — не файл этой утилиты") ;;
    esac
  done
}

# Правка лаунчера (scripts/fix.sh hub): то же, что fix_classify, но своё у лаунчера — то, что собирает scripts/hub-sources.sh
# (Sources/App и экраны Sources/Modules/*/UI) и build.sh. Kit, Shared, помощники, код утилит и договор связи — отказ.
# FIX_SCREENS — экраны утилит из Sources/Modules/*/UI, которых нет в выпуске утилиты: лаунчер их получит, окно утилиты нет.
fix_classify_hub() {
  local file owner version
  FIX_OWN=(); FIX_SKIPPED=(); FIX_REFUSED=(); FIX_SCREENS=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      Catalog/catalog.json | README.md | docs/* | Tests/* | .github/* | .gitignore | \
        scripts/dev.sh | scripts/dev-scope.sh | scripts/fix.sh | scripts/fix-scope.sh | scripts/release-all.sh | scripts/release.sh | \
        scripts/build-pilot.sh | scripts/test-app-layout.sh | scripts/test-fn-tap.sh | scripts/list-layouts/*)
        FIX_SKIPPED+=("$file") ;;
      Sources/Kit/*) FIX_REFUSED+=("$file — Kit входит в сборку всех утилит и лаунчера") ;;
      Sources/Shared/*) FIX_REFUSED+=("$file — общий код вентиляторов, он есть и в службе, и в лаунчере") ;;
      Sources/FanHelper/* | Sources/VoiceHelper/* | Sources/LinkHelper/*) FIX_REFUSED+=("$file — помощник утилиты: выходит вместе с ней") ;;
      Sources/Modules/*/UI/*Wire.swift) FIX_REFUSED+=("$file — договор связи с утилитой: нужен и выпуск утилиты") ;;
      Sources/Modules/*/UI/*)
        FIX_OWN+=("$file")
        dev_scope_classify <<<"$file"
        owner="${PICK[0]:-}"
        version=""
        [ -z "$owner" ] || version="$(fix_catalog_version "$owner")"
        if [ -z "$version" ] || ! fix_released_in "$owner-v$version" "$file"; then FIX_SCREENS+=("$file"); fi ;;
      Sources/App/* | Info.plist | build.sh | install.sh | Resources/* | local.utilitumus.plist | \
        scripts/hub-sources.sh | scripts/check-no-seam.sh | scripts/unlock-signing.sh)
        FIX_OWN+=("$file") ;;
      scripts/*) FIX_REFUSED+=("$file — этим собирается и выпускается каждая утилита") ;;
      Sources/Apps/*/* | Sources/Modules/*/*)
        dev_scope_classify <<<"$file"
        owner="${PICK[0]:-}"
        version=""
        [ -z "$owner" ] || version="$(fix_catalog_version "$owner")"
        if [ -n "$version" ] && fix_released_in "$owner-v$version" "$file"; then
          FIX_SKIPPED+=("$file")
        else
          FIX_REFUSED+=("$file — код утилиты ${owner:-без владельца}, ещё не выпущен её выпуском")
        fi ;;
      *) FIX_REFUSED+=("$file — не файл лаунчера") ;;
    esac
  done
}

# Вкладку в лаунчере рисует сам центр своей копией экрана (RemoteMixerPage → MixerView): в выпуск утилиты правка попадёт,
# но вкладка покажет её только после выпуска центра.
fix_screen_files() { # файлы
  local file
  for file in "$@"; do
    case "${file##*/}" in
      *View*.swift | *Views.swift | *Screen*.swift | *Tab.swift | *Sheet.swift | *Chart.swift | *Sections.swift | *Components.swift | *Panel.swift | *Preview.swift) echo "$file" ;;
    esac
  done
}
