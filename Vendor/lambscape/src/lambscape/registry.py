"""Реестр ботов из bots.toml и их статус: метки launchd, .app по bundle id, порты, память."""

import logging
import os
import plistlib
import time
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from . import procs as procs_mod

log = logging.getLogger(__name__)


@dataclass
class BotSpec:
    id: str
    name: str
    project: str
    url: str | None = None
    launchd: list[str] = field(default_factory=list)
    bundle_ids: list[str] = field(default_factory=list)
    start: list[str] | None = None
    stop: list[str] | None = None
    restart: list[str] | None = None
    requires_env: list[str] = field(default_factory=list)
    env_file: str | None = None
    note: str = ""


def load(path) -> list[BotSpec]:
    """Боты из bots.toml. Битый файл или запись без id/name/project не роняют панель."""
    try:
        data = tomllib.loads(Path(path).read_text("utf-8"))
    except FileNotFoundError:
        return []
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        log.warning("bots.toml не читается: %s", e)
        return []
    known = BotSpec.__dataclass_fields__
    bots = []
    for raw in data.get("bot", []):
        try:
            bots.append(BotSpec(**{k: v for k, v in raw.items() if k in known}))
        except TypeError:
            log.warning("bots.toml: пропускаю запись без id/name/project (%s)", raw.get("id") or raw.get("name"))
    return bots


_bundles: dict[str, dict] = {}
_INFO_KEYS = ("CFBundleIdentifier", "LSUIElement", "LSBackgroundOnly")
# Папки под защитой TCC: панель под launchd не читает в них файлы, иначе macOS спросит доступ окном
_PROTECTED = tuple(os.path.expanduser(p) + "/" for p in ("~/Documents", "~/Desktop", "~/Downloads"))


def protected(path: str) -> bool:
    return path.startswith(_PROTECTED)


def bundle_info(bundle: str) -> dict:
    """Нужные панели ключи Info.plist бандла (кэш по пути бандла): bundle id и признаки фонового приложения."""
    try:
        return _bundles[bundle]
    except KeyError:
        pass
    info = {}
    if not protected(bundle):  # например Electron из node_modules проекта в ~/Documents
        try:
            with open(f"{bundle}/Contents/Info.plist", "rb") as f:
                data = plistlib.load(f)
            info = {k: data[k] for k in _INFO_KEYS if k in data}
        except Exception:  # нет файла, битый или не словарь
            pass
    _bundles[bundle] = info  # кэш сбрасывает «Обновить» из другого потока — отдаём своё значение, не из словаря
    return info


def bundle_id(exe: str) -> str | None:
    """bundle id приложения, которому принадлежит exe, — из его Info.plist."""
    i = exe.rfind(".app/Contents/MacOS/")
    if i < 0:
        return None
    bid = bundle_info(exe[: i + 4]).get("CFBundleIdentifier")
    return bid if isinstance(bid, str) else None


def bot_pids(spec: BotSpec, procs: dict, launchd: dict[str, int | None]) -> list[int]:
    """Главные процессы бота: PID его launchd-меток и запущенные .app с его bundle id."""
    pids = {launchd.get(label) for label in spec.launchd} & procs.keys()
    if spec.bundle_ids:
        pids |= {p.pid for p in procs.values() if ".app/Contents/MacOS/" in p.exe and bundle_id(p.exe) in spec.bundle_ids}
    return sorted(pids)


def env_missing(spec: BotSpec) -> list[str]:
    """Обязательные переменные без значения. Сами значения (токены) никуда не уходят."""
    if not spec.requires_env:
        return []
    values: dict = os.environ
    if spec.env_file:
        values = {}
        try:
            text = "" if protected(spec.env_file) else Path(spec.env_file).read_text("utf-8")
        except (OSError, UnicodeDecodeError):
            text = ""
        for line in text.splitlines():
            k, sep, v = line.strip().removeprefix("export ").partition("=")
            if sep and not k.startswith("#"):
                values[k.strip()] = v.strip().strip("'\"")
    return [k for k in spec.requires_env if not values.get(k)]


def status(spec: BotSpec, procs: dict, launchd: dict[str, int | None]) -> dict:
    mains = bot_pids(spec, procs, launchd)
    kids = procs_mod.children(procs)
    tree = {q for pid in mains for q in procs_mod.tree(procs, pid, kids)}
    # Статус — по launchd-меткам (их и гасит/поднимает команда из конфига); .app вроде менюбара — только в pids/памяти
    if spec.launchd:
        up, total = sum(launchd.get(label) in procs for label in spec.launchd), len(spec.launchd)
    else:
        found = {bundle_id(procs[p].exe) for p in mains}
        up, total = sum(b in found for b in spec.bundle_ids), len(spec.bundle_ids)
    missing = env_missing(spec)
    state = "running" if total and up == total else "partial" if up else "no-config" if missing else "stopped"
    note = spec.note
    if state == "no-config":
        where = os.path.basename(spec.env_file) if spec.env_file else "окружение"
        note = f"Не настроен: впиши {', '.join(missing)} в {where}"
    wanted = {"running": ("stop", "restart"), "partial": ("start", "stop", "restart"),
              "stopped": ("start",), "no-config": ()}[state]
    # аптайм — по launchd-процессам: менюбар-приложение бота живёт неделями и врал бы
    labelled = {launchd.get(label) for label in spec.launchd} & set(mains)
    starts = [procs[p].start_ts for p in (labelled or mains) if procs[p].start_ts]
    return {
        "id": spec.id,
        "name": spec.name,
        "project": os.path.basename(spec.project.rstrip("/")) or spec.id,
        "status": state,
        "pids": mains,
        "mem_mb": round(sum(procs_mod.mem(procs[q]) for q in tree)),
        "uptime_s": int(time.time() - min(starts)) if starts else 0,
        "ports": sorted({port for q in tree for port in procs_mod.listen_ports(q)}),
        "url": spec.url,
        "note": note,
        "actions": [v for v in wanted if getattr(spec, v)],
    }
