"""Действия панели: остановить дерево своих процессов, включить, выключить или перезапустить бота,
остановить, убрать из автозапуска или вернуть фоновый агент launchd.

Что гарантируем:
- исполняется только action_id из серверного снимка не старше 5 с (это проверяет маршрут /api/action);
- перед сигналом заново читаем uniqueid каждой цели: ушедшие пропускаем; корень уже завершился — 409
  «уже завершился», а если pid корня занят другим процессом — 409 и ни одного сигнала;
- не трогаем pid ≤ 1, саму панель и всех её предков, всё дерево сессии Claude, из которой запущена панель,
  процессы ботов (их гасит только команда из bots.toml: kill KeepAlive-агента launchd тут же поднимет),
  сессии, которые ведёт приложение (Claude.app, IDE), хост вкладок терминала, чужие uid и WindowServer,
  loginwindow, Dock, Finder, SystemUIServer, ControlCenter; системный файл (кроме шелла) не бывает целью
  действия, но в дереве цели он — команда пользователя (sleep, tail, ssh) и останавливается вместе с деревом;
- SIGTERM всем, сначала глубоким; до 5 с ждём; SIGKILL только тем, кто жив и всё ещё тот же процесс;
- агенты — только launchctl в gui/<uid> через paths.LAUNCHCTL; никогда com.apple.*, боты, сама панель и
  системный домен; запреты, состояние и plist сверяем заново перед командой;
- одно действие за раз; каждое — строка JSON в actions.log.
"""

import json
import logging
import os
import re
import shlex
import signal
import subprocess
import threading
import time

from . import agents, attrib, paths, registry, sessions, system
from . import procs as procs_mod

log = logging.getLogger(__name__)

GRACE_S = 5.0
SPEC_MAX_AGE_S = 5.0  # action_id ищем в снимке не старше этого
BOT_TIMEOUT_S = 60.0
AGENT_TIMEOUT_S = 30.0
AGENT_WAIT_S = 3.0  # после bootout ждём, пока launchctl list перестанет показывать pid агента
OUT_MAX = 500
STALE = "Действие устарело — обнови панель"
GONE = "Процесс уже завершился — обнови панель"
_STOP_ID = re.compile(r"stop:proc:(\d{1,7}):([0-9a-f]+)")
SYSTEM_NAMES = frozenset({"WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer", "ControlCenter"})
SYSTEM_DIRS = ("/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/")
DONE = {"start": "Включён", "stop": "Выключен", "restart": "Перезапущен"}


class ActionError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status, self.message = status, message


def fmt_mb(mb: float) -> str:
    return f"{mb / 1024:.1f} GB" if mb >= 1024 else f"{round(mb)} MB"


def plural(n: int, one: str, few: str, many: str) -> str:
    if n % 10 == 1 and n % 100 != 11:
        return one
    return few if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14 else many


def procs_word(n: int) -> str:
    return f"{n} {plural(n, 'процесс', 'процесса', 'процессов')}"


def fence(procs, bots, launchd, self_pid: int | None = None) -> dict[int, str]:
    """pid → почему не трогаем: панель и её предки, всё дерево сессии Claude, из которой запущена панель,
    процессы ботов из bots.toml со всеми потомками и сессии Claude, которые ведёт приложение."""
    me = self_pid or os.getpid()
    kids = procs_mod.children(procs)
    ups = procs_mod.ancestors(procs, me)
    out = {me: "это сама панель"} | {pid: "предок панели" for pid in ups}
    for pid in ups:
        if pid in procs and sessions.is_claude(procs[pid]):
            for q in procs_mod.tree(procs, pid, kids):
                out.setdefault(q, "сессия, из которой запущена панель")
    for b in bots:
        for main in registry.bot_pids(b, procs, launchd):
            for q in procs_mod.tree(procs, main, kids):
                out.setdefault(q, f"процесс бота {b.id} — только его кнопками")
    # .app панель не останавливает: убить агента Claude.app значит сломать чат, а не освободить память
    for p in procs.values():
        if sessions.is_claude(p) and (app := sessions.host_app(p, procs)):
            out.setdefault(p.pid, f"сессией управляет {app}.app")
    return out


