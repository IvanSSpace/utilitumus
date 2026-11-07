# Для скриптов Tests/run-*.sh: инкрементальная сборка без оптимизации (swiftc без -O и так собирает -Onone,
# так что проверяется тот же код). Кэш лежит вне папки проверки, которую скрипт чистит, и живёт между запусками.
#   . Tests/lib/incremental.sh
#   incremental_flags "$CACHE" "${FILES[@]}"   # заполняет INC_FLAGS; файлы потом передаются swiftc как обычно
#   swiftc "${INC_FLAGS[@]}" ... "${FILES[@]}"
# Нужен -module-name в самом вызове swiftc. INCREMENTAL_OFF=1 — собрать целиком, как раньше.
#   CACHE="$(incremental_cache имя-проверки [флаги -D ...])"   # папка кэша
# Пути к исходникам в карте относительные и у всех копий проекта одинаковые, поэтому общий кэш подмешал бы объекты чужой
# ветки. Своя папка у каждой копии (рабочее дерево), проверки и набора флагов. Вызывать из корня проекта.
incremental_cache() {
  local name="$1" key; shift
  key="$( { pwd -P; printf '%s\n' "$@"; } | /usr/bin/shasum -a 256 | cut -c1-12)"
  echo "${INCREMENTAL_ROOT:-${TMPDIR:-/tmp}/utilitumus-inc}/$key/$name"
}

# Когда компилировать нечего, инкрементальный swiftc не компонует и оставляет файл как есть, даже если его собрали из другого
# кэша: с другими -D или в другой копии проекта. Проверка запустила бы чужую программу, поэтому выход убирается заранее.
# Цена — компоновка при каждом запуске. Tests/run-incremental-lib-check.sh ловит возврат этой ошибки.
swiftc() {
  local prev="" arg
  case " $* " in
    *" -incremental "*) for arg in "$@"; do [ "$prev" != "-o" ] || rm -f -- "$arg"; prev="$arg"; done ;;
  esac
  command swiftc "$@"
}

incremental_flags() {
  local cache="$1"; shift
  INC_FLAGS=()
  [ -z "${INCREMENTAL_OFF:-}" ] || return 0
  mkdir -p "$cache"
  /usr/bin/python3 -I - "$cache" "$@" <<'PY'
import hashlib, json, sys
cache = sys.argv[1]
out = {"": {"swift-dependencies": cache + "/master.swiftdeps"}}
for f in sys.argv[2:]:
    b = cache + "/o" + hashlib.md5(f.encode()).hexdigest()[:12]
    out[f] = {"object": b + ".o", "swift-dependencies": b + ".swiftdeps", "dependencies": b + ".d"}
new = json.dumps(out)
try:
    same = open(cache + "/map.json").read() == new
except OSError:
    same = False
if not same:
    open(cache + "/map.json", "w").write(new)
PY
  INC_FLAGS=(-incremental -enable-batch-mode -j8 -output-file-map "$cache/map.json")
}

# Утилита со швом для стенда: аргументы как у scripts/build-app.sh. Входы те же и подпись верна — копия готового бандла вместо
# компиляции с -O. Кэш свой у каждой копии проекта и флага. INCREMENTAL_OFF=1 — собрать заново. Вызывать из корня проекта.
build_seam_utility() {
  local cache=""
  [ -n "${INCREMENTAL_OFF:-}" ] || cache="$(incremental_cache "utility-$1" "$5")"
  UTILITUMUS_BUILD_CACHE="$cache" scripts/build-app.sh "$@"
}
