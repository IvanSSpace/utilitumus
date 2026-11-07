#!/bin/bash
# Лимит времени проверок (Tests/lib/check-limit.sh) на подставных зависающих проверках: процессы только свои, без сборки и подписи.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

T="$(mktemp -d "${TMPDIR:-/tmp}/check-timeout.XXXXXX")"
sleep 900 &
BYSTANDER=$!
trap 'kill "$BYSTANDER" 2>/dev/null || true; rm -rf "$T"' EXIT
failures=0
ok() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$3», вышло «$2»"; fi; }
has() { if /usr/bin/grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: нет «$3» в $2:"; cat "$2"; fi; }
# Зомби уже мёртв, просто его ещё не подобрали.
alive() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in '' | Z*) return 1 ;; *) return 0 ;; esac; }
dead() { if alive "$2"; then bad "$1 жив: $(ps -o command= -p "$2")"; kill -9 "$2" 2>/dev/null || true; else ok "$1 убит"; fi; }

echo "== у каждой проверки есть лимит, и он идёт до set и cd"
for f in Tests/run-*.sh; do
  case "$f" in Tests/run-satellite-mutations.sh) continue ;; esac
  # Без строки лимита grep вернёт 1: под set -e и pipefail скрипт молча вышел бы, не назвав файл.
  first="$(/usr/bin/grep -nE '^(CHECK_LIMIT=[0-9]+ )?source "\$\(dirname "\$0"\)/lib/check-limit\.sh"$' "$f" | cut -d: -f1 | head -1 || true)"
  other="$(/usr/bin/grep -nvE '^(#|$)' "$f" | cut -d: -f1 | head -1)"
  [ "$first" = "$other" ] || bad "$f: первая команда не лимит"
done
ok "проверено скриптов: $(ls Tests/run-*.sh | wc -l | tr -d ' ')"

mkdir -p "$T/Tests/lib" "$T/locks"
cp Tests/lib/check-limit.sh "$T/Tests/lib/"
export MARK="$T"
# Подставная проверка: имя, лимит (пусто — общий), тело со стандартного ввода.
fixture() {
  { printf '#!/bin/bash\n%ssource "$(dirname "$0")/lib/check-limit.sh"\nset -uo pipefail\n' "${2:+CHECK_LIMIT=$2 }"; cat; } > "$T/Tests/run-$1.sh"
}
# Сама эта проверка уже под сторожем, а подставным нужен свой. Не функция: с ней $! был бы подоболочкой, а не сторожем.
FRESH=(env -u CHECK_LIMIT_GUARD -u CHECK_LIMIT)

# Висит на переднем плане; потомки: фоновый, осиротевший, со своей группой (его находит только обход по родителю).
fixture hung 2 <<'EOF'
trap 'echo начала > "$MARK/hung.trap"; sleep 1; echo закончила >> "$MARK/hung.trap"' EXIT
sleep 901 &
echo $! > "$MARK/hung.bg"
( sleep 902 & echo $! > "$MARK/hung.orphan" )
/usr/bin/perl -e 'setpgrp(0, 0); sleep 903' &
echo $! > "$MARK/hung.own-group"
sleep 904
EOF
# SIGTERM игнорирует потомок на переднем плане. С trap на TERM, как в Tests/satellite-check-lib.sh, bash выполнит его, только
# когда потомок умрёт (без такого trap bash умирает сразу и успевает выполнить trap на EXIT).
fixture stubborn "" <<'EOF'
trap 'exit 1' TERM
trap 'echo $$ > "$MARK/stubborn.trap"' EXIT
/usr/bin/perl -e '$SIG{TERM} = "IGNORE"; open(my $f, ">", "$ENV{MARK}/stubborn.child"); print $f $$; close $f; sleep 905'
EOF
# SIGTERM не берёт и сам скрипт, он только запускает новых потомков.
fixture immortal 1 <<'EOF'
trap '' TERM
echo $$ > "$MARK/immortal.root"
while :; do sleep 906; done
EOF
fixture exits "" <<'EOF'
echo "аргументы: $# [$1] [$2]"
exit 7
EOF

echo "== код и аргументы независлой проверки доходят как есть"
status=0
"${FRESH[@]}" /bin/bash "$T/Tests/run-exits.sh" a 'b c' > "$T/exits.log" 2>&1 || status=$?
same "код проверки" "$status" 7
has "аргументы" "$T/exits.log" 'аргументы: 2 [a] [b c]'
same "строки о зависании нет" "$(/usr/bin/grep -c ПРОВАЛ "$T/exits.log" || true)" 0

