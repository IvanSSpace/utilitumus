#!/bin/bash
# Пароль связки подписи не должен попадать в argv: `unlock-keychain -p` есть только в scripts/unlock-signing.sh
# (там он уходит в `security -i` по stdin). Настоящую связку проверка не трогает.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

for f in build.sh scripts/*.sh Tests/*.sh; do
  bash -n "$f" || bad "синтаксис $f"
done
ok "синтаксис скриптов"

FOUND="$(grep -rnE 'unlock-keychain[^|]*-p|cat "\$[A-Za-z_]*(PASSWORD|password)[A-Za-z_]*"' build.sh scripts Tests .github 2>/dev/null \
  | grep -v '^scripts/unlock-signing\.sh:' | grep -v '^Tests/run-unlock-guard-check\.sh:' || true)"
if [ -n "$FOUND" ]; then bad "пароль связки вне scripts/unlock-signing.sh: $FOUND"; else ok "unlock-keychain -p только в scripts/unlock-signing.sh"; fi

if grep -vE '^\s*#' scripts/unlock-signing.sh | grep -qE 'set -[a-z]*x|bash -x'; then bad "в unlock-signing.sh включена трасса"; else ok "в unlock-signing.sh нет трассы"; fi

# Подставной security вместо /usr/bin/security (так сделана очередь сборок): пароль не читается, команда без -p.
T="$(mktemp -d "${TMPDIR:-/tmp}/unlock-guard.XXXXXX")"
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.config/utilitumus" "$T/home/Library/Keychains" "$T/bin"
echo "секрет-для-проверки" > "$T/home/.config/utilitumus/keychain-password"
: > "$T/home/Library/Keychains/utilitumus-signing.keychain-db"
printf '#!/bin/sh\necho "$@" > "%s/argv"\n' "$T" > "$T/bin/security"
chmod +x "$T/bin/security"
HOME="$T/home" PATH="$T/bin:$PATH" scripts/unlock-signing.sh
if [ "$(cat "$T/argv")" = "unlock-keychain $T/home/Library/Keychains/utilitumus-signing.keychain-db" ]; then ok "подставной security получил unlock-keychain без пароля"; else bad "argv подставного security: $(cat "$T/argv")"; fi
if grep -q секрет "$T/argv"; then bad "пароль в argv"; else ok "пароля в argv нет"; fi
# Нет файла пароля — молча выходит.
rm "$T/home/.config/utilitumus/keychain-password"; rm "$T/argv"
HOME="$T/home" PATH="$T/bin:$PATH" scripts/unlock-signing.sh
if [ -e "$T/argv" ]; then bad "без файла пароля security вызван"; else ok "без файла пароля ничего не вызывается"; fi

if [ "$failures" -eq 0 ]; then echo "ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
