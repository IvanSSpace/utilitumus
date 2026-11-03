"""Снимок системы для GET /api/snapshot и действия к нему.

Клиент получает только action_id с подписью, текстом подтверждения и списком целей; что именно делать
(pid, uniqueid, дерево, бот и глагол) остаётся в ActionSpec на сервере — исполняет actions.execute.
"""

import os
import shlex
import threading
import time
from collections import Counter
from dataclasses import dataclass, field

from . import actions, advice, agents, attrib, disk, paths, registry, sessions, system
from . import procs as procs_mod

HEAVY_MB = 500  # потомок сессии тяжелее этого получает свою кнопку «Остановить»
VERBS = {"start": "Включить", "stop": "Выключить", "restart": "Перезапустить"}
TOP_N = 15
FRESH_EVERY_S = 5.0  # «Обновить» пересобирает всё не чаще раза в 5 с
FRESH_TOP_S = 5.0
BUSY = "Сессия сейчас работает — остановка прервёт задачу"
WIRED_NOTE = ("Ядро macOS, драйверы и видеопамять GPU — на Apple Silicon память общая. Напрямую не освобождается; "
              "уменьшается, если закрыть тяжёлые графические приложения")
CACHED_NOTE = "Недавно прочитанные файлы. macOS сама отдаст эту память, когда понадобится — это не потеря"
# карта памяти
SPLIT_TOP = 8
CANDIDATES = 12
CLEANABLE = {"app": "yes", "compressed": "yes", "wired": "partly", "cached": "no", "free": "no"}
HINTS = {
    "macos": "Это сама macOS: WindowServer, Spotlight, Finder и службы. Напрямую не освободить — что помогает, "
             "смотри в подсказках группы «Система»",
    "browser": "Закрой лишние вкладки: каждая — отдельный процесс «вкладка». В Chrome помогает «Экономия памяти» "
               "(Настройки → Производительность), тяжёлую вкладку видно в «Окно → Диспетчер задач»",
    "app": "Закрой приложение, если оно сейчас не нужно (⌘Q)",
    "project": "Процессы проекта без кнопки: останови их там, где запускал, — в терминале или IDE",
    "other": "Процессы без проекта и приложения — полный список по кнопке «показать все» в группе",
}
FINDER_BASE_MB = 150  # столько Finder держит сразу после перезапуска
SPOTLIGHT_MB = 200
fmt_mb = actions.fmt_mb


@dataclass
class ActionSpec:
    id: str
    kind: str  # "stop-tree" | "bot" | "agent"
    label: str
    confirm: str
    pid: int | None = None
    uid: str | None = None
    tree: list[tuple[int, str]] = field(default_factory=list)  # (pid, uniqueid): сначала глубокие, корень последним
    bot_id: str | None = None
    verb: str | None = None
    targets: list[dict] = field(default_factory=list)  # что остановится: {pid, name, mb}, без защищённых
    warning: str = ""
    command: str = ""  # у бота и агента — команда для показа
    agent: str | None = None  # метка launchd
    plist: str | None = None
    domain: str = ""  # у агента — всегда "gui": системный домен действий не получает


def fmt_age(s: float) -> str:
    s = int(s)
    if s < 60:
        return "меньше минуты"
    return f"{s // 60} мин" if s < 3600 else f"{s // 3600} ч" if s < 2 * 86400 else f"{s // 86400} д"


