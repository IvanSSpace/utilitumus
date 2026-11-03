"""Фоновые агенты launchd: сторонние задания gui/<uid> и системные службы из /Library/LaunchDaemons,
плюс каталог известных производителей — что перестанет работать, если агента выключить.

Здесь только чтение: launchctl list (system.launchd_jobs), print-disabled и plist-файлы. Менять состояние может только
actions.py — argv для bootout/disable/enable/bootstrap строит argv() отсюда, всегда через paths.LAUNCHCTL.
"""

import os
import plistlib
import re
import shlex
import subprocess
import time
from pathlib import Path

from . import attrib, paths, system
from . import procs as procs_mod

GUI_DIRS = [Path.home() / "Library/LaunchAgents", Path("/Library/LaunchAgents")]
SYSTEM_DIRS = [Path("/Library/LaunchDaemons")]
APPLE_DIRS = [Path("/System/Library/LaunchAgents")]  # метки не com.apple., но от Apple: com.openssh.ssh-agent
SELF_LABEL = "local.lambscape"  # сама панель под launchd (bin/lambscape)
DISABLED_EVERY_S = 60.0

# начало метки (в нижнем регистре) → производитель и что перестанет работать
CATALOG = (
    (("com.logi.optionsplus.updater",), "Logitech", "перестанут приходить обновления Logi Options+"),
    (("com.logi.", "com.logitech."), "Logitech",
     "перестанут работать настройки кнопок/жестов Logitech, базовая работа мыши останется"),
    (("com.google.keystone", "com.google.googleupdater"), "Google",
     "программы Google не будут обновляться в фоне — Chrome проверит обновления сам, когда его откроешь"),
    (("us.zoom.",), "Zoom", "Zoom не будет проверять обновления в фоне — звонки работают как раньше"),
    (("com.valvesoftware.",), "Steam",
     "фоновые службы Steam: сам Steam и игры работают, при запуске Steam поднимет их сам"),
    (("com.adobe.",), "Adobe",
     "фоновые службы Creative Cloud: синхронизация и обновления — только пока открыт Creative Cloud"),
    (("com.microsoft.update", "com.microsoft.autoupdate"), "Microsoft",
     "Office не будет обновляться в фоне — обновить можно вручную: «Справка → Проверить наличие обновлений»"),
    (("com.rogueamoeba.",), "Rogue Amoeba",
     "перестанут работать Loopback, Audio Hijack и SoundSource: их виртуальные звуковые устройства пропадут"),
)
UNKNOWN = "что перестанет работать — неизвестно, вернуть можно кнопкой «Вернуть»"
UNKNOWN_ROOT = "что перестанет работать — неизвестно"  # у служб root кнопок нет — и «вернуть кнопкой» тоже
ROOT = "системная служба (нужен sudo)"
TERMINAL = "хост вкладок терминала — закроются все вкладки и сессии Claude в них"


def vendor_of(label: str) -> tuple[str, str]:
    low = label.lower()
    for prefixes, vendor, note in CATALOG:
        if low.startswith(prefixes):
            return vendor, note
    return "", UNKNOWN


def bot_labels(bots) -> set[str]:
    return {label for b in bots for label in b.launchd}


def why_refused(label: str, domain: str, bots_labels) -> str | None:
    """Почему панель не трогает задание, или None: службы macOS, запущенные приложения, боты (у них свои
    кнопки), сама панель и всё в системном домене (там нужен root)."""
    if label.startswith("com.apple."):
        return "служба macOS"
    if label.startswith(("application.", "[", "0x")):
        return "это запущенное приложение, а не агент"
    if label in bots_labels:
        return "агент бота из bots.toml — только кнопками бота"
    if label.startswith(SELF_LABEL):
        return "это сама панель"
    if domain != "gui":
        return ROOT
    return None


def why_tree(procs: dict, tree: list[int], fenced: dict[int, str]) -> str | None:
    """Процессы задания, которые нельзя гасить: хост вкладок терминала, панель и её предки, процессы ботов.
    Причину называем по самому верхнему такому процессу (дерево — от глубоких к корню)."""
    for q in reversed(tree):
        if attrib.terminal_app(procs[q]):
            return TERMINAL
        if q in fenced:
            return fenced[q]
    return None


