# Снимок настоящих мест, которые стенды трогать не должны: только имена, размеры и mtime, содержимое не читается.
#
#   source Tests/stand-snapshot.sh
#   stand_snapshot_take "$OUT/before.txt"
#   ... проверки ...
#   stand_snapshot_compare "$OUT/before.txt"      # 0 — не менялось, 1 — менялось
#
# Настоящее Utilitumus (центр или любая настоящая утилита, например Вентиляторы со своим fans.log) может быть запущено
# и само пишет свои журналы и настройки. Тогда расхождения в журналах и в local.utilitumus.plist только отмечаются
# (ПРИМЕЧАНИЕ), остальное всё равно провал. Приложение не трогаем.

STAND_REAL_LOCATIONS=(
  "$HOME/Library/Application Support/Utilitumus"
  "$HOME/Library/Logs/Utilitumus"
  "$HOME/Library/Preferences/local.utilitumus.plist"
  "/Library/PrivilegedHelperTools/local.utilitumus.fan"
  "/Library/LaunchDaemons/local.utilitumus.fan.plist"
)

stand_snapshot_take() {
  : > "$1"
  local place
  for place in "${STAND_REAL_LOCATIONS[@]}"; do
    if [ -e "$place" ] || [ -L "$place" ]; then
      # Тестовые домены (local.utilitumus.test.*) — это сам шов, их стенд пишет по праву.
      find "$place" -not -name 'local.utilitumus.test.*' -exec /usr/bin/stat -f '%N|%z|%m' {} + 2>/dev/null
    else
      echo "$place|отсутствует"
    fi
  done | LC_ALL=C sort >> "$1"
}

# Метки стендов — local.utilitumus.test.*, настоящих утилит — local.utilitumus.app.<id>: стенд под них не попадает.
stand_real_app_running() {
  pgrep -x Utilitumus > /dev/null 2>&1 \
    || launchctl list 2>/dev/null | awk '$1 != "-" && $3 ~ /^local\.utilitumus\.app\./ { found = 1 } END { exit !found }'
}

stand_snapshot_compare() {
  local before="$1" after changed noisy hard
  after="$(mktemp -t stand-snapshot)"
  stand_snapshot_take "$after"
  changed="$(diff "$before" "$after" | /usr/bin/grep -E '^[<>]' || true)"
  rm -f "$after"
  if [ -z "$changed" ]; then echo "ok   настоящие места не менялись ($(wc -l < "$before" | tr -d ' ') записей)"; return 0; fi
  if stand_real_app_running; then
    noisy="$(echo "$changed" | /usr/bin/grep -E 'Library/Logs/Utilitumus|Preferences/local\.utilitumus\.plist' || true)"
    hard="$(echo "$changed" | /usr/bin/grep -vE 'Library/Logs/Utilitumus|Preferences/local\.utilitumus\.plist' || true)"
    [ -n "$noisy" ] && { echo "ПРИМЕЧАНИЕ: настоящее Utilitumus запущено, его журналы и настройки меняются само:"; echo "$noisy" | sed 's/^/   /'; }
  else
    hard="$changed"
  fi
  if [ -n "$hard" ]; then echo "ПРОВАЛ: стенд изменил настоящее:"; echo "$hard" | sed 's/^/   /'; return 1; fi
  echo "ok   настоящие места не менялись, кроме отмеченного"
  return 0
}