class _Actions:
    def __init__(self, procs: dict, bots: list, launchd: dict):
        self.procs = procs
        self.kids = procs_mod.children(procs)
        self.fenced = actions.fence(procs, bots, launchd)
        self.specs: dict[str, ActionSpec] = {}

    def tree(self, pid: int) -> list[int]:
        return procs_mod.tree(self.procs, pid, self.kids)

    def stop(self, pid: int, label: str, head: str, tail: str = "", warning: str = "") -> str | None:
        """Кнопка «Остановить» для pid и его потомков. None — сам pid трогать нельзя (панель, система, бот…).
        Подтверждение: head, сколько ещё процессов и MB, tail, защищённые потомки."""
        p = self.procs.get(pid)
        if not p or actions.why_protected(p, self.fenced):
            return None
        tree = self.tree(pid)
        kept = [q for q in tree if actions.why_protected(self.procs[q], self.fenced, root=q == pid)]
        others = sorted((q for q in tree if q != pid and q not in kept), key=lambda q: -procs_mod.mem(self.procs[q]))
        mb = sum(procs_mod.mem(self.procs[q]) for q in (pid, *others))
        confirm = (f"{head}, освободит ≈{fmt_mb(mb)}." + (f" Остановятся также: {self._names(others)}." if others else "")
                   + (f" {tail}" if tail else "") + (f" Не тронет защищённые: {self._names(kept)}." if kept else "")
                   + " Сначала SIGTERM, через 5 с — SIGKILL.")
        aid = f"stop:proc:{pid}:{p.uid}"
        self.specs[aid] = ActionSpec(
            aid, "stop-tree", label, confirm, pid=pid, uid=p.uid, tree=[(q, self.procs[q].uid) for q in tree],
            targets=[{"pid": q, "name": procs_mod.label(self.procs[q]), "mb": round(procs_mod.mem(self.procs[q]))}
                     for q in (pid, *others)],
            warning=warning)
        return aid

    def _names(self, pids: list[int]) -> str:
        """«node ×2, zsh, Python и ещё 3» — в порядке убывания памяти."""
        counts = Counter(self.procs[q].name for q in pids)
        parts = [f"{n} ×{c}" if c > 1 else n for n, c in counts.items()]
        return ", ".join(parts[:4]) + (f" и ещё {len(parts) - 4}" if len(parts) > 4 else "")

    def bot(self, spec: registry.BotSpec, verb: str) -> None:
        aid = f"bot:{spec.id}:{verb}"
        argv = getattr(spec, verb)
        cmd = shlex.join(argv) if isinstance(argv, list) else str(argv)
        confirm = f"Выполнит {cmd}." + (f" {spec.note}" if spec.note else "")
        self.specs[aid] = ActionSpec(aid, "bot", f"{VERBS[verb]} {spec.name}", confirm, bot_id=spec.id, verb=verb,
                                     command=cmd)

    def agent(self, a: dict, verb: str) -> str:
        """Кнопка агента launchd: подтверждение называет последствие из каталога производителей."""
        aid = f"agent:{a['label']}:{verb}"
        cmds = agents.argv(verb, a["label"], a["plist"], a["_loaded"])
        what = a["name"] + (f" от {a['vendor']}" if a["vendor"] else "")
        note = a["note"][:1].upper() + a["note"][1:]
        freed = f" Освободит ≈{fmt_mb(a['mem_mb'])}." if a["mem_mb"] else ""
        if verb == "stop":
            label = f"Остановить {a['name']}"
            confirm = (f"Остановит фоновый агент {what} до следующего входа в систему (launchctl bootout).{freed} {note}."
                       + (" После перезагрузки запустится снова." if a["run_at_load"] or a["keepalive"] else ""))
        elif verb == "disable":
            label = f"Убрать {a['name']} из автозапуска"
            if a["pids"]:
                head = f"Остановит {what} и уберёт из автозапуска (launchctl bootout и disable).{freed}"
            elif a["_loaded"]:  # загружен, ждёт запуска: остановить нечего, но выгрузить надо — иначе запустится сам
                head = (f"Уберёт {what} из автозапуска (launchctl bootout и disable): сейчас он не запущен, "
                        "а теперь не запустится ни сам, ни при следующем входе.")
            else:
                head = f"Уберёт {what} из автозапуска (launchctl disable): при следующем входе не запустится."
            confirm = head + f" {note}. Вернуть — кнопкой «Вернуть» в «Фоновых агентах»."
        else:
            label = f"Вернуть {a['name']}"
            start = " и запустит" if len(cmds) > 1 else ", запустится при следующем входе"
            confirm = f"Вернёт {what} в автозапуск{start} (launchctl {' и '.join(c[1] for c in cmds)})."
        tree = sorted(a["_tree"], key=lambda q: (q not in a["pids"], -procs_mod.mem(self.procs[q])))
        self.specs[aid] = ActionSpec(
            aid, "agent", label, confirm, verb=verb, agent=a["label"], plist=a["plist"], domain="gui",
            targets=[] if verb == "enable" else [{"pid": q, "name": procs_mod.label(self.procs[q]),
                                                   "mb": round(procs_mod.mem(self.procs[q]))} for q in tree],
            command=" && ".join(map(shlex.join, cmds)))
        return aid


