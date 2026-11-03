"""Подсказки: что держит память и что с этим сделать — по готовому снимку, кнопки — из его же действий.

Правила: долгоживущий dev-сервер или тяжёлый потомок сессии/вкладки, простаивающая сессия, сироты, одни и те же
MCP в нескольких сессиях, модели ollama, рост свопа или давление памяти. Считаются не чаще раза в 15 с и не ждут
сеть: ollama опрашивается в фоне раз в минуту и только когда его процесс запущен.
"""

import http.client
import json
import re
import threading
import time

from . import history, sessions
from .actions import fmt_mb, plural

EVERY_S = 15.0
LONG_S = 2 * 3600
HEAVY_MB = 500
IDLE_S = 6 * 3600
SWAP_GROWTH_MB = 500
OLLAMA = ("127.0.0.1", 11434)
OLLAMA_EVERY_S = 60.0
RANK = {"high": 0, "med": 1, "low": 2}


def severity(mb: float) -> str:
    return "high" if mb >= 2048 else "med" if mb >= 500 else "low"


def _item(rule: str, sev: str, title: str, detail: str, saves_mb: float, action_id: str | None) -> dict:
    return {"id": f"adv:{rule}", "severity": sev, "title": title, "detail": detail, "saves_mb": round(saves_mb),
            "action_id": action_id}


def _long_running(snap: dict, specs: dict) -> list[dict]:
    """dev-сервер дольше 2 ч или любой потомок больше 500 MB и дольше 2 ч — у сессии и во вкладке терминала.
    Вложенные (npm start:dev → webpack) не дублируем: кнопка обёртки гасит и то, что под ней."""
    found = []
    for s in snap["sessions"]["claude"]:
        found += [(c, f"его запустила сессия «{s['name']}»") for c in s["children"]]
    for term in snap["sessions"]["terminals"]:
        for sh in term["shells"]:
            where = f" ({sh['project']})" if sh.get("project") else ""
            found += [(c, f"запущен во вкладке {sh['tty'] or sh['pid']}{where}") for c in sh.get("children", [])]
    hits = [(c, why) for c, why in found if c.get("action_id") in specs and c["age_s"] >= LONG_S
            and (c["kind"] == "dev-server" or (c["mem_mb"] or 0) >= HEAVY_MB)]
    inner = {pid for c, _ in hits for pid, _uid in specs[c["action_id"]].tree if pid != c["pid"]}
    out = []
    for c, why in hits:
        if c["pid"] in inner:
            continue
        mb = sum(t["mb"] for t in specs[c["action_id"]].targets) or c["mem_mb"] or 0
        out.append(_item(f"dev-server:{c['pid']}", severity(mb),
                         f"{c['name'][:40]} висит {c['age_s'] // 3600} ч и держит {fmt_mb(mb)} — остановить?",
                         why, mb, c["action_id"]))
    return out


def _idle(snap: dict, now: float) -> list[dict]:
    out = []
    for s in snap["sessions"]["claude"]:
        idle = now - (s["last_activity_ts"] or now)
        if s["status"] == "idle" and idle > IDLE_S and s["action_id"]:
            detail = (f"продолжить потом: {s['resume_cmd']}" if s["resume_cmd"]
                      else "sessionId неизвестен — продолжить через --resume не выйдет")
            out.append(_item(f"idle:{s['pid']}", severity(s["mem_mb"]),
                             f"Сессия {s['name']} простаивает {int(idle // 3600)} ч", detail, s["mem_mb"],
                             s["action_id"]))
    return out


def _orphans(snap: dict) -> list[dict]:
    """Все сироты одной строкой; кнопка — самой большой из тех, что можно остановить."""
    orphans = snap["sessions"]["orphans"]
    stoppable = [o for o in orphans if o["action_id"]]
    if not stoppable:
        return []
    big = max(stoppable, key=lambda o: o["mem_mb"] or 0)
    n, total = len(orphans), sum(o["mem_mb"] or 0 for o in orphans)
    title = f"{n} {plural(n, 'осиротевший процесс держит', 'осиротевших процесса держат', 'осиротевших процессов держат')}"
    return [_item("orphans", severity(big["mem_mb"] or 0), f"{title} {fmt_mb(total)}",
                  f"Родитель завершился, launchd ими не управляет. Кнопка — для самого большого: {big['name']} "
                  f"({fmt_mb(big['mem_mb'] or 0)})", big["mem_mb"] or 0, big["action_id"])]


def _mcp_name(label: str) -> str:
    """«github-mcp-server» из «node …/github-mcp-server/dist/index.js»: первое слово с признаком MCP."""
    return next((w for w in re.split(r"[/\s]+", label) if sessions._MCP.search(w)), label)


