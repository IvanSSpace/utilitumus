#!/bin/bash
# Эквалайзер Микшера без устройств и тапов: настоящий `ProcessTap.render` на подставных буферах, настройки в своём домене.
# Сборка -O, как у выпуска: порядок записи и чтения между потоками проверяется в той же оптимизации. Папка: MIXER_EQ_DIR.
#   без аргументов  страж по исходникам, граница с лаунчером, математика, обход, передача коэффициентов, настройки
#   mutate          поломки в копии исходников: каждую должна поймать проверка
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MIXER_EQ_DIR:-${TMPDIR:-/tmp}/mixer-eq-check}"
SUITE="local.utilitumus.test.mixer-eq"
rm -rf "$OUT"
mkdir -p "$OUT"
reset_suite() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
trap reset_suite EXIT

build() { # папка модуля, выход
  swiftc -O -parse-as-library -target "$TARGET" -module-name MixerEqCheck -o "$2" Tests/MixerEqCheck.swift \
    "$1/EqDSP.swift" "$1/ProcessTap.swift" "$1/AudioProcessList.swift" "$1/MixerEqSettings.swift" "$1/UI/MixerEq.swift" \
    -framework CoreAudio -framework AudioToolbox
}

# Реалтайм-код без комментариев: слово в комментарии стража не касается.
code_of() { sed -E 's://.*$::' "$1"; }
realtime_of() { sed -n '/MARK: - Реалтайм/,$p' "$1" | sed -E 's://.*$::'; }

# Запрещённое в реалтайме и в файле с реалтаймом целиком. 1 — пусто, больше — ошибка самого grep.
forbid() { # имя, образец, текст со стандартного ввода
  local found status=0
  found="$(/usr/bin/grep -nE -- "$2")" || status=$?
  case "$status" in
    0) echo "FAIL $1:"; echo "$found"; exit 1 ;;
    1) echo "ok   $1" ;;
    *) echo "FAIL $1: grep завершился с кодом $status"; exit 1 ;;
  esac
}

guard() { # файл EqDSP, файл ProcessTap
  # Строки только как типы и вызовы: само слово в имени функции не ловится благодаря границам.
  local banned='\b(Array|ContiguousArray|Dictionary|Set|String|Substring|Character|class|actor|print|debugPrint|NSLog|os_log|Logger|NS[A-Z][a-zA-Z]+|os_unfair_lock[a-z_]*|pthread_[a-z_]+|DispatchQueue|DispatchSemaphore|Task|Date|withUnsafe[A-Za-z]*|malloc|calloc|realloc|free|allocate|deallocate|Optional|Any|AnyObject)\b|\[[A-Z][A-Za-z]*\]|\[[A-Z][A-Za-z]*:'
  # Без `|| return`: `forbid` живёт в подоболочке конвейера, и внутри `if` у вызывающего его код иначе потерялся бы.
  realtime_of "$1" | forbid "EqDSP, реалтайм: нет Array, class, print, блокировок, Dictionary, String, аллокаций" "$banned" || return 1
  realtime_of "$2" | forbid "ProcessTap.render: нет Array, class, print, блокировок, Dictionary, String, аллокаций" "$banned" || return 1
  # Файл фильтров целиком: чистая логика, в нём не может быть подсчёта ссылок и системных рамок.
  code_of "$1" | forbid "EqDSP целиком: нет классов, коллекций, логов, блокировок" '\b(Array|Dictionary|String|class|actor|print|NSLog|os_unfair_lock[a-z_]*|DispatchQueue)\b|\[[A-Z][A-Za-z]*\]|\[[A-Z][A-Za-z]*:' || return 1
  code_of "$1" | forbid "EqDSP без AppKit, CoreAudio и Foundation" '^import +(AppKit|CoreAudio|AudioToolbox|Foundation|SwiftUI)' || return 1
  # Реалтайм-раздел должен быть: иначе страж смотрел бы в пустоту.
  [ "$(realtime_of "$1" | /usr/bin/grep -c 'func process')" = 1 ] && echo "ok   страж видит реалтайм EqDSP" || { echo "FAIL страж не видит реалтайм EqDSP"; return 1; }
  [ "$(realtime_of "$2" | /usr/bin/grep -c 'static func render')" = 1 ] && echo "ok   страж видит ProcessTap.render" || { echo "FAIL страж не видит ProcessTap.render"; return 1; }
}

