# Для scripts/dev.sh и Tests/run-dev-scope-check.sh, подключается через `.`: чьи файлы менялись и что видит центр.
# Нужны APPS (id:Имя через пробел) и текущая папка в корне репозитория.
# Правка Sources/Kit набор не расширяет: она касается всех, dev.sh только говорит об этом.

name_of() { local pair; for pair in $APPS; do [ "${pair%%:*}" = "$1" ] && { echo "${pair##*:}"; return; }; done; return 1; }
id_of_name() { local pair; for pair in $APPS; do [ "${pair##*:}" = "$1" ] && { echo "${pair%%:*}"; return; }; done; return 1; }

# Экран утилиты в центре: Sources/App/Satellites/Remote<Имя>*. RemoteModule* общие, такого модуля нет.
dev_scope_screen_owner() {
  local LC_ALL=C base="${1##*/Remote}" pair
  for pair in $APPS; do
    case "$base" in "${pair##*:}"[A-Z.]*) echo "${pair%%:*}"; return ;; esac
  done
  return 1
}

# Список изменённых файлов на входе. PICK — кого пересобрать, SCREENS — чьи экраны правили, KIT — менялся ли Kit.
# Помощники и Sources/Shared входят в манифест ровно одной утилиты, поэтому её и пересобирают.
# Экран пересобирает только центр. Остальные файлы центра (BrowserSatelliteHooks.swift, Setup, Store) общие для нескольких модулей.
dev_scope_classify() {
  local file id
  PICK=(); SCREENS=""; KIT=""
  while IFS= read -r file; do
    case "$file" in
      Sources/Apps/*/* | Sources/Modules/*/*) id="$(id_of_name "$(echo "$file" | cut -d/ -f3)")" || continue ;;
      Sources/VoiceHelper/*) id=voice ;;
      Sources/FanHelper/* | Sources/Shared/*) id=fans ;;
      Sources/LinkHelper/*) id=browser ;;
      Sources/App/Satellites/Remote*)
        id="$(dev_scope_screen_owner "$file")" || continue
        case " $SCREENS " in *" $id "*) ;; *) SCREENS="${SCREENS:+$SCREENS }$id" ;; esac
        continue ;;
      Sources/Kit/*) KIT=1; continue ;;
      *) continue ;;
    esac
    case " ${PICK[*]:-} " in *" $id "*) ;; *) PICK+=("$id") ;; esac
  done
}

# Набор центра: перечисленные id без повторов. --all передаёт `*`.
dev_scope_line() {
  local list="" id
  for id in "$@"; do
    case ",$list," in *",$id,"*) ;; *) list="${list:+$list,}$id" ;; esac
  done
  # Метка собрана из частей, как в scripts/check-no-seam.sh.
  echo "local.utilitumus.dev-""scope=$list"
}

# Файл с набором для компиляции центра с флагом KIT_DEV_SCOPE. Строка видна в бинарнике: её ищет scripts/check-no-seam.sh.
dev_scope_swift() {
  printf 'enum KitDevScope {\n    static let line = "%s"\n}\n' "$(dev_scope_line "$@")"
}