def verbs(loaded: bool, running: bool, disabled: bool, has_plist: bool) -> list[str]:
    """Что можно сделать с агентом по его состоянию: остановить запущенного (загруженный без процесса ничего не
    держит — его только убрать из автозапуска), убрать из автозапуска невыключенного, вернуть выключенного или
    выгруженного (без plist вернуть можно только флагом — загрузится при входе)."""
    out = ["stop"] if loaded and running else []
    if not disabled and (loaded or has_plist):
        out.append("disable")
    if disabled or (not loaded and has_plist):
        out.append("enable")
    return out


def argv(verb: str, label: str, plist: str | None, loaded: bool) -> list[list[str]]:
    """Команды launchctl для агента в gui/<uid>: stop — bootout (до следующего входа), disable — bootout и disable,
    enable — enable и, если не загружен, bootstrap своего plist."""
    lc, domain = paths.LAUNCHCTL, f"gui/{os.getuid()}"
    target = f"{domain}/{label}"
    if verb == "stop":
        return [[lc, "bootout", target]]
    if verb == "disable":
        return ([[lc, "bootout", target]] if loaded else []) + [[lc, "disable", target]]
    if verb == "enable":
        return [[lc, "enable", target]] + ([[lc, "bootstrap", domain, plist]] if plist and not loaded else [])
    raise ValueError(f"нет такого действия с агентом: {verb}")


def sudo_hint(label: str) -> str:
    target = shlex.quote(f"system/{label}")
    return f"sudo launchctl bootout {target}; sudo launchctl disable {target}"


def parse_disabled(text: str) -> dict[str, bool]:
    """`launchctl print-disabled`: метка → выключена ли. Новые macOS пишут disabled/enabled, старые — true/false."""
    return {m[1]: m[2] in ("disabled", "true") for m in re.finditer(r'"([^"]+)"\s*=>\s*(\w+)', text)}


_disabled: dict = {"ts": float("-inf"), "data": {}}


def disabled(max_age_s: float = DISABLED_EVERY_S) -> dict[str, bool]:
    """Флаги автозапуска gui/<uid> (кэш на минуту: меняются они в основном кнопками самой панели — тогда forget)."""
    global _disabled
    if time.monotonic() - _disabled["ts"] < max_age_s:
        return _disabled["data"]
    try:
        r = system.launchctl([paths.LAUNCHCTL, "print-disabled", f"gui/{os.getuid()}"])
        data = parse_disabled(r.stdout) if r.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError):
        data = {}
    _disabled = {"ts": time.monotonic(), "data": data}
    return data


def forget() -> None:
    """После действия или по «Обновить»: флаги автозапуска перечитаются."""
    global _disabled
    _disabled = {"ts": float("-inf"), "data": {}}


def _read_plist(path) -> dict | None:
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception:  # нет прав, битый файл
        return None
    return data if isinstance(data, dict) else None


def _job(path: str, data: dict) -> dict | None:
    label = data.get("Label")
    if not isinstance(label, str) or not label:
        return None
    args = data.get("ProgramArguments")
    program = data.get("Program") or (args[0] if isinstance(args, list) and args else "")
    return {"label": label, "plist": path, "program": program if isinstance(program, str) else "",
            "keepalive": bool(data.get("KeepAlive")), "run_at_load": data.get("RunAtLoad") is True,
            "disabled": data.get("Disabled") is True}


_plist_cache: dict[str, tuple[tuple[int, int], dict | None]] = {}


def plists(dirs) -> dict[str, dict]:
    """Метка → задание из *.plist в каталогах (кэш по пути, mtime и размеру: файлы меняются редко)."""
    out: dict[str, dict] = {}
    for d in dirs:
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in sorted(entries, key=lambda e: e.name):
            if not e.name.endswith(".plist"):
                continue
            try:
                st = e.stat()
            except OSError:
                continue
            hit = _plist_cache.get(e.path)
            if hit is None or hit[0] != (st.st_mtime_ns, st.st_size):
                data = _read_plist(e.path)
                hit = _plist_cache[e.path] = ((st.st_mtime_ns, st.st_size), data and _job(e.path, data))
            if hit[1]:
                out.setdefault(hit[1]["label"], hit[1])
    return out


def own_plist(path: str, label: str) -> bool:
    """plist для bootstrap: лежит прямо в каталоге LaunchAgents и описывает именно эту метку (читаем заново)."""
    data = _read_plist(path) if Path(path).parent in [Path(d) for d in GUI_DIRS] else None
    return bool(data) and data.get("Label") == label


def _foreign(label: str) -> bool:
    """Стороннее задание, а не служба macOS и не запущенное приложение (application.<bundle>.<номера>)."""
    return not label.startswith(("com.apple.", "application.", "[", "0x"))


