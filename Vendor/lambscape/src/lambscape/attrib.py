"""Атрибуция процессов: каждый процесс попадает в группу проекта, приложения, системы или «прочего»."""

import os
import re
from pathlib import Path

from . import procs as procs_mod
from . import registry

NAMES = {"system": "Система", "other": "Прочее"}
_APP = re.compile(r"/([^/]+)\.app/")
# служебные .app, которые на деле часть другого приложения
_APP_OF = {"Orca Terminal Host": "Orca"}


def _prefixes(roots) -> list[str]:
    return [str(r).rstrip("/") + "/" for r in roots]


def _find_project(text: str, prefixes: list[str], anywhere: bool) -> tuple[str, str] | None:
    for r in prefixes:
        i = text.find(r) if anywhere else (0 if text.startswith(r) else -1)
        if i >= 0:
            name = re.split(r"[/\0]", text[i + len(r):], maxsplit=1)[0]
            if name:
                return name, r + name
    return None


def project_of(path: str | None, roots, anywhere: bool = False) -> tuple[str, str] | None:
    """Папка первого уровня под корнем проектов: ('lambscape', '/…/projects/lambscape').
    anywhere — корень может стоять внутри строки (аргумент вида --config=/…/projects/x)."""
    return _find_project(path, _prefixes(roots), anywhere) if path else None


def session_project(cwd: str | None, roots) -> tuple[str, str] | None:
    """Проект сессии Claude: папка под корнем, иначе сама папка cwd (домашняя — «~»)."""
    hit = project_of(cwd, roots)
    if hit or not cwd or cwd == "/":
        return hit
    return ("~" if cwd == str(Path.home()) else os.path.basename(cwd.rstrip("/"))), cwd


def app_name(exe: str) -> str | None:
    """Внешний .app, которому принадлежит exe (хелперы и рендереры — тоже). Python.app внутри фреймворка — не приложение."""
    m = _APP.search(exe or "")
    if not m or ".framework/" in exe[: m.start()]:
        return None
    return _APP_OF.get(m.group(1), m.group(1))


def system_path(exe: str) -> bool:
    # служебные .app в /System/Library (Dock, Finder…) — тоже система, иначе обзор забит мелочью
    return exe.startswith(("/System/Library/", "/System/Cryptexes/", "/System/Volumes/Preboot/Cryptexes/OS/",
                           "/usr/", "/bin/", "/sbin/", "/Library/Apple/")) and not exe.startswith("/usr/local/")


def _flag(v) -> bool:
    return str(v).lower() in ("1", "true", "yes")


def background_app(exe: str) -> str | None:
    """Имя фонового приложения (в Info.plist внешнего .app — LSUIElement или LSBackgroundOnly: без окна в Dock),
    иначе None. Смотрим внешний бандл: у хелперов браузера свой LSUIElement, но они — часть обычного приложения.
    Приложения Apple и системные пути — не наши."""
    i = (exe or "").find(".app/")
    if i < 0 or system_path(exe) or ".framework/" in exe[:i]:
        return None
    info = registry.bundle_info(exe[: i + 4])
    if str(info.get("CFBundleIdentifier", "")).startswith("com.apple."):
        return None
    return app_name(exe) if _flag(info.get("LSUIElement")) or _flag(info.get("LSBackgroundOnly")) else None


def in_ram(p) -> float:
    """Сколько памяти процесса сейчас в RAM, MB: resident, а у root (resident не виден) — footprint без сжатого."""
    return p.res_mb if p.res_mb is not None else max(0.0, procs_mod.mem(p) - procs_mod.swapped(p))


def fit(values: list[float], total: int) -> list[int]:
    """Целые доли total пропорционально values, в сумме ровно total и не меньше нуля: округление вниз, а недостающие
    единицы — строкам с самой большой дробной частью. Делить не по чему — всё в последнюю строку («прочее»)."""
    s = sum(values)
    if s <= 0:
        return [0] * (len(values) - 1) + [total]
    exact = [v * total / s for v in values]
    out = [int(x) for x in exact]
    for i in sorted(range(len(out)), key=lambda i: out[i] - exact[i])[: total - sum(out)]:
        out[i] += 1
    return out


def terminal_app(p) -> str | None:
    """Хост вкладок терминала: шеллы под ним — вкладки, а атрибуцию от него не наследуем."""
    if p.name == "orca-terminal-host":
        return "Orca"
    if p.name.startswith("iTermServer") or p.name == "iTerm2":
        return "iTerm2"
    if p.exe.endswith("/Terminal.app/Contents/MacOS/Terminal"):
        return "Terminal"
    return None


def _own(p, prefixes: list[str]) -> tuple[str, str, str | None] | None:
    for value, why, anywhere in ((p.cwd, "cwd в проекте", False), (p.exe, "exe в проекте", False),
                                 ("\0".join(p.args), "args в проекте", True)):
        hit = value and _find_project(value, prefixes, anywhere)
        if hit:
            return f"project:{hit[0]}", why, hit[1]
    app = app_name(p.exe)
    if app and not system_path(p.exe):
        return f"app:{app}", "приложение", None
    return None