# У скрипта под сторожем своя группа, поэтому Ctrl-C в терминале получает только сторож: он обязан передать сигнал дереву.
echo "== прерывание сторожа доходит до проверки"
fixture stopped "" <<'EOF'
trap 'exit 1' TERM
trap 'echo есть > "$MARK/stopped.trap"' EXIT
sleep 907 &
echo $! > "$MARK/stopped.bg"
sleep 908
EOF
"${FRESH[@]}" /bin/bash "$T/Tests/run-stopped.sh" > "$T/stopped.log" 2>&1 &
stopped=$!
for _ in $(seq 1 100); do [ -e "$T/stopped.bg" ] && break; sleep 0.1; done
kill -TERM "$stopped"
status=0
wait "$stopped" || status=$?
same "код прерванной" "$status" 143
dead "потомок прерванной" "$(cat "$T/stopped.bg")"
[ -s "$T/stopped.trap" ] && ok "trap прерванной выполнен" || bad "trap прерванной не выполнен"
same "о зависании не сказано" "$(/usr/bin/grep -c зависла "$T/stopped.log" || true)" 0

echo "== зависшие проверки"
locked() { /usr/bin/python3 -I -c 'import fcntl, sys
try:
    fcntl.flock(open(sys.argv[1], "w"), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
sys.exit(1)' "$1"; }
started=$SECONDS
CHECK_LOCK_DIR="$T/locks" "${FRESH[@]}" Tests/with-check-lock.sh /bin/bash "$T/Tests/run-hung.sh" > "$T/hung.log" 2>&1 &
hung=$!
"${FRESH[@]}" CHECK_LIMIT=1 /bin/bash "$T/Tests/run-stubborn.sh" > "$T/stubborn.log" 2>&1 &
stubborn=$!
"${FRESH[@]}" /bin/bash "$T/Tests/run-immortal.sh" > "$T/immortal.log" 2>&1 &
immortal=$!
for _ in $(seq 1 100); do [ -e "$T/hung.bg" ] && break; sleep 0.1; done
if locked "$T/locks/run-hung.lock"; then ok "пока висит, замок группы занят"; else bad "пока висит, замок группы свободен"; fi

status=0
wait "$hung" || status=$?
hung_seconds=$((SECONDS - started))
same "код зависшей, через замок" "$status" 124
has "строка о зависании" "$T/hung.log" 'ПРОВАЛ: run-hung зависла, больше 2 с, убита'
[ "$hung_seconds" -lt 15 ] && ok "убита за лимит: $hung_seconds с" || bad "убивали $hung_seconds с при лимите 2"
for who in bg orphan own-group; do dead "потомок $who" "$(cat "$T/hung.$who")"; done
same "trap очистки дошёл до конца" "$(cat "$T/hung.trap" | tr '\n' ' ')" "начала закончила "
if locked "$T/locks/run-hung.lock"; then bad "замок группы не отпущен"; else ok "замок группы отпущен"; fi
if alive "$BYSTANDER"; then ok "посторонний sleep того же вида жив"; else bad "убит посторонний sleep"; fi

status=0
wait "$stubborn" || status=$?
same "код: потомок игнорирует SIGTERM" "$status" 124
has "общий лимит заменяется из окружения" "$T/stubborn.log" 'ПРОВАЛ: run-stubborn зависла, больше 1 с, убита'
dead "потомок, игнорирующий SIGTERM," "$(cat "$T/stubborn.child")"
[ -s "$T/stubborn.trap" ] && ok "trap выполнен: SIGKILL сначала пришёл потомку" || bad "trap не выполнен"

status=0
wait "$immortal" || status=$?
same "код: сам скрипт игнорирует SIGTERM" "$status" 124
dead "скрипт, игнорирующий SIGTERM," "$(cat "$T/immortal.root")"

if alive "$BYSTANDER"; then ok "посторонний sleep жив и в конце"; else bad "убит посторонний sleep"; fi
[ "$failures" -eq 0 ] || { echo "ПРОВАЛОВ: $failures"; exit 1; }
echo "ЛИМИТ ПРОВЕРОК: ВСЁ ОК"
