#!/bin/bash
# Контрольные поломки основы: каждая ломает одно правило в копии исходников, и проверка основы должна упасть
# на нужной строке. Рабочее дерево не меняется: копия живёт в папке стенда.
# Tests/run-satellite-mutations.sh [номера через пробел]   Папка: SATELLITE_MUTATIONS_DIR.
# Общего лимита (Tests/lib/check-limit.sh) здесь нет: он покрыл бы вложенную проверку, а лимит нужен на каждую поломку.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SATELLITE_MUTATIONS_DIR:-${TMPDIR:-/tmp}/satellite-mutations}"
mkdir -p "$WORK"
# Лимит на поломку. Без поломок проверка зелёная и не зависает, поэтому зависание значит, что поломка замечена; каждый раз
# это не сверяется. Со сборкой с нуля под нагрузкой проверка шла до 426 с.
LIMIT=600
MODEL=Sources/App/Satellites/RemoteModuleModel.swift
HOST=Sources/Kit/SatelliteHost.swift
SERVER=Sources/Kit/Link/LinkServer.swift
CLIENT=Sources/Kit/Link/LinkClient.swift
PROTOCOL=Sources/Kit/Link/LinkProtocol.swift
WIRE=Sources/Kit/Link/LinkWire.swift
MODULE=Sources/Kit/SatelliteModule.swift
UPDATE=Sources/Kit/SatelliteSelfUpdate.swift

# номер|файл|было|стало|какая строка должна упасть
MUTATIONS=(
"1|$MODEL|toleratedFailedReads: Int { 1 }|toleratedFailedReads: Int { 0 }|первый сбой чтения"
"2|$MODEL|guard ticket > applied else { return false }|applied = ticket; return true|старое чтение опоздало"
"3|$MODEL|for item in pending { optimistic(\&shown, item.action) }||оптимизм"
"4|$MODEL|pending.removeAll { \$0.ticket == item.ticket }||откат"
"5|$MODEL|guard sending.insert(key).inserted else { return }|sending.insert(key)|в пути одно"
"6|$MODEL|if data.count < Self.offMainDecodeBytes {|if true {|большой ответ"
"7|$MODEL|if reading {|if false {|пинги во время чтения"
"8|$SERVER|MainActor.assumeIsolated { self?.lost(session) }|_ = self|клиент умер"
"9|$SERVER|if wasWatching { handler.linkWatcherLost() }||подписчик пропал"
"10|$PROTOCOL|return oldest <= hello.protocolVersion|return hello.protocolVersion == protocolVersion; _ = oldest <= hello.protocolVersion|диапазон версий"
"11|$HOST|case .uninstall: module.stopForUninstall()|case .uninstall: module.stopForUpdate()|quit(uninstall)"
"12|$SERVER|LinkQuitReason(rawValue: reason) ?? .update|LinkQuitReason(rawValue: reason) ?? .uninstall|неизвестная причина"
"13|$HOST|if mode == .active \&\& enabled {|if enabled {|пассивная значит остановленная"
"14|$MODULE|func enterPassive() { stop() }|func enterPassive() {}|пассивная значит остановленная"
"15|$WIRE|encoder.outputFormatting = .sortedKeys||sortedKeys"
"16|$WIRE|encoded(action) == data else { return nil }|true else { return nil }|не канонический вид"
"17|$HOST|LinkThrottle(interval: 0.25)|LinkThrottle(interval: 0)|всплеск 200"
"18|$HOST|LinkThrottle(interval: 1)|LinkThrottle(interval: 0)|статус менялся 20 раз"
"19|$HOST|guard linkStatus() != announcedStatus else { return }||статус не менялся"
"20|$HOST|guard module.setupSteps.contains(where: { \$0.id == id }) else {|guard id != \"\" else {|неизвестный шаг"
"21|$CLIENT|if watchLevel != .none {|if false {|модель взяла экран"
"22|$UPDATE|try await beforeReplace()\$|try await ({})()|хук идёт до замены"
)

only=" $* "
failed=0
ran=""
for mutation in "${MUTATIONS[@]}"; do
  IFS='|' read -r number file from to expected <<< "$mutation"
  if [ $# -gt 0 ] && [[ "$only" != *" $number "* ]]; then continue; fi
  copy="$WORK/copy"
  rm -rf "$copy"
  mkdir -p "$copy"
  (cd "$ROOT" && tar cf - --exclude=.git --exclude=build Sources Tests scripts Info.plist) | (cd "$copy" && tar xf -)
  before="$(shasum "$copy/$file")"
  sed -i '' "s|$from|$to|g" "$copy/$file"
  if [ "$before" = "$(shasum "$copy/$file")" ]; then
    echo "ПРОВАЛ $number: замена не применилась: $from"
    failed=$((failed + 1))
    continue
  fi
  ran="$ran|$number"
  log="$WORK/mutation-$number.log"
  status=0
  SATELLITE_CHECK_DIR="$WORK/out" CHECK_LIMIT="$LIMIT" "$copy/Tests/run-satellite-base-check.sh" "mut$number" > "$log" 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    echo "ПРОВАЛ $number: проверка прошла, поломка не поймана: $from"
    failed=$((failed + 1))
  elif grep -E "^FAIL" "$log" | grep -q -- "$expected"; then
    echo "ok   $number: $(grep -E "^FAIL" "$log" | grep -- "$expected" | head -1 | cut -c1-130)"
  # Первая строка «== » печатается после сборки: без неё до запуска не дошло, что бы ни было в журнале.
  elif ! grep -q '^== ' "$log"; then
    echo "ПРОВАЛ $number: не собралось (код $status): $(grep -m1 'error:' "$log" | cut -c1-160)"
    failed=$((failed + 1))
  elif [ "$status" -eq 124 ]; then
    echo "ok   $number: зависла, поломка заметна"
  # Падение вместо строки FAIL: поломка замечена, но проверка неаккуратная, она не называет, что сломалось.
  elif [ "$status" -gt 128 ] || grep -q 'Fatal error' "$log"; then
    echo "ok   $number: упала при запуске, поломка заметна, проверка неаккуратная: $(grep -m1 'Fatal error' "$log" | cut -c1-130)"
  else
    echo "ПРОВАЛ $number: упало не там. Ждали «$expected», а: $(grep -E '^FAIL|ПРОВАЛ' "$log" | head -2 | cut -c1-160)"
    failed=$((failed + 1))
  fi
done
rm -rf "$WORK/copy" "$WORK/out"
launchctl list | grep -E "local\.utilitumus\.test\.mut(${ran#|})$" && { echo "ПРОВАЛ: метка осталась"; failed=$((failed + 1)); }
if [ "$failed" -eq 0 ]; then echo "ПОЛОМКИ ОСНОВЫ: ВСЕ ПОЙМАНЫ"; else echo "НЕ ПОЙМАНО: $failed"; exit 1; fi