def _resume(s: dict, what: str = "") -> str:
    if s["resume_cmd"]:
        return f"Продолжить {what}потом: {s['resume_cmd']}"
    return "sessionId неизвестен — продолжить через --resume не выйдет."


def _session_actions(acts: _Actions, s: dict, now: float) -> None:
    busy = s["status"] in ("busy", "shell")
    s["action_id"] = None if s["is_self"] else acts.stop(
        s["pid"], f"Остановить сессию {s['name']}", f"Остановит сессию Claude «{s['name']}»", _resume(s),
        BUSY if busy else "")
    for c in s["children"]:
        heavy = c["kind"] == "dev-server" or (c["mem_mb"] or 0) >= HEAVY_MB
        p = acts.procs.get(c["pid"])
        what = "dev-сервер" if c["kind"] == "dev-server" else "процесс"
        age = f", работает {fmt_age(now - p.start_ts)}" if p and p.start_ts else ""
        c["action_id"] = acts.stop(c["pid"], f"Остановить {c['name']}",
                                   f"Остановит {c['name']} — {what} сессии «{s['name']}»{age}",
                                   "Сама сессия останется.") if heavy else None


def _shell_action(acts: _Actions, sh: dict, by_pid: dict) -> str | None:
    tty = sh["tty"] or str(sh["pid"])
    where = f" ({sh['project']})" if sh["project"] else ""
    hosted = [by_pid[q] for q in acts.tree(sh["pid"]) if q in by_pid]
    if not hosted:
        return acts.stop(sh["pid"], f"Закрыть шелл {tty}{where}", f"Закроет шелл {tty}{where}")
    s = hosted[0]
    names = ", ".join(f"«{x['name']}»" for x in hosted)
    busy = any(x["status"] in ("busy", "shell") for x in hosted)
    return acts.stop(sh["pid"], f"Закрыть шелл {tty}{where}",
                     f"Закроет шелл {tty}{where} и убьёт сессию Claude {names}", _resume(s, "сессию "),
                     BUSY if busy else f"Вместе с шеллом завершится сессия Claude {names}")


def _shell_children(acts: _Actions, sh: dict, skip: set[int], now: float) -> list[dict]:
    """dev-серверы и тяжёлые процессы вкладки, кроме сессий Claude в ней (у них своя карточка), — со своей кнопкой:
    остановить их, не закрывая шелл."""
    tty, out = sh["tty"] or str(sh["pid"]), []
    for q in acts.tree(sh["pid"])[:-1]:
        p = acts.procs[q]
        if q in skip or (sessions.child_kind(p) != "dev-server" and procs_mod.mem(p) < HEAVY_MB):
            continue
        c = sessions._child(p, now)
        what = "dev-сервер" if c["kind"] == "dev-server" else "процесс"
        c["action_id"] = acts.stop(q, f"Остановить {c['name']}",
                                   f"Остановит {c['name']} — {what} во вкладке {tty}, работает {fmt_age(c['age_s'])}",
                                   "Шелл останется.")
        out.append(c)
    return sorted(out, key=lambda c: -(c["mem_mb"] or 0))


def _breakdown(procs: dict, assigned: dict, names: dict, stop_ids: dict) -> dict:
    """Что лежит в сегментах полосы памяти (по клику): приложения, сжатое, wired (от 1 MB), кэш файлов."""
    swapped = sorted(((procs_mod.swapped(p), p) for p in procs.values()), key=lambda x: -x[0])
    wired = sorted((p for p in procs.values() if (p.wired_mb or 0) >= 1), key=lambda p: -p.wired_mb)
    return {
        "app": attrib.ram_split(procs, assigned)[:TOP_N],
        "compressed": [{"pid": p.pid, "uid": p.uid, "name": procs_mod.label(p),
                        "group": names.get(assigned.get(p.pid, ("",))[0], ""), "mb": round(mb),
                        "action_id": stop_ids.get(p.pid)} for mb, p in swapped[:TOP_N] if round(mb) > 0],
        "wired": {"top": [{"pid": p.pid, "name": procs_mod.label(p), "mb": round(p.wired_mb, 1)} for p in wired[:10]],
                  "note": WIRED_NOTE},
        "cached": {"note": CACHED_NOTE},
    }