case "${1:-}" in
"")
  echo "== Страж реального времени"
  guard Sources/Modules/Mixer/EqDSP.swift Sources/Modules/Mixer/ProcessTap.swift

  echo "== Граница с лаунчером"
  HUB_LIST="$(scripts/hub-sources.sh)"
  [ -z "$(/usr/bin/grep -E 'EqDSP|ProcessTap|MixerEqSettings|MixerController' <<<"$HUB_LIST" || true)" ] && echo "ok   код звука не в списке лаунчера" || { echo "FAIL код звука в списке лаунчера"; exit 1; }
  /usr/bin/grep -qF 'Sources/Modules/Mixer/UI/MixerEq.swift' <<<"$HUB_LIST" && echo "ok   значения и варианты в лаунчере есть" || { echo "FAIL экрану лаунчера нечем проверять значения"; exit 1; }
  { /usr/bin/grep -rlE 'EqEngine|biquad|OSAtomic|cos\(|pow\(' Sources/Modules/Mixer/UI Sources/App/Satellites/RemoteMixer*.swift || true; } | forbid "в UI и вкладке лаунчера нет формул и обращений к фильтрам" '.'

  echo "== Сборка и прогон"
  build Sources/Modules/Mixer "$OUT/check"
  "$OUT/check"
  ;;
mutate)
  M="$OUT/mut"
  caught=0
  missed=0
  build Sources/Modules/Mixer "$OUT/mut-check"
  "$OUT/mut-check" > "$OUT/mut.log" 2>&1 || { echo "ПРОВАЛ: без поломок проверка не проходит"; /usr/bin/grep '^FAIL' "$OUT/mut.log" || true; exit 1; }
  echo "ok   без поломок проверка проходит"
  mutation() { # файл относительно модуля, что заменить, на что, имя
    rm -rf "$M"
    mkdir -p "$M"
    cp -R Sources/Modules/Mixer/ "$M/"
    /usr/bin/python3 -I - "$M/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) < 1:
    sys.exit("нет строки: " + old)
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
    build "$M" "$OUT/mut-check" 2>"$OUT/mut-build.log" || { echo "ПРОВАЛ: поломка «$4» не собралась"; /usr/bin/grep 'error:' "$OUT/mut-build.log" | head -5; exit 1; }
    if "$OUT/mut-check" > "$OUT/mut.log" 2>&1; then
      echo "FAIL поломку не поймали: $4"
      missed=$((missed + 1))
    else
      echo "ok   поймана: $4 ($(/usr/bin/grep -c '^FAIL' "$OUT/mut.log" || true) провалов, первый: $(/usr/bin/grep -m1 '^FAIL' "$OUT/mut.log" | cut -c1-90))"
      caught=$((caught + 1))
    fi
  }
  mutation EqDSP.swift 'return reader[2] != 0 || set[Self.limiterShare] != 0' 'return true' "обход не побайтовый: на ровном эквалайзере фильтры всё равно работают"
  mutation ProcessTap.swift 'let shaped = eqHere ? eq.process(sample, channel: firstChannel + c) : sample' 'let shaped = eqHere ? eq.process(sample, channel: firstChannel + c) : sample * 0.99999' "обход не побайтовый: путь без эквалайзера меняет значения"
  mutation EqDSP.swift 'current[i] += (set[i] - current[i]) * step' 'current[i] = set[i]' "резкая смена без сглаживания"
  mutation EqDSP.swift 'var out = x + (limited - x) * current[Self.limiterShare]
        if out > 1 { out = 1 } else if out < -1 { out = -1 }' 'let out = x + (limited - x) * 0' "нет защиты от перегруза"
  mutation EqDSP.swift 'set[preamp] = active ? 1 / peakResponse(set, rate: rate) : 1' 'set[preamp] = 1' "нет предусиления"
  mutation EqDSP.swift 'guard frequency < rate * 0.45 else { return }' '' "полоса выше Найквиста не отключается"
  mutation UI/MixerEq.swift 'var soundingBands: [Double] { enabled ? bands : MixerEq.flat }' 'var soundingBands: [Double] { bands }' "выключатель не выключает"
  mutation UI/MixerEq.swift 'next.preset = MixerEq.customID
