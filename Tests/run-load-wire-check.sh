#!/bin/bash
# «Нагрузка» перед переносом: состояние и действия через JSON, отказы, экран на состоянии из JSON. Движок и исполнители
# подставные: ничего не останавливается и не запускается, настоящие load-history.json и actions.log не пишутся.
# Настройки в своём suite. Окно за экраном и прозрачное. Папка стенда: LOAD_WIRE_DIR, иначе $TMPDIR/load-wire-check.
#   без аргументов     логика и снимки: встроенный экран против экрана на состоянии из JSON
#   baseline <коммит>  встроенный экран до подготовки против нынешнего, пиксель в пиксель
#   mutate             поломки проверок в копии исходников: каждую должны поймать отказы
#   measure            размер и время настоящего состояния на этом Mac, сборка -O. Только чтение: процессы, launchctl list
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-check}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${LOAD_WIRE_DIR:-${TMPDIR:-/tmp}/load-wire-check}"
SUITE="local.utilitumus.test.load-wire"
FRAMEWORKS=(-framework SwiftUI -framework AppKit -framework Charts)

cleanup() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
trap cleanup EXIT
mkdir -p "$OUT"
# Инкрементальная сборка только у обычного режима: кэш вне папки стенда. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache load-wire KIT_TEST_DEFAULTS)"

# Свой suite вместо общего для стендов: другой стенд в это время может менять тему.
kit_sources() {
  local root="$1" dest="$2"
  mkdir -p "$dest"
  # Файл с тем же содержимым сохраняет время изменения и не перекомпилируется зря.
  sed "s/local.utilitumus.test.kit/$SUITE/" "$root/Sources/Kit/KitDefaults.swift" > "$dest/KitDefaults.swift.new"
  cmp -s "$dest/KitDefaults.swift.new" "$dest/KitDefaults.swift" || cp "$dest/KitDefaults.swift.new" "$dest/KitDefaults.swift"
  rm -f "$dest/KitDefaults.swift.new"
  find "$root/Sources/Kit" -name '*.swift' -not -name KitDefaults.swift -print
  echo "$dest/KitDefaults.swift"
  echo "$root/Sources/App/Design/Pages.swift"
}

build_full() { # корень исходников, папка, выход, флаги
  local root="$1" dir="$2" exe="$3"; shift 3
  mkdir -p "$dir"
  # Иначе при ошибке сборки ниже остался бы и прошёл проверку файл прошлого запуска: вывод swiftc здесь отфильтрован.
  rm -f "$exe"
  cmp -s Tests/LoadWireCheck.swift "$dir/LoadWireCheck.swift" || cp Tests/LoadWireCheck.swift "$dir/LoadWireCheck.swift"
  local files=("$dir/LoadWireCheck.swift") f
  while IFS= read -r f; do files+=("$f"); done < <({ kit_sources "$root" "$dir/kit"; find "$root/Sources/Modules/Load" -name '*.swift'; } | sort)
  # С флагами (-O замера, -D LOAD_BASELINE) сборка целиком: -O инкрементально не собирают, а база нужна редко.
  INC_FLAGS=()
  [ "$#" -gt 0 ] || incremental_flags "$CACHE" "${files[@]}"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS "$@" -module-name LoadWireCheck -o "$exe" \
    "${files[@]}" "${FRAMEWORKS[@]}" 2>&1 | grep -E 'error|^<unknown>' || true
  [ -x "$exe" ] || { echo "ПРОВАЛ: не собралось"; exit 1; }
}

build_logic() { # папка модуля Load, выход
  local load="$1" exe="$2" L="$1/Native"
  rm -f "$exe"
  cp Tests/LoadWireCheck.swift "$OUT/LoadWireCheck-logic.swift"
  # Команды ботов и ответ утилиты живут в Kit: логика без него не собирается, поломки его не копируют.
  swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -D LOAD_LOGIC_ONLY -o "$exe" "$OUT/LoadWireCheck-logic.swift" \
    $(kit_sources . "$OUT/logic-kit") $(find "$L/Core" -name '*.swift') "$L/Background/BackgroundActions.swift" "$L/Background/BotStatus.swift" \
    "$L/Background/LaunchAgents.swift" "$L/Background/BackgroundStore.swift" "$L/Sessions/MuxProbe.swift" "$L/Sessions/SessionModels.swift" \
    "$L/Sessions/SessionsBuilder.swift" "$L/Sessions/Transcripts.swift" "$L/Sessions/SessionStop.swift" "$L/LoadStore.swift" \
    "$L/LoadSnapshotKey.swift" "$L/LoadPalette.swift" "$load/LoadModel.swift" "$load/LoadWire.swift" -framework SwiftUI -framework AppKit 2>&1 | grep -E 'error' || true
  [ -x "$exe" ]
}

