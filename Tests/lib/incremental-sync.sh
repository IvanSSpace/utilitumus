# Для скриптов Tests/run-*.sh с подставными исходниками: дополнение к Tests/lib/incremental.sh.
# Скрипт готовит файлы в своей временной папке, как раньше, а swiftc получает их копии из кэша:
#   incremental_sync "$OUT/src" "$CACHE/src"
# Файл с тем же содержимым сохраняет время изменения и не перекомпилируется зря, изменённый заменяется,
# а файл, которого больше нет в исходной папке, удаляется: иначе glob по папке кэша собрал бы и его.
incremental_sync() {
  local from="$1" to="$2" f
  mkdir -p "$to"
  for f in "$to"/*; do
    [ -e "$f" ] || continue
    [ -e "$from/$(basename "$f")" ] || rm -f "$f"
  done
  for f in "$from"/*; do
    cmp -s "$f" "$to/$(basename "$f")" || cp "$f" "$to/$(basename "$f")"
  done
}