def _helper_actions(acts: _Actions, launchd: dict) -> dict[int, str]:
    """Фоновые приложения: корень .app без окна в Dock, запущенный не агентом launchd — у агента
    KeepAlive и свои кнопки. Без списка launchd их не отличить, поэтому тогда кнопок нет. pid → action_id."""
    if not launchd:
        return {}
    managed = {pid for label, pid in launchd.items() if pid and not label.startswith("application.")}
    me, out = os.getuid(), {}
    for p in acts.procs.values():
        if p.ppid != 1 or p.user != me or p.pid in managed or ".app/" not in p.exe:
            continue
        app = attrib.background_app(p.exe)
        if app and (aid := acts.stop(p.pid, f"Закрыть {app}", f"Закроет фоновое приложение {app} (без окна в Dock)",
                                     "Открыть снова — из «Программ» или Spotlight.")):
            out[p.pid] = aid
    return out


def _split(raw: dict[str, float], total: int, names: dict[str, str]) -> list[dict]:
    """Сегмент vm_stat по группам: macOS, 8 самых больших программ, прочее (с группой «без признаков») —
    в сумме ровно total: доли — по оценкам процессов, они с vm_stat один в один не сходятся."""
    top = sorted((g for g in raw if g not in ("system", "other") and raw[g] > 0), key=lambda g: -raw[g])[:SPLIT_TOP]
    rest = sum(raw.values()) - raw.get("system", 0.0) - sum(raw[g] for g in top)
    mbs = attrib.fit([raw.get("system", 0.0), *(raw[g] for g in top), max(0.0, rest)], total)
    return ([{"key": "macos", "name": "macOS", "mb": mbs[0], "color_key": "system"}]
            + [{"key": g, "name": names.get(g, g), "mb": mb, "color_key": g} for g, mb in zip(top, mbs[1:-1])]
            + [{"key": "rest", "name": "прочее", "mb": mbs[-1], "color_key": "rest"}])


def _hint(gid: str, kind: str, name: str) -> str:
    if gid == "system":
        return HINTS["macos"]
    if kind == "app":
        return HINTS["browser"] if procs_mod.app_short(name) in procs_mod.BROWSERS else HINTS["app"]
    return HINTS["project"] if kind == "project" else HINTS["other"]


def memory_map(procs: dict, assigned: dict, groups: list[dict], memory: dict,
               group_actions: dict[str, list[tuple[str, int]]]) -> dict:
    """Карта памяти: «Приложения» — по оценкам в RAM, «Сжато» — по сжатому у процессов; сводка
    macOS/программы; что чистится; что можно освободить — группы по убыванию, с кнопками и подсказкой, если
    кнопки освобождают меньше половины группы (у браузера на 3 GB бывает только кнопка его апдейтера на 11 MB)."""
    ram: dict[str, float] = {}
    cmp: dict[str, float] = {}
    for pid, (gid, _why, _path) in assigned.items():
        p = procs[pid]
        ram[gid] = ram.get(gid, 0.0) + attrib.in_ram(p)
        cmp[gid] = cmp.get(gid, 0.0) + procs_mod.swapped(p)
    names = {g["id"]: g["name"] for g in groups}
    kinds = {g["id"]: g["kind"] for g in groups}
    sizes = {g["id"]: g["mem_mb"] for g in groups}
    split = {"app": _split(ram, memory["app_mb"], names), "compressed": _split(cmp, memory["compressed_mb"], names)}
    macos = split["app"][0]["mb"] + split["compressed"][0]["mb"]
    k_ram = memory["app_mb"] / s if (s := sum(ram.values())) > 0 else 0.0
    k_cmp = memory["compressed_mb"] / s if (s := sum(cmp.values())) > 0 else 0.0
    cands = []
    for gid in ram:
        r, c = round(ram[gid] * k_ram), round(cmp[gid] * k_cmp)
        if r + c <= 0:
            continue
        acts = [] if gid == "system" else group_actions.get(gid, [])
        covered = bool(acts) and 2 * max(mb for _aid, mb in acts) >= sizes.get(gid, 0)
        cands.append({"key": "macos" if gid == "system" else gid, "name": "macOS" if gid == "system" else names.get(gid, gid),
                      "ram_mb": r, "compressed_mb": c, "action_ids": [aid for aid, _mb in acts],
                      "hint": "" if covered else _hint(gid, kinds.get(gid, ""), names.get(gid, ""))})
    cands.sort(key=lambda c: -(c["ram_mb"] + c["compressed_mb"]))
    return {
        "summary": {"macos_mb": macos, "programs_mb": memory["app_mb"] + memory["compressed_mb"] - macos,
                    "cache_mb": memory["cached_mb"], "wired_mb": memory["wired_mb"]},
        "split": split,
        "cleanable": dict(CLEANABLE),
        "free_candidates": cands[:CANDIDATES],
    }