def why_protected(p, fenced: dict[int, str], root: bool = True) -> str | None:
    """Почему процесс нельзя трогать, или None. root — цель действия: системный файл ею быть не может, кроме
    шелла (вкладка терминала, шелл сессии). Потомок цели — свой процесс пользователя, даже если это sleep или ssh."""
    if p.pid <= 1:
        return "системный процесс"
    if p.pid in fenced:
        return fenced[p.pid]
    if p.user != os.getuid():
        return "процесс другого пользователя"
    if p.name in SYSTEM_NAMES or os.path.basename(p.exe) in SYSTEM_NAMES:
        return "системный процесс"
    if attrib.terminal_app(p):
        return "хост вкладок терминала"
    if not p.exe:
        return "не удалось прочитать путь"
    shell = p.exe.startswith("/bin/") and os.path.basename(p.exe) in sessions.SHELLS
    if root and p.exe.startswith(SYSTEM_DIRS) and not p.exe.startswith("/usr/local/") and not shell:
        return "системный файл"
    return None


def _signal(pid: int, sig: int) -> bool:
    try:
        os.kill(pid, sig)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        log.warning("нет прав на сигнал %d процессу %d", sig, pid)
        return False


def _alive(items: list[tuple[int, str]]) -> list[tuple[int, str]]:
    return [(pid, uid) for pid, uid in items if procs_mod.identity(pid) == uid]


def stop_tree(tree: list[tuple[int, str]], grace_s: float = GRACE_S, mem: dict[int, float] | None = None) -> dict:
    """SIGTERM каждой цели (список уже от глубоких к корню), до grace_s ждём выхода, затем SIGKILL тем,
    кто жив и всё ещё тот же процесс. Перед каждым сигналом uniqueid сверяется заново."""
    termed = [(pid, uid) for pid, uid in tree if procs_mod.identity(pid) == uid and _signal(pid, signal.SIGTERM)]
    left, deadline = termed, time.monotonic() + grace_s
    while left and time.monotonic() < deadline:
        time.sleep(0.05)
        left = _alive(left)
    killed = [(pid, uid) for pid, uid in left if procs_mod.identity(pid) == uid and _signal(pid, signal.SIGKILL)]
    survived, deadline = killed, time.monotonic() + 1.0
    while survived and time.monotonic() < deadline:
        time.sleep(0.02)
        survived = _alive(survived)
    gone = {pid for pid, _ in termed} - {pid for pid, _ in survived}
    return {"stopped": len(termed) - len(killed), "killed": len(killed) - len(survived), "survived": len(survived),
            "freed_mb": round(sum((mem or {}).get(pid, 0.0) for pid in gone))}


def _stop(spec, grace_s: float, record: dict) -> dict:
    now = procs_mod.identity(spec.pid)
    if now is None:
        raise ActionError(409, GONE)
    if now != spec.uid:
        raise ActionError(409, "Процесс сменился: этот PID уже занят другим процессом — обнови панель")
    procs = procs_mod.scan()
    launchd = system.launchd_jobs()
    if not launchd:  # без списка заданий не отличить процесс бота от сироты
        raise ActionError(500, "launchctl не ответил — не могу проверить ботов, повтори позже")
    fenced = fence(procs, registry.load(paths.BOTS_TOML), launchd)
    root = procs.get(spec.pid)
    if root is not None and root.uid == spec.uid and (why := why_protected(root, fenced)):
        raise ActionError(403, f"Не трогаю {root.name}: {why}")
    targets, kept = [], []
    for pid, uid in spec.tree:
        p = procs.get(pid)
        if p is None or p.uid != uid:
            continue  # уже завершился, а если pid занят другим — тем более не трогаем
        if why := why_protected(p, fenced, root=pid == spec.pid):
            kept.append(f"{p.name} ({why})")
            continue
        targets.append((pid, uid))
        record["targets"].append({"pid": pid, "uid": uid, "name": p.name})
    if not targets:
        msg = "Нечего останавливать: процессы уже завершились"
        return {"ok": True, "message": msg + (f". Не тронуты: {', '.join(kept[:5])}" if kept else ""), "freed_mb": 0}
    r = stop_tree(targets, grace_s, {pid: procs_mod.mem(procs[pid]) for pid, _ in targets})
    n = r["stopped"] + r["killed"]
    msg = f"Остановлено {procs_word(n)}, освобождено ≈{fmt_mb(r['freed_mb'])}"
    if r["killed"]:
        msg += f" ({r['killed']} — только через SIGKILL)"
    if r["survived"]:
        msg += f". Не завершились даже после SIGKILL: {r['survived']}"
    if kept:
        msg += f". Не тронуты: {', '.join(kept[:5])}" + ("…" if len(kept) > 5 else "")
    return {"ok": True, "message": msg, "freed_mb": r["freed_mb"]}