' '' "ручная правка не переключает на «Свой»"
  mutation UI/MixerEq.swift 'MixerEq.isValid(bands) && MixerEq.isKnownPreset(preset)' 'MixerEq.isValid(bands)' "чужое имя режима проходит"
  # В одном потоке эта поломка незаметна: её может поймать только одновременная запись и чтение.
  mutation EqDSP.swift 'let set = sets + Int(writer.pointee) * Self.setSize
        Self.fill' 'writer.pointee = Int32(reader[0])
        let set = sets + Int(writer.pointee) * Self.setSize
        Self.fill' "неполный набор: писатель пишет в набор, который читает реалтайм"
  mutation EqDSP.swift 'while band < Self.bands {
            // Сюда' 'while band < Self.bands - 1 {
            // Сюда' "неполный набор: последняя полоса не считается"
  mutation EqDSP.swift 'case 8: return 8000' 'case 8: return 4000' "неверная частота полосы"
  mutation UI/MixerEq.swift 'bands.count == bandCount && ' 'bands.count >= bandCount && ' "проверка пропускает 11 и 13 полос"
  mutation UI/MixerEq.swift 'bands.count == bandCount && ' 'bands.count <= bandCount && ' "проверка пропускает 9 полос"
  mutation UI/MixerEq.swift '$0 >= minGain && $0 <= maxGain' '$0 >= minGain' "проверка пропускает значение выше предела"
  mutation UI/MixerEq.swift '$0.isFinite && $0 >= minGain' '!$0.isFinite || $0 >= minGain' "проверка пропускает NaN и бесконечность"
  mutation EqDSP.swift 'let a = pow(10, gain / 40)' 'let a = pow(10, -gain / 40)' "неверный знак усиления"
  mutation EqDSP.swift 'let w = 2 * Double.pi * frequency / rate' 'let w = 2 * Double.pi * frequency / 48000' "неверная частота дискретизации"
  mutation EqDSP.swift 'if y > -Self.silence && y < Self.silence { y = 0 }' '' "денормалы в истории"
  mutation EqDSP.swift 'if !(x > -1e6 && x < 1e6) {' 'if false {' "NaN со входа застревает в истории"
  mutation EqDSP.swift 'if channels != reader[1] {' 'if false {' "смена формата не обнуляет историю"
  mutation EqDSP.swift 'let memory = history + channel * Self.historyPerChannel' 'let memory = history' "история одна на все каналы"
  mutation ProcessTap.swift 'let eqHere = eqOn && firstChannel + outCh <= EqEngine.maxChannels' 'let eqHere = eqOn' "каналов больше памяти истории"

  mutation MixerEqSettings.swift 'if setting.isValid, setting != .off {' 'if setting != .off {' "значения с диска не проверяются"
  echo "== Страж на поломках"
  guard_mutation() { # что дописать в реалтайм, имя
    rm -rf "$M"
    mkdir -p "$M"
    cp -R Sources/Modules/Mixer/ "$M/"
    printf '\n%s\n' "$1" >> "$M/EqDSP.swift"
    if (guard "$M/EqDSP.swift" "$M/ProcessTap.swift") > "$OUT/guard.log" 2>&1; then
      echo "FAIL страж не заметил: $2"
      missed=$((missed + 1))
    else
      echo "ok   страж заметил: $2"
      caught=$((caught + 1))
    fi
  }
  guard_mutation 'func a() { var x: [Double] = []; x.append(1) }' "Array"
  guard_mutation 'final class Hidden {}' "class"
  guard_mutation 'func a() { print("x") }' "print"
  guard_mutation 'func a() { os_unfair_lock_lock(l) }' "блокировка"
  guard_mutation 'let d: [String: Int] = [:]' "Dictionary"
  guard_mutation 'func a(_ s: String) {}' "String"
  echo "Поймано: $caught, пропущено: $missed"
  [ "$missed" -eq 0 ]
  ;;
*)
  echo "Неизвестный аргумент: $1"
  exit 2
  ;;
esac