def system_hints(procs: dict) -> list[dict]:
    """Что на деле помогает с памятью «Системы» — только для того, что сейчас запущено."""
    by: dict[str, float] = {}
    for p in procs.values():
        by[p.name] = by.get(p.name, 0.0) + procs_mod.mem(p)
    spotlight = sum(mb for name, mb in by.items() if name.startswith(("mds", "mdworker")))
    hints = []
    if by.get("Finder", 0.0) > FINDER_BASE_MB:
        hints.append({"title": "Перезапусти Finder",
                      "how": "Option + правый клик по Finder в Dock → «Перезапустить»: окна Finder закроются, файлы "
                             "не пострадают",
                      "saves_mb": round(by["Finder"] - FINDER_BASE_MB)})
    if "WallpaperDynamicExtension" in by:
        hints.append({"title": "Статичные обои вместо динамических",
                      "how": "Системные настройки → Обои: выбери обычную картинку — динамическим обоям нужен "
                             "отдельный процесс",
                      "saves_mb": round(by["WallpaperDynamicExtension"])})
    if spotlight > SPOTLIGHT_MB:
        hints.append({"title": "Spotlight индексирует код",
                      "how": "Системные настройки → Spotlight → Конфиденциальность: добавь папки с проектами и "
                             "node_modules",
                      "saves_mb": round(spotlight - SPOTLIGHT_MB)})
    if "WindowServer" in by:
        hints.append({"title": "Меньше окон — меньше WindowServer",
                      "how": "Его память растёт с числом окон и экранов: закрой лишние окна, особенно браузерные, "
                             "и отключи ненужный монитор",
                      "saves_mb": 0})
    return hints


def _group_actions(specs: dict[str, ActionSpec], assigned: dict, bot_items: list[dict]) -> dict[str, list[tuple[str, int]]]:
    """Группа → действия, которые освобождают её память (стоп процессов, стоп и «убрать» агентов, выключение
    ботов), с MB, по убыванию."""
    bots = {b["id"]: b for b in bot_items}
    sized = []
    for aid, a in specs.items():
        mb = sum(t["mb"] for t in a.targets)
        if a.kind == "stop-tree":
            root = a.pid
        elif a.kind == "agent" and a.verb in ("stop", "disable") and a.targets:
            root = a.targets[0]["pid"]
        elif a.kind == "bot" and a.verb == "stop" and (b := bots.get(a.bot_id)) and b["pids"]:
            root, mb = b["pids"][0], b["mem_mb"]
        else:
            continue
        if root in assigned:
            sized.append((-mb, aid, assigned[root][0]))
    out: dict[str, list[tuple[str, int]]] = {}
    for mb, aid, gid in sorted(sized):
        out.setdefault(gid, []).append((aid, -mb))
    return out


_cpu = {"t": 0.0, "wall": 0.0}


def _self(procs: dict) -> dict:
    t, wall = time.process_time(), time.monotonic()
    pct = (t - _cpu["t"]) / (wall - _cpu["wall"]) * 100 if _cpu["wall"] and wall > _cpu["wall"] else 0.0
    _cpu.update(t=t, wall=wall)
    me = procs.get(os.getpid())
    return {"pid": os.getpid(), "mem_mb": round(procs_mod.mem(me), 1) if me else 0, "cpu_pct": round(pct, 1)}