def _clip(text: str) -> str:
    return text if len(text) <= OUT_MAX else "…" + text[-(OUT_MAX - 1):]


def _bot(spec, record: dict) -> dict:
    bot = next((b for b in registry.load(paths.BOTS_TOML) if b.id == spec.bot_id), None)
    argv = getattr(bot, spec.verb, None) if bot is not None and spec.verb in DONE else None
    if not argv:
        raise ActionError(400, STALE)
    if not isinstance(argv, list) or not all(isinstance(a, str) and a for a in argv):
        raise ActionError(500, f"В bots.toml команда {spec.verb} бота {bot.id} — не список строк")
    cmd = record["command"] = shlex.join(argv)
    home = os.environ.get("HOME") or os.path.expanduser("~")
    # без shell и без окружения панели: только HOME и PATH, как у launchd-агента с ~/.local/bin
    env = {"HOME": home, "PATH": f"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:{home}/.local/bin"}
    try:
        r = subprocess.run(argv, env=env, cwd=home, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           errors="replace", timeout=BOT_TIMEOUT_S, start_new_session=True)
    except subprocess.TimeoutExpired:
        raise ActionError(500, f"Команда не уложилась в {BOT_TIMEOUT_S:g} с: {cmd}") from None
    except OSError as e:
        raise ActionError(500, f"Не удалось запустить {cmd}: {e.strerror or e}") from None
    record["output"] = _clip((r.stdout + r.stderr).strip())
    if r.returncode != 0:
        err = _clip(r.stderr.strip() or r.stdout.strip())
        raise ActionError(500, f"Команда завершилась с кодом {r.returncode}" + (f": {err}" if err else ""))
    return {"ok": True, "message": f"{DONE[spec.verb]}: {bot.name}", "freed_mb": 0}


AGENT_DONE = {"stop": "Остановлен до следующего входа", "disable": "Остановлен и убран из автозапуска",
              "enable": "Возвращён в автозапуск"}


def _agent_pid(label: str) -> int | None:
    """pid агента по свежему launchctl list, пока он не пропадёт, но не дольше AGENT_WAIT_S."""
    deadline = time.monotonic() + AGENT_WAIT_S
    while (pid := system.launchd_jobs().get(label)) and time.monotonic() < deadline:
        time.sleep(0.1)
    return pid