case "$MODE" in
check)
  build_full . "$CACHE/src" "$OUT/check"
  "$OUT/check" logic
  rm -rf "$OUT/png-new" "$OUT/png-remote"; mkdir -p "$OUT/png-new" "$OUT/png-remote"
  cleanup
  "$OUT/check" render "$OUT/png-new"
  cleanup
  "$OUT/check" render-remote "$OUT/png-remote"
  "$OUT/check" diff "$OUT/png-new" "$OUT/png-remote"
  ;;
baseline)
  COMMIT="${2:?нужен коммит}"
  [ -x "$OUT/check" ] || build_full . "$CACHE/src" "$OUT/check"
  BASE="$OUT/base"
  rm -rf "$BASE"; mkdir -p "$BASE"
  /usr/bin/git archive "$COMMIT" Sources | tar -x -C "$BASE"
  # До подготовки подставить данные нечем: копия читает их у стенда, больше в ней ничего не меняется.
  L="$BASE/Sources/Modules/Load/Native"
  sed -i '' 's/BackgroundCollector.collect(s)/loadTestBackground()/; s/ActionLog.recent()/loadTestJournal()/g' "$L/Background/BackgroundStore.swift"
  sed -i '' 's/@Published private(set) var history/@Published var history/' "$L/LoadStore.swift"
  build_full "$BASE" "$OUT/base-build" "$OUT/base-check" -D LOAD_BASELINE
  rm -rf "$OUT/png-base" "$OUT/png-new"; mkdir -p "$OUT/png-base" "$OUT/png-new"
  cleanup
  "$OUT/base-check" render "$OUT/png-base"
  cleanup
  "$OUT/check" render "$OUT/png-new"
  "$OUT/check" diff "$OUT/png-base" "$OUT/png-new"
  ;;