def assign(procs, roots, claude_sessions, bot_specs, launchd) -> dict[int, tuple[str, str, str | None]]:
    """PID → (id группы, почему, путь проекта)."""
    kids = procs_mod.children(procs)
    out: dict[int, tuple[str, str, str | None]] = {}
    # 1. claude и все его потомки — проект по cwd сессии
    for s in claude_sessions:
        proj = session_project(s.get("cwd"), roots)
        if proj and s["pid"] in procs:
            for pid in procs_mod.tree(procs, s["pid"], kids):
                why = "сессия claude" if pid == s["pid"] else f"потомок claude {s['pid']}"
                out.setdefault(pid, (f"project:{proj[0]}", why, proj[1]))
    # боты из bots.toml — по своим launchd-меткам и bundle id
    for spec in bot_specs:
        name = os.path.basename(spec.project.rstrip("/")) or spec.id
        for main in registry.bot_pids(spec, procs, launchd):
            for pid in procs_mod.tree(procs, main, kids):
                out.setdefault(pid, (f"project:{name}", f"бот {spec.id}", spec.project))
    # 2–3. свои признаки: cwd / exe / args в проекте, exe в .app
    prefixes = _prefixes(roots)
    own = {pid: hit for pid, p in procs.items() if pid not in out and (hit := _own(p, prefixes))}
    for pid, p in procs.items():
        if pid in out:
            continue
        if pid in own:
            out[pid] = own[pid]
            continue
        # без своих признаков — от ближайшего предка, но не через launchd и не через хост терминала
        q, steps = procs.get(p.ppid), 0
        while q and q.pid > 1 and not terminal_app(q) and steps < 64:
            if q.pid in own:
                out[pid] = (own[q.pid][0], f"наследует от {q.pid}", own[q.pid][2])
                break
            q, steps = procs.get(q.ppid), steps + 1
        else:
            out[pid] = ("system", "системный путь", None) if pid == 0 or system_path(p.exe) else ("other", "без признаков", None)
    return out


def _kind_name(gid: str) -> tuple[str, str]:
    kind, _, name = gid.partition(":")
    return kind, name or NAMES[kind]


def groups(procs, roots, claude_sessions, bot_specs, launchd, assigned=None) -> list[dict]:
    """Группы снимка, по убыванию памяти; в top — пять самых тяжёлых процессов группы, в rest — сколько
    процессов и MB за его пределами: top + rest = mem_mb ровно (округление строк подогнано под итог).
    Процессы с неизвестной памятью (root вне top) считаются в count и rest, но в top не попадают."""
    if assigned is None:
        assigned = assign(procs, roots, claude_sessions, bot_specs, launchd)
    acc: dict[str, dict] = {}
    for pid, (gid, why, path) in assigned.items():
        p = procs[pid]
        g = acc.get(gid)
        if g is None:
            kind, name = _kind_name(gid)
            g = acc[gid] = {"id": gid, "kind": kind, "name": name, "path": path,
                            "mem_mb": 0.0, "count": 0, "_members": []}
        g["mem_mb"] += procs_mod.mem(p)
        g["count"] += 1
        if p.mem_mb is not None:
            g["_members"].append((p.mem_mb, pid, why))
    out = []
    for g in acc.values():
        top = sorted(g.pop("_members"), reverse=True)[:5]
        total = round(g["mem_mb"])
        *tops, rest = fit([mem for mem, _pid, _why in top] + [max(0.0, g["mem_mb"] - sum(m for m, _p, _w in top))], total)
        g["top"] = [{"pid": pid, "name": procs_mod.label(procs[pid]), "mem_mb": mb, "why": why}
                    for mb, (_mem, pid, why) in zip(tops, top)]
        g["rest"] = {"count": g["count"] - len(top), "mb": rest}
        g["mem_mb"] = total
        out.append(g)
    return sorted(out, key=lambda g: -g["mem_mb"])


def ram_split(procs, assigned) -> list[dict]:
    """Группы по памяти в RAM (resident) и «сжато или в свопе» (procs.swapped), по убыванию RAM.
    У root resident не виден: в RAM идёт footprint из top без сжатого."""
    acc: dict[str, list[float]] = {}
    for pid, (gid, _why, _path) in assigned.items():
        p = procs[pid]
        g = acc.setdefault(gid, [0.0, 0.0])
        g[0] += in_ram(p)
        g[1] += procs_mod.swapped(p)
    out = [{"id": gid, "name": _kind_name(gid)[1], "kind": _kind_name(gid)[0], "ram_mb": round(ram), "swapped_mb": round(sw)}
           for gid, (ram, sw) in acc.items()]
    return sorted(out, key=lambda g: -g["ram_mb"])