def _agent(spec, record: dict) -> dict:
    label = spec.agent or ""
    bots = registry.load(paths.BOTS_TOML)
    system_job = spec.domain != "gui" or label in agents.plists(agents.SYSTEM_DIRS)
    if why := agents.why_refused(label, "system" if system_job else "gui", agents.bot_labels(bots)):
        raise ActionError(403, f"Не трогаю {label}: {why}")
    jobs = system.launchd_jobs()
    if not jobs:
        raise ActionError(500, "launchctl не ответил — повтори позже")
    loaded, pid = label in jobs, jobs.get(label)
    procs = procs_mod.scan()
    tree = procs_mod.tree(procs, pid) if pid in procs else []
    if why := agents.why_tree(procs, tree, fence(procs, bots, jobs)):
        raise ActionError(403, f"Не трогаю {label}: {why}")
    if spec.verb == "stop" and not loaded:
        raise ActionError(409, "Агент уже остановлен — обнови панель")
    plist = spec.plist if spec.verb == "enable" and not loaded else None
    if plist and not agents.own_plist(plist, label):
        raise ActionError(409, "plist агента сменился или лежит не в LaunchAgents — обнови панель")
    record["targets"].append({"label": label, "pid": pid})
    cmds = agents.argv(spec.verb, label, plist, loaded)
    record["command"] = " && ".join(map(shlex.join, cmds))
    out = []
    for argv in cmds:
        try:
            r = system.launchctl(argv, timeout=AGENT_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            raise ActionError(500, f"launchctl не уложился в {AGENT_TIMEOUT_S:g} с: {shlex.join(argv)}") from None
        except OSError as e:
            raise ActionError(500, f"Не удалось запустить launchctl: {e.strerror or e}") from None
        out.append((r.stdout + r.stderr).strip())
        record["output"] = _clip("\n".join(filter(None, out)))
        if r.returncode != 0:
            err = _clip(r.stderr.strip() or r.stdout.strip())
            # выключенное в «Объектах входа» (Background Task Management) launchctl не вернёт
            btm = (" Если агент выключен в «Системные настройки → Основные → Объекты входа», включи его там."
                   if spec.verb == "enable" else "")
            raise ActionError(500, f"launchctl {argv[1]} завершился с кодом {r.returncode}" + (f": {err}." if err else ".")
                              + btm)
    # bootout мог отработать без ошибки, а процесс — остаться: верим только launchctl list
    if spec.verb in ("stop", "disable") and loaded and (left := _agent_pid(label)):
        err = record.get("output", "")
        raise ActionError(500, f"Агент не остановился: launchctl list всё ещё показывает pid {left}" + (f". {err}" if err else ""))
    freed = round(sum(procs_mod.mem(procs[q]) for q in tree)) if spec.verb != "enable" else 0
    done = "Убран из автозапуска" if spec.verb == "disable" and not tree else AGENT_DONE[spec.verb]  # процесса не было
    return {"ok": True, "message": f"{done}: {label}", "freed_mb": freed}


def _log(action_id, spec, record: dict, result: str, message: str) -> None:
    line = {"ts": int(time.time()), "action_id": str(action_id)[:200], "kind": getattr(spec, "kind", None),
            "label": getattr(spec, "label", ""), "targets": record["targets"], "result": result, "message": message}
    line.update({k: record[k] for k in ("command", "output") if k in record})
    log.info("действие %s: %s", line["action_id"], message)
    try:
        paths.LOGS.mkdir(parents=True, exist_ok=True)
        with open(paths.LOGS / "actions.log", "a", encoding="utf-8") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
    except OSError as e:
        log.warning("actions.log не пишется: %s", e)


_lock = threading.Lock()


def _gone(action_id) -> bool:
    """id остановки из старого снимка, чей процесс уже завершился: pid свободен или занят другим процессом."""
    m = _STOP_ID.fullmatch(action_id) if isinstance(action_id, str) else None
    return bool(m) and procs_mod.identity(int(m[1])) != m[2]


def execute(action_id: str, specs: dict, *, grace_s: float = GRACE_S) -> dict:
    """Выполнить действие из серверного снимка: {"ok": True, "message", "freed_mb"} или ActionError
    (400 — нет такого, 403 — защищённая цель, 409 — процесс уже завершился или сменился, агент уже остановлен
    или идёт другое действие, 500 — сбой команды)."""
    spec = specs.get(action_id) if isinstance(action_id, str) else None
    record: dict = {"targets": []}
    try:
        if not _lock.acquire(blocking=False):
            raise ActionError(409, "Уже выполняется другое действие")
        try:
            if spec is None and _gone(action_id):
                raise ActionError(409, GONE)
            if spec is None or spec.kind not in ("stop-tree", "bot", "agent"):
                raise ActionError(400, STALE)
            if spec.kind == "bot":
                result = _bot(spec, record)
            elif spec.kind == "agent":
                result = _agent(spec, record)
            else:
                result = _stop(spec, grace_s, record)
        finally:
            _lock.release()
    except ActionError as e:
        _log(action_id, spec, record, "error", e.message)
        raise
    except Exception:
        _log(action_id, spec, record, "error", "внутренняя ошибка")
        raise
    _log(action_id, spec, record, "ok", result["message"])
    return result