mutate)
  SRC=Sources/Modules/Load
  M="$OUT/mut"
  caught=0; missed=0
  mutation() { # файл относительно модуля, что заменить, на что, имя
    rm -rf "$M"; mkdir -p "$M"; cp -R "$SRC/" "$M/"
    /usr/bin/python3 -I - "$M/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) < 1:
    sys.exit("нет строки: " + old)
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
    if ! build_logic "$M" "$OUT/mut-check"; then echo "ПРОВАЛ: поломка «$4» не собралась"; exit 1; fi
    if "$OUT/mut-check" logic > "$OUT/mut.log" 2>&1; then
      echo "FAIL поломку не поймали: $4"; missed=$((missed + 1))
    else
      echo "ok   поймана: $4 ($(grep -c '^FAIL' "$OUT/mut.log" || true) провалов, первый: $(grep -m1 '^FAIL' "$OUT/mut.log" | cut -c1-90))"; caught=$((caught + 1))
    fi
  }
  build_logic "$SRC" "$OUT/mut-check"
  "$OUT/mut-check" logic > "$OUT/mut.log" 2>&1 || { echo "ПРОВАЛ: без поломок логика не проходит"; grep '^FAIL' "$OUT/mut.log"; exit 1; }
  echo "ok   без поломок логика проходит"
  mutation LoadWire.swift 'guard let shown = measure, shown.offers(target) else {' 'guard measure != nil else {' "цель не сверяется с экраном"
  mutation LoadWire.swift 'guard target.rows.allSatisfy({ latest?.procs[$0.pid]?.uniqueID == $0.uniqueID }) else {' 'guard true else {' "uniqueID не сверяется со свежим замером"
  mutation LoadWire.swift '$0.rowID == id && $0.stoppable && !$0.isSelf' '$0.rowID == id' "текущую сессию можно остановить"
  mutation LoadWire.swift 'groups.contains { $0.members.contains { $0.rowID == id && $0.stoppable } }' 'groups.contains { $0.members.contains { $0.rowID == id } }' "строка без кнопки принимается"
  mutation LoadWire.swift 'guard pendingStop?.id == planID else { return "Подтверждение устарело — попробуй ещё раз" }' 'guard pendingStop != nil else { return "Подтверждение устарело — попробуй ещё раз" }' "подтверждение остановки не сверяет id плана"
  mutation LoadWire.swift 'guard pending?.id == planID else { return "Подтверждение устарело — попробуй ещё раз" }' 'guard pending != nil else { return "Подтверждение устарело — попробуй ещё раз" }' "подтверждение фонового не сверяет id плана"
  mutation Native/LoadStore.swift 'guard let plan = pendingStop, plan.id == planID, !stopRunning else { return }' 'guard let plan = pendingStop, !stopRunning else { return }' "модель выполняет план с чужим id"
  mutation Native/Background/BackgroundStore.swift 'guard let plan = pending, plan.id == planID, !running else { return }' 'guard let plan = pending, !running else { return }' "модель фонового выполняет план с чужим id"
  mutation LoadWire.swift 'agent.verbs.contains(verb) else' 'true else' "действие агента, которого нет на кнопках"
  mutation LoadWire.swift 'bot.actions.contains(verb) else' 'true else' "действие бота, которого нет на кнопках"
  mutation Native/Background/BackgroundActions.swift 'if case .argv(let argv)? = spec.commands[verb] { shown = argv }' 'if case .argv(let argv)? = BotRegistry.load().first(where: { $0.id == spec.id })?.commands[verb] { shown = argv }' "команда бота сверяется с файлом, а не с показанной"
  mutation Native/Background/BackgroundActions.swift '{ shown = argv }' '{ shown = argv } else if case .argv(let argv)? = BotRegistry.load().first(where: { $0.id == spec.id })?.commands[verb] { shown = argv }' "план без команды запускает то, чего человек не видел"
  mutation Native/Background/BackgroundActions.swift 'cmd = BotRunner.shown(argv)' 'cmd = Exec.display(argv)' "команда в вопросе бота не очищена"
  mutation Native/Background/BackgroundActions.swift 'message: ScreenText.clean((cmd.isEmpty ? "Выполнит команду из bots.toml." : "Выполнит \(cmd).") + (b.spec.note.isEmpty ? "" : " \(b.spec.note)"), BotRunner.maxShown),' 'message: (cmd.isEmpty ? "Выполнит команду из bots.toml." : "Выполнит \(cmd).") + (b.spec.note.isEmpty ? "" : " \(b.spec.note)"),' "текст вопроса бота не очищен"
  mutation LoadWire.swift 'guard label.utf8.count <= LoadStore.maxIDBytes else { return "Непонятная команда" }' '' "длина метки не ограничена"
  mutation LoadWire.swift 'guard !stopRunning else { return "Остановка уже идёт" }
            guard pendingStop?.id' 'guard pendingStop?.id' "второе подтверждение во время остановки"
  mutation Native/Core/LoadHistory.swift 'guard claimWriter() else {' 'guard true || claimWriter() else {' "второй писатель истории"
  mutation Native/Background/BotStatus.swift 'name: ScreenText.clean(spec.name, BotRunner.maxShown), state' 'name: spec.name, state' "имя бота в строке без очистки"
  mutation LoadWire.swift 'guard watchers < Self.maxWatchers else { return "Экран и так открыт" }' '' "открытия экрана без предела"
  mutation LoadWire.swift 'for i in m.sessions.claude.indices { m.sessions.claude[i].activity.lastPromptTS = nil }' '' "состояние не приведено к связи"
  rm -rf "$M"
  echo "поймано $caught, не поймано $missed"
  [ "$missed" -eq 0 ]
  ;;
measure)
  build_full . "$OUT/measure-build" "$OUT/measure" -O
  HISTORY="$OUT/history-copy.json"
  rm -f "$HISTORY"
  REAL="$HOME/Library/Application Support/Utilitumus/load-history.json"
  [ -f "$REAL" ] && cp "$REAL" "$HISTORY"
  "$OUT/measure" measure "$HISTORY"
  rm -f "$HISTORY"
  ;;
*)
  echo "неизвестный режим $MODE"; exit 2 ;;
esac