def _mcp(snap: dict) -> list[dict]:
    """Один и тот же MCP-сервер в двух сессиях и больше: каждая сессия поднимает свою копию. Совет без кнопки."""
    per: dict[str, dict[int, float]] = {}  # сервер → сессия → MB
    for s in snap["sessions"]["claude"]:
        for c in s["children"]:
            if c["kind"] == "mcp":
                by = per.setdefault(_mcp_name(c["name"]), {})
                by[s["pid"]] = by.get(s["pid"], 0) + (c["mem_mb"] or 0)
    dups = {name: by for name, by in per.items() if len(by) >= 2}
    if not dups:
        return []
    names = sorted(dups, key=lambda n: -sum(dups[n].values()))
    total = sum(sum(by.values()) for by in dups.values())
    extra = sum(sum(by.values()) - max(by.values()) for by in dups.values())  # всё, кроме одной копии
    more = f" и ещё {len(names) - 3}" if len(names) > 3 else ""
    return [_item("mcp", "low", f"MCP {', '.join(names[:3])}{more} запущены в {max(map(len, dups.values()))} "
                                f"сессиях — {fmt_mb(total)}",
                  "Подключай их только в нужных проектах (.mcp.json проекта), а не глобально — тогда остальные "
                  "сессии не будут поднимать свои копии", extra, None)]


_ollama: dict = {"ts": float("-inf"), "models": []}
_ollama_lock = threading.Lock()


def probe_ollama() -> list[dict]:
    """Загруженные модели: GET /api/ps, таймаут 1 с. Порт не слушается или ответ не тот — пусто."""
    conn = http.client.HTTPConnection(*OLLAMA, timeout=1)
    try:
        conn.request("GET", "/api/ps")
        r = conn.getresponse()
        data = json.loads(r.read()) if r.status == 200 else {}
    except (OSError, ValueError, http.client.HTTPException):
        return []
    finally:
        conn.close()
    models = data.get("models") if isinstance(data, dict) else None
    return [{"name": str(m.get("name") or m.get("model") or "?"), "mb": round((m.get("size") or 0) / 2**20)}
            for m in models if isinstance(m, dict)] if isinstance(models, list) else []


def _refresh_ollama_and_release() -> None:
    global _ollama
    try:
        _ollama = {"ts": time.monotonic(), "models": probe_ollama()}
    finally:
        _ollama_lock.release()


def ollama_models() -> list[dict]:
    """Кэш на минуту; устарел — обновляется в фоне, а пока отдаём прошлый."""
    if time.monotonic() - _ollama["ts"] >= OLLAMA_EVERY_S and _ollama_lock.acquire(blocking=False):
        threading.Thread(target=_refresh_ollama_and_release, name="ollama", daemon=True).start()
    return _ollama["models"]


def _ollama_hint(snap: dict) -> list[dict]:
    running = any(p["label"] == "ollama" and p["count"] for p in snap["ai_mem"]["parts"])
    models = ollama_models() if running else []
    if not models:
        return []
    mb = sum(m["mb"] for m in models)
    names = ", ".join(m["name"] for m in models)
    return [_item("ollama", severity(mb), f"ollama держит в памяти {names} — {fmt_mb(mb)}",
                  f"Выгрузить: ollama stop {models[0]['name']} — или закрой ollama, если она сейчас не нужна", mb, None)]


def _swap(snap: dict) -> list[dict]:
    """Своп вырос на 500 MB за 30 мин или давление warn/critical — что выключить первым: три главных кандидата
    из «Что можно освободить», кроме самой macOS."""
    mem = snap["memory"]
    growth = history.read(history.swap_growth) or 0
    if growth < SWAP_GROWTH_MB and mem["pressure"] not in ("warn", "critical"):
        return []
    top = [c for c in mem.get("free_candidates", []) if c["key"] != "macos"][:3]
    title = (f"Своп растёт: +{fmt_mb(growth)} за 30 мин" if growth >= SWAP_GROWTH_MB else
             f"Давление памяти {'критическое' if mem['pressure'] == 'critical' else 'повышенное'}")
    detail = ("Что выключить первым: " + ", ".join(f"{c['name']} ({fmt_mb(c['ram_mb'] + c['compressed_mb'])})"
                                                    for c in top)) if top else "Закрой то, что сейчас не нужно"
    return [_item("swap", "high" if mem["pressure"] == "critical" else "med", title, detail,
                  sum(c["ram_mb"] + c["compressed_mb"] for c in top), None)]


def build(snap: dict, specs: dict, now: float) -> list[dict]:
    """Подсказки по снимку, по severity и затем по saves_mb. Кнопка — только из specs этого снимка."""
    items = [*_long_running(snap, specs), *_idle(snap, now), *_orphans(snap), *_mcp(snap), *_ollama_hint(snap),
             *_swap(snap)]
    items = [a for a in items if a["action_id"] is None or a["action_id"] in specs]
    return sorted(items, key=lambda a: (RANK[a["severity"]], -a["saves_mb"]))


_cache: dict = {"ts": float("-inf"), "items": []}


def get(snap: dict, specs: dict, now: float | None = None) -> list[dict]:
    """Для снимка: пересчёт не чаще раза в EVERY_S; подсказки с кнопками, которых в этом снимке уже нет, отбрасываем."""
    global _cache
    t = time.monotonic()
    if t - _cache["ts"] >= EVERY_S:
        _cache = {"ts": t, "items": build(snap, specs, time.time() if now is None else now)}
    return [a for a in _cache["items"] if a["action_id"] is None or a["action_id"] in specs]