_ctx: dict = {}  # последний build(): процессы, группы и кнопки — для GET /api/group/<id>


def _launchd(procs: dict, fresh: bool = False) -> dict:
    """launchctl зовём, только когда сменились свои прямые потомки launchd: бот перезапустился, процесс осиротел.
    Системные (mdworker_shared и т.п.) появляются каждые несколько секунд и ботами не бывают."""
    me = os.getuid()
    return system.launchd_jobs(frozenset((p.pid, p.uid) for p in procs.values()
                                         if p.ppid == 1 and p.user == me and not attrib.system_path(p.exe)),
                               max_age_s=0 if fresh else 60.0)


def _claude(procs: dict) -> list[dict]:
    return sessions.claude_sessions(procs, paths.CLAUDE_SESSIONS_DIR, paths.CLAUDE_PROJECTS_DIR, paths.PROJECT_ROOTS)


def build(fresh: bool = False) -> tuple[dict, dict[str, ActionSpec]]:
    """fresh — «Обновить»: top для root синхронно (до 5 с), launchctl, флаги автозапуска и bundle id перечитываются."""
    global _ctx
    if fresh:
        system.root_footprints_now(FRESH_TOP_S)
        registry._bundles.clear()
        agents.forget()
    else:
        system.root_footprints()  # top для root-процессов — в фоне и не чаще раза в 5 мин
    procs = procs_mod.scan()
    launchd = _launchd(procs, fresh)
    roots = paths.PROJECT_ROOTS
    bots = registry.load(paths.BOTS_TOML)
    claude = _claude(procs)
    terms = sessions.terminals(procs, roots)
    # без списка launchd не отличить сироту от KeepAlive-бота, а kill такого — перезапуск, а не стоп
    orphans = sessions.orphans(procs, {pid for pid in launchd.values() if pid}) if launchd else []
    assigned = attrib.assign(procs, roots, claude, bots, launchd)
    groups = attrib.groups(procs, roots, claude, bots, launchd, assigned)
    ai_mem = sessions.ai_mem(procs, claude)
    bot_items = [registry.status(b, procs, launchd) for b in bots]

    acts = _Actions(procs, bots, launchd)
    now = time.time()
    by_pid = {s["pid"]: s for s in claude}
    in_sessions = {q for s in claude for q in s["_tree"]}
    for s in claude:
        s.pop("_tree")
        _session_actions(acts, s, now)
    for t in terms:
        for sh in t["shells"]:
            sh["action_id"] = _shell_action(acts, sh, by_pid)
            sh["children"] = _shell_children(acts, sh, in_sessions, now)
    for o in orphans:
        o.pop("_tree")
        o["action_id"] = acts.stop(o["pid"], f"Остановить {o['name']}",
                                   f"Остановит {o['name']} — сирота: {o['reason']}, работает {fmt_age(o['age_s'])}")
    for b, st in zip(bots, bot_items):
        for verb in st["actions"]:  # только то, что позволяет статус: у запущенного нет «Включить»
            acts.bot(b, verb)
    helpers = _helper_actions(acts, launchd)
    agent_items = agents.collect(procs, launchd, bots, acts.fenced)
    for a in agent_items:
        a["actions"] = {verb: acts.agent(a, verb) for verb in a.pop("_verbs")}
        del a["_tree"], a["_loaded"]

    memory = system.memory()
    stop_ids = {a.pid: aid for aid, a in acts.specs.items() if a.kind == "stop-tree"}
    memory["breakdown"] = _breakdown(procs, assigned, {g["id"]: g["name"] for g in groups}, stop_ids)
    memory.update(memory_map(procs, assigned, groups, memory, _group_actions(acts.specs, assigned, bot_items)))
    for g in groups:
        if g["id"] == "system":
            g["hints"] = system_hints(procs)
    snap = {
        "ts": int(now),
        "host": system.host(),
        "memory": memory,
        "groups": groups,
        "sessions": {"claude": claude, "terminals": terms, "tmux": sessions.tmux(), "docker": sessions.docker(),
                     "orphans": orphans},
        "bots": bot_items,
        "agents": agent_items,
        "advice": [],
        "actions": {aid: {"kind": "stop" if a.kind == "stop-tree" else a.verb, "label": a.label, "confirm": a.confirm,
                          "targets": a.targets, "warning": a.warning, "command": a.command}
                    for aid, a in acts.specs.items()},
        "ai_mem": ai_mem,
        "self": _self(procs),
        "disk": disk.get(),
    }
    snap["advice"] = advice.get(snap, acts.specs, now)
    # для /api/group/<id>: у каждого процесса — его кнопка (стоп дерева, стоп агента, выключение бота) и вид
    pid_action = {pid: f"bot:{st['id']}:stop" for st in bot_items for pid in st["pids"][:1]
                  if f"bot:{st['id']}:stop" in acts.specs}
    pid_action |= {a["pids"][0]: a["actions"]["stop"] for a in agent_items if a["pids"] and "stop" in a["actions"]}
    pid_action |= stop_ids
    kinds = {a["pids"][0]: "agent" for a in agent_items if a["pids"]} | dict.fromkeys(helpers, "helper")
    _ctx = {"procs": procs, "assigned": assigned, "pid_action": pid_action, "kinds": kinds}
    return snap, acts.specs


