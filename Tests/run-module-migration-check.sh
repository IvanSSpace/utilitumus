#!/bin/bash
# Автопереход модулей на утилиты: каталог, установка и состояние модулей подставные, сети и настоящих установок нет.
# Три мутации: каждая ломает код в копии, проверка обязана провалиться; исходник не меняется.
# Папка: MODULE_MIGRATION_CHECK_DIR, иначе $TMPDIR/module-migration-check.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MODULE_MIGRATION_CHECK_DIR:-${TMPDIR:-/tmp}/module-migration-check}"

# Ни один тест не имеет права дотянуться до настоящих путей и настоящей связи.
status=0
found="$(grep -nE '\.live|live[A-Z]' Tests/ModuleMigrationCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: настоящие замыкания и пути в тестах:"; echo "$found"; exit 1 ;;
  1) echo "ok   настоящие замыкания и пути в тестах: нет" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
# У основной сборки и каждой мутации свой кэш: набор файлов разный, а общий кэш пересобирал бы мутацию при каждой смене.
. Tests/lib/incremental.sh
rm -rf "$OUT"
mkdir -p "$OUT/src"

# Kit.defaults — домен самого бинарника, не настоящий local.utilitumus.
sed 's/Bundle\.main\.bundleIdentifier == hubBundleID/true/' Sources/Kit/KitDefaults.swift > "$OUT/src/KitDefaults.swift"
if ! grep -q 'UserDefaults = true' "$OUT/src/KitDefaults.swift"; then
  echo "ПРОВАЛ: подмена Kit.defaults не сработала"
  exit 1
fi
cp Tests/ModuleMigrationCheck.swift "$OUT/src/main.swift"

# $1 — имя, $2 — файл с кодом миграции.
build() {
  local cache f
  cache="$(incremental_cache "module-migration-$1" "$TARGET")"
  mkdir -p "$cache/src"
  # Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
  for f in main.swift KitDefaults.swift; do cmp -s "$OUT/src/$f" "$cache/src/$f" || cp "$OUT/src/$f" "$cache/src/$f"; done
  local migration="$2"
  if [ "$migration" = "$OUT/src/Mutant.swift" ]; then
    migration="$cache/src/Mutant.swift"
    cmp -s "$OUT/src/Mutant.swift" "$migration" || cp "$OUT/src/Mutant.swift" "$migration"
  fi
  local files=("$cache/src/main.swift" "$cache/src/KitDefaults.swift" $(find Sources/Kit -name '*.swift' -not -name KitDefaults.swift | sort) \
    Sources/App/ModuleManager.swift Sources/App/ModuleScope.swift Sources/App/ModuleReset.swift Sources/Modules/Keyboard/UI/FnSystemAction.swift \
    Sources/App/SidebarLayout.swift Tests/HubLinkStubs.swift \
    Sources/App/Satellites/ModuleHandover.swift Sources/App/Satellites/SatelliteRegistry.swift \
    Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteAgent.swift "$migration")
  incremental_flags "$cache" "${files[@]}"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -module-name ModuleMigrationCheck -o "$OUT/$1" \
    "${files[@]}" -framework SwiftUI -framework AppKit -framework Carbon
}

build module-migration-check Sources/App/Satellites/ModuleMigration.swift
"$OUT/module-migration-check" "$OUT/work"

# Мутация: точная подстрока $2 в ModuleMigration.swift заменяется на $3. Проверка обязана провалиться.
mutate() {
  local name="$1"
  python3 -I - "$name" "$2" "$3" Sources/App/Satellites/ModuleMigration.swift "$OUT/src/Mutant.swift" <<'PY'
import sys
name, old, new, source, target = sys.argv[1:]
text = open(source, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("мутация «%s»: нужной строки в коде не одна" % name)
open(target, "w", encoding="utf-8").write(text.replace(old, new))
PY
  build "mutant-$name" "$OUT/src/Mutant.swift"
  if "$OUT/mutant-$name" "$OUT/work-$name" > "$OUT/mutant-$name.log" 2>&1; then
    echo "ПРОВАЛ: мутация «${name}» не замечена"
    exit 1
  fi
  echo "ok   мутация «${name}» замечена"
}
mutate removed '!env.defaults.bool(forKey: removedKey(id)),' 'true,'
mutate backoff 'env.now().timeIntervalSince1970 >= env.defaults.double(forKey: retryAfterKey(id)),' 'true,'
mutate off-module 'await env.isBuiltInOn(module) else' 'true else'