_apple_cache: dict[str, bool] = {}


def _apple(label: str) -> bool:
    if label not in _apple_cache:
        _apple_cache[label] = any((Path(d) / f"{label}.plist").is_file() for d in APPLE_DIRS)
    return _apple_cache[label]


def _name(program: str, label: str) -> str:
    """Имя для людей: бандл, в котором лежит исполняемый файл, иначе имя файла, иначе метка."""
    m = re.search(r"([^/]+)\.app/Contents/MacOS/[^/]+$", program)
    return m[1] if m else os.path.basename(program) if program.startswith("/") else label


def collect(procs: dict, launchd: dict, bots, fenced: dict[int, str]) -> list[dict]:
    """Сторонние задания launchd: с plist в LaunchAgents (автозапуск), без plist — только запущенные или выключенные
    кнопкой «убрать» (дремлющие апдейтеры приложений вроде ShipIt память не держат, а без них приложение не
    обновится), и запущенные системные службы (только подсказка sudo). Без com.apple., приложений и ботов.
    Служебные ключи: _verbs — что можно сделать (пусто, если трогать нельзя), _tree — процессы задания, _loaded."""
    if not launchd:  # без launchctl list не знаем, что загружено, — лучше ничего не предлагать
        return []
    skip = bot_labels(bots)
    gui, dis, root_jobs = plists(GUI_DIRS), disabled(), plists(SYSTEM_DIRS)
    extra = [*(label for label, pid in launchd.items() if pid in procs), *(label for label, off in dis.items() if off)]
    labels = {label for label in gui if _foreign(label)}
    labels |= {label for label in extra if label not in gui and _foreign(label) and not _apple(label)}
    kids = procs_mod.children(procs)
    items = []
    for label in labels - skip:
        job, pid = gui.get(label), launchd.get(label)
        tree = procs_mod.tree(procs, pid, kids) if pid in procs else []
        program = job["program"] if job else procs[pid].exe if pid in procs else ""
        off = dis.get(label, job["disabled"] if job else False)
        # метка есть и в /Library/LaunchDaemons — это служба root: bootout в gui её не остановит, actions отобьёт
        root = label in root_jobs
        why = why_refused(label, "system" if root else "gui", skip) or why_tree(procs, tree, fenced)
        vendor, note = vendor_of(label)
        # у защищённого — память только своего процесса: дерево хоста терминала — это вкладки и сессии в них,
        # они уже посчитаны в проектах, а остановить их отсюда всё равно нельзя
        held = tree[-1:] if why else tree
        items.append({
            "label": label, "name": _name(program, label), "vendor": vendor, "plist": job["plist"] if job else None,
            "pids": [pid] if pid in procs else [], "mem_mb": round(sum(procs_mod.mem(procs[q]) for q in held)),
            "keepalive": job["keepalive"] if job else False, "run_at_load": job["run_at_load"] if job else False,
            "disabled": off, "domain": "gui", "note": ROOT if root else f"Не трогаю: {why}" if why else note,
            **({"sudo_hint": sudo_hint(label)} if root else {}),
            "_verbs": [] if why else verbs(label in launchd, bool(tree), off, job is not None), "_tree": tree,
            "_loaded": label in launchd,
        })
    by_exe: dict[str, list[int]] = {}
    for p in procs.values():
        by_exe.setdefault(p.exe, []).append(p.pid)
    for label, job in root_jobs.items():
        pids = sorted(by_exe.get(job["program"], [])) if job["program"].startswith("/") else []
        if not pids or not _foreign(label) or label in skip or label in labels:
            continue
        tree = [q for pid in pids for q in procs_mod.tree(procs, pid, kids)]
        vendor, note = vendor_of(label)
        items.append({
            "label": label, "name": _name(job["program"], label), "vendor": vendor, "plist": job["plist"], "pids": pids,
            "mem_mb": round(sum(procs_mod.mem(procs[q]) for q in tree)), "keepalive": job["keepalive"],
            "run_at_load": job["run_at_load"], "disabled": job["disabled"], "domain": "system",
            "note": UNKNOWN_ROOT if note == UNKNOWN else note,
            "sudo_hint": sudo_hint(label), "_verbs": [], "_tree": tree, "_loaded": bool(pids),
        })
    return sorted(items, key=lambda a: (not a["pids"], -a["mem_mb"], a["label"].lower()))