_lock = threading.Lock()
_cached: tuple[float, dict, dict] | None = None
_last_fresh = float("-inf")


def sample() -> tuple[dict, list[dict]]:
    """Для сэмплера истории (раз в минуту, и при закрытой панели): итоги памяти и группы — без top, агентов, кнопок
    и подсказок, чтобы уложиться в 0.3 % ядра; память root-процессов — из последнего кэша top.
    Под замком снимка: кэши launchctl и разбора транскриптов у них общие."""
    with _lock:
        procs = procs_mod.scan()
        launchd = _launchd(procs)
        groups = attrib.groups(procs, paths.PROJECT_ROOTS, _claude(procs), registry.load(paths.BOTS_TOML), launchd)
        return system.memory(), groups


def get(max_age_s: float = 1.5, *, fresh: bool = False) -> tuple[dict, dict[str, ActionSpec]]:
    """Снимок считается только по запросу и живёт max_age_s; параллельные запросы ждут один расчёт.
    fresh — пересобрать сразу, но не чаще раза в FRESH_EVERY_S: иначе обычный снимок с fresh_throttled."""
    global _cached, _last_fresh
    with _lock:
        now = time.monotonic()
        throttled = fresh and now - _last_fresh < FRESH_EVERY_S
        if fresh and not throttled:
            _last_fresh = now
            snap, specs = build(fresh=True)
            _cached = (time.monotonic(), snap, specs)
        elif _cached is None or now - _cached[0] >= max_age_s:
            snap, specs = build()
            _cached = (time.monotonic(), snap, specs)
        _, snap, specs = _cached
    return ({**snap, "fresh_throttled": True} if throttled else snap), specs


def invalidate() -> None:
    """После действия: следующий запрос считает снимок заново и перечитывает launchctl и флаги автозапуска."""
    global _cached
    with _lock:
        _cached = None
    system.forget_launchd()
    agents.forget()


def group(gid: str) -> list[dict] | None:
    """Все процессы группы, по убыванию памяти, неизвестная — в конце; None — такой группы нет.
    Из того же снимка, что видит панель (не старше 1.5 с)."""
    get()
    ctx = _ctx
    pids = [pid for pid, (g, _why, _path) in ctx.get("assigned", {}).items() if g == gid]
    if not pids:
        return None
    procs = ctx["procs"]
    rows = []
    for pid in pids:
        p = procs[pid]
        kind = ctx["kinds"].get(pid) or ("session" if sessions.is_claude(p) else sessions.child_kind(p))
        rows.append({"pid": pid, "name": procs_mod.label(p), "mem_mb": None if p.mem_mb is None else round(p.mem_mb),
                     "kind": kind, "action_id": ctx["pid_action"].get(pid)})
    return sorted(rows, key=lambda r: (r["mem_mb"] is None, -(r["mem_mb"] or 0), r["pid"]))
