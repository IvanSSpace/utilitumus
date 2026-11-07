#!/bin/bash
# «Голос»: состояние, действия, отказы, режим проверки, экран за кадром, встроенный экран до и после правки.
# Без микрофона, горячей клавиши, вставки, сети и настоящих моделей. Папка стенда: VOICE_WIRE_DIR.
# VOICE_WIRE_BASE — коммит для снимков «до»; VOICE_WIRE_NO_BASE=1 — без них, если гит недоступен.
set -euo pipefail
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}"; OUT="${VOICE_WIRE_DIR:-${T%/}/voice-wire-check}"
BASE="${VOICE_WIRE_BASE:-509cdb3}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
CONTROLLER=Sources/Modules/Voice/VoiceController.swift
REAL_MODELS="$HOME/Library/Application Support/Utilitumus/Voice/Models"
# Свой suite вместо общего local.utilitumus.test.kit: стенд пишет настройки в Kit.defaults, а модели лежат в папке по имени suite.
export KIT_TEST_SUITE="local.utilitumus.test.kit.voice-wire"

fail() { echo "ПРОВАЛ: $1"; exit 1; }
real_snapshot() { ls -laT "$REAL_MODELS" 2>/dev/null | shasum; }
cleanup() {
  for name in voice-wire-check voice-wire-base "$KIT_TEST_SUITE"; do
    defaults delete "$name" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$name.plist"
  done
  # Модели стенда (шов KIT_TEST_DEFAULTS) лежат во временной папке, а не в доме.
  rm -rf "${TMPDIR:-/tmp}/utilitumus-test-models/$KIT_TEST_SUITE"
}
trap cleanup EXIT
BEFORE="$(real_snapshot)"

# Вставку в тесте не вызвать: при поломке ушёл бы настоящий ⌘V. Поэтому порядок проверяем по исходнику.
BODY="$(awk '/private func insert\(_ text: String, session: TestSession\?\)/,/^    }$/' "$CONTROLLER")"
[ "$(sed -n 2p <<<"$BODY" | tr -d ' ')" = "ifcaptureTestText(text){" ] || fail "вставка не начинается с режима проверки"
[ "$(sed -n 2,5p <<<"$BODY" | grep -c 'return')" = 1 ] || fail "в режиме проверки вставка не заканчивается сразу"
echo "ok   вставка сначала отдаёт текст режиму проверки и в нём ничего не вставляет"
# Встроенный модуль режим не включает: его модель экрана ничего не делает, включает только действие по связи.
USES="$(grep -rlE 'beginTest\(|\.beginTest' Sources | sort | tr '\n' ' ')"
EXPECTED="Sources/App/Satellites/RemoteVoiceModel.swift Sources/Modules/Voice/VoiceController.swift Sources/Modules/Voice/VoiceScreenModel.swift Sources/Modules/Voice/VoiceView.swift Sources/Modules/Voice/VoiceWire.swift "
[ "$USES" = "$EXPECTED" ] || fail "режим проверки включается ещё где-то: $USES"
grep -qE 'func beginTest\(\) \{\}' Sources/Modules/Voice/VoiceScreenModel.swift || fail "встроенная модель экрана включает режим проверки"
grep -q 'controller.beginTest' Sources/Modules/Voice/VoiceScreenModel.swift && fail "встроенная модель зовёт контроллер"
echo "ok   встроенный модуль режим проверки не включает"
# Экран закрыт или центр пропал (аренда экрана): запись проверки утилиты обрывается.
awk '/func screenOpen\(_ open: Bool\)/,/^    }$/' Sources/Apps/Voice/VoiceModule.swift | grep -q 'controller.endTest()' || fail "закрытие экрана не обрывает запись проверки"
echo "ok   закрытие экрана обрывает запись проверки"

rm -rf "$OUT/src" "$OUT/shots-after" "$OUT/home-run" "$OUT/home-after"
mkdir -p "$OUT/src" "$OUT/shots-after"

sources() {
  find "$1" -name '*.swift' -not -path "$1/FanHelper/*" -not -path "$1/LinkHelper/*" -not -path "$1/Apps/*" -not -name UtilitumusApp.swift
}
# Инкрементальная сборка: у каждой из двух сборок свой кэш с копиями подставных файлов. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
. Tests/lib/incremental-sync.sh
# Настоящие файлы; точка входа у стенда своя. Шов KIT_TEST_DEFAULTS уводит Kit.defaults в тестовый suite.
build() { # файл стенда, корень исходников, выход, флаги
  local app="$OUT/src/$(basename "$3")-app.swift"
  sed '/^@main$/d' "$2/App/UtilitumusApp.swift" > "$app"
  # Коммит базы в ключе: файлы из git archive получают время коммита, и разные коммиты не должны делить объекты.
  # shellcheck disable=SC2086
  local cache f; cache="$(incremental_cache "$(basename "$3")" KIT_TEST_DEFAULTS ${4:-} "$BASE")"
  incremental_sync "$OUT/src" "$cache/src"
  local files=("$cache/src/$(basename "$1")" "$cache/src/$(basename "$app")")
  while IFS= read -r f; do files+=("$f"); done < <(sources "$2" | sort)
  incremental_flags "$cache" "${files[@]}"
  rm -f "$3"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS ${4:-} -module-name VoiceWireCheck -o "$3" \
    "${files[@]}" \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit
}
cp Tests/VoiceWireCheck.swift "$OUT/src/VoiceWireCheck.swift"
build "$OUT/src/VoiceWireCheck.swift" Sources "$OUT/voice-wire-check"

in_home() { # домашний каталог, команда
  local home="$1"; shift
  mkdir -p "$home"
  env HOME="$home" CFFIXED_USER_HOME="$home" "$@"
}
in_home "$OUT/home-run" "$OUT/voice-wire-check" run "$OUT"

if [ "${VOICE_WIRE_NO_BASE:-}" != 1 ]; then
  rm -rf "$OUT/base" "$OUT/shots-before" "$OUT/home-before"
  mkdir -p "$OUT/base" "$OUT/shots-before"
  /usr/bin/git archive "$BASE" Sources | tar -x -C "$OUT/base"
  build "$OUT/src/VoiceWireCheck.swift" "$OUT/base/Sources" "$OUT/voice-wire-base" "-D VOICE_WIRE_BASE"
  in_home "$OUT/home-before" "$OUT/voice-wire-base" shots "$OUT/shots-before"
  in_home "$OUT/home-after" "$OUT/voice-wire-check" shots "$OUT/shots-after"
  in_home "$OUT/home-run" "$OUT/voice-wire-check" compare "$OUT/shots-before" "$OUT/shots-after"
  diff "$OUT/shots-before/log.txt" "$OUT/shots-after/log.txt" || fail "состояние после шагов разошлось"
  echo "ok   состояние после каждого шага совпало"
fi

[ "$BEFORE" = "$(real_snapshot)" ] || fail "папка настоящих моделей изменилась"
echo "ok   папка настоящих моделей не менялась"
echo "ВСЁ ОК"
