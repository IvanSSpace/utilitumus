# Лимит времени проверки: зависшая не стоит вечно, а падает с понятной строкой и кодом 124. Первая команда скрипта, до cd:
#   source "$(dirname "$0")/lib/check-limit.sh"                  # общий лимит
#   CHECK_LIMIT=5400 source "$(dirname "$0")/lib/check-limit.sh" # свой лимит у долгой проверки
# Скрипт перезапускается под сторожем, поэтому ожидание замка и очереди снаружи (with-check-lock, buildq) в лимит не входит.
# Лимит считается по тикам сторожа: пока Mac спит, время проверки не идёт.
#
# Сторож убивает только своё дерево, по номерам процессов: своя группа плюс потомки по родителю. Потомка со своей группой
# находит родитель, осиротевшего находит группа. Имена процессов не смотрит.
# Порядок: один SIGTERM всем (второй оборвал бы уже идущий trap очистки), 30 с на trap. Потом SIGKILL всем, кроме самого
# скрипта: bash не выполнит trap, пока ждёт потомка, которому SIGTERM не указ. Ещё 15 с на trap, потом SIGKILL и скрипту.
# Вложенная проверка лимит не заводит, её покрывает внешняя: CHECK_LIMIT_GUARD наследуется. Tests/run-check-timeout-check.sh.
if [ -z "${CHECK_LIMIT_GUARD:-}" ]; then
  exec /usr/bin/perl -e '
    use POSIX ();
    my ($limit, $name, @cmd) = @ARGV;
    $| = 1;
    $ENV{CHECK_LIMIT_GUARD} = 1;
    defined(my $root = fork) or die "fork: $!\n";
    if (!$root) { setpgrp(0, 0); exec { $cmd[0] } @cmd; exit 127 }
    setpgrp($root, $root);
    my ($signal, $status, %seen);
    $SIG{$_} = sub { $signal = shift } for qw(INT TERM HUP);

    sub reap { $status = $? if !defined $status && waitpid($root, POSIX::WNOHANG) == $root; defined $status }
    sub pause { select(undef, undef, undef, shift) }
    # Живые процессы дерева. Раз попавший в него запоминается: когда родитель умрёт, по родителю его уже не найти.
    sub tree {
      my (%kids, %alive);
      open(my $ps, "-|", "/bin/ps", "-axo", "pid=,ppid=,pgid=,stat=") or return ();
      while (<$ps>) {
        my ($pid, $ppid, $pgid, $stat) = split;
        next if $stat =~ /^Z/;
        $alive{$pid} = 1;
        push @{ $kids{$ppid} }, $pid;
        $seen{$pid} = 1 if $pgid == $root;
      }
      close $ps;
      my @queue = ($root, keys %seen);
      while (@queue) { my $pid = shift @queue; $seen{$pid} = 1; push @queue, @{ delete $kids{$pid} || [] } }
      return grep { $alive{$_} } keys %seen;
    }
    sub gone_within { my $seconds = shift; for (1 .. $seconds * 2) { reap(); return 1 unless tree(); pause(0.5) } reap(); !tree() }

    my $ticks = 0;
    until (reap() || $signal || $ticks++ >= $limit * 5) { pause(0.2) }
    exit($status & 127 ? 128 + ($status & 127) : $status >> 8) if defined $status;

    my $interrupted = $signal;
    kill "TERM", tree();
    gone_within(30) or do {
      kill "KILL", grep { $_ != $root } tree();
      gone_within(15) or do { for (1 .. 10) { my @rest = tree() or last; kill "KILL", @rest; pause(0.5) } };
    };
    my @left = tree();
    print "ПРОВАЛ: $name: не убиты @left\n" if @left;
    exit({ INT => 130, TERM => 143, HUP => 129 }->{$interrupted}) if $interrupted;
    print "ПРОВАЛ: $name зависла, больше $limit с, убита\n";
    exit 124;
  ' "${CHECK_LIMIT:-1800}" "$(basename "$0" .sh)" /bin/bash "$0" "$@"
fi
