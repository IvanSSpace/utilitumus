"""Сессии Claude Code, вкладки терминалов, tmux, Docker и сироты."""

import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import time
from datetime import datetime
from pathlib import Path

from . import attrib, registry
from . import procs as procs_mod

SHELLS = {"zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh"}
INTERPRETERS = {"node", "bun", "deno", "uv", "uvx", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node"}
TMUX_SOCK = Path(f"/private/tmp/tmux-{os.getuid()}/default")
DOCKER_SOCK = Path.home() / ".docker/run/docker.sock"
# под launchd PATH минимальный
TMUX_BIN = shutil.which("tmux", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin") or "tmux"

_MCP = re.compile(r"mcp", re.I)
_DEV = re.compile(r"\b(webpack|vite|next|tsx|nodemon|uvicorn)\b|(?<![a-z])serve|start:dev", re.I)


def _claude_exe(p) -> bool:
    return ("/.local/share/claude/versions/" in p.exe or os.path.basename(p.exe).startswith("claude")
            or "/claude-code/" in p.exe or p.name == "claude")


def is_print(p) -> bool:
    """Одноразовый claude -p (боты, скрипты): не сессия."""
    return ("-p" in p.args or "--print" in p.args) and _claude_exe(p)


def is_claude(p) -> bool:
    return _claude_exe(p) and not is_print(p)


def host_app(p, procs) -> str | None:
    """Приложение, которое ведёт сессию: Claude.app (его встроенный claude-code), IDE. Такую сессию
    останавливает и продолжает само приложение, а не панель и не `claude --resume`. Шелл и хост терминала
    хозяином не считаются: сессия во вкладке терминала — своя."""
    parent = procs.get(p.ppid)
    if parent and not attrib.terminal_app(parent) and (app := attrib.app_name(parent.exe)):
        return app
    return attrib.app_name(p.exe)


def child_kind(p) -> str:
    if p.name in SHELLS:
        return "shell"
    text = " ".join(p.args) or p.exe
    if _MCP.search(text):
        return "mcp"
    if _DEV.search(text):
        return "dev-server"
    return "other"


def slug(path: str) -> str:
    """Папка транскриптов в ~/.claude/projects: путь, где всё, кроме букв и цифр, заменено на «-»."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def _ms(v) -> int:
    return int(v / 1000) if isinstance(v, (int, float)) else 0


def _session_json(path: Path, p) -> dict:
    """Данные <pid>.json, если файл про этот самый процесс."""
    try:
        meta = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(meta, dict) or meta.get("pid") != p.pid:
        return {}
    # pid переиспользуется: json прежнего процесса старше нынешнего
    if meta.get("startedAt") and _ms(meta["startedAt"]) < p.start_ts - 5:
        return {}
    return meta


_TAIL = (1 << 16, 1 << 22)  # 64 KB с конца; если там одна огромная строка (вывод инструмента) — до 4 MB


def transcript_ts(path) -> int:
    """Время последней строки транскрипта с меткой времени. mtime файла не годится: служебные строки
    (last-prompt, permission-mode, …) дописываются без метки и без всякой активности."""
    try:
        with open(path, "rb") as f:
            end = f.seek(0, os.SEEK_END)
            for size in _TAIL:
                f.seek(max(0, end - size))
                lines = f.read().split(b"\n")
                for raw in reversed(lines[1:] if end > size else lines):  # первая строка окна обрезана
                    if b'"timestamp"' in raw:
                        try:
                            return int(datetime.fromisoformat(json.loads(raw)["timestamp"]).timestamp())
                        except (ValueError, KeyError, TypeError):  # недописанная строка, метка не наверху
                            pass
                if end <= size:
                    break
    except OSError:
        pass
    return 0


def _transcript(projects_dir, cwd: str, sid: str | None) -> Path | None:
    """Транскрипт сессии в ~/.claude/projects; в папках под TCC (если каталог переопределён туда) — не читаем."""
    if not (sid and cwd and re.fullmatch(r"[\w-]+", sid)):
        return None
    path = Path(projects_dir) / slug(cwd) / f"{sid}.jsonl"
    return None if registry.protected(str(path)) else path


def _last_activity(meta: dict, projects_dir, cwd: str, sid: str | None) -> int:
    """updatedAt/statusUpdatedAt из json или последняя метка транскрипта — что новее:
    пока сессия busy, json не меняется весь ход, а транскрипт пишется."""
    ts = max(_ms(meta.get("updatedAt")), _ms(meta.get("statusUpdatedAt")))
    if path := _transcript(projects_dir, cwd, sid):
        ts = max(ts, transcript_ts(path))
    return ts


# «Что делает сессия»: последний запрос человека и последний шаг ассистента
ACT_TAIL = 3 << 20
PROMPT_MAX, ACTION_MAX, WHAT_MAX = 120, 90, 80
NO_ACTIVITY = {"last_prompt": "", "last_prompt_ts": None, "last_action": "", "last_action_ts": None}
_WHAT = ("description", "file_path", "command", "pattern", "url", "query", "skill")
# до json.loads: только строки user/assistant, без субагентов и ответов инструментов (в них бывает по мегабайту)
_KIND = re.compile(rb'"type":\s*"(?:user|assistant)"')
_SKIP = re.compile(rb'"isSidechain":\s*true|"type":\s*"tool_result"')
_acts: dict[str, dict] = {}


def _clip(text: str, n: int) -> str:
    return text if len(text) <= n else text[: n - 1] + "…"


def _iso(v) -> int | None:
    try:
        return int(datetime.fromisoformat(v).timestamp())
    except (TypeError, ValueError):
        return None


def _prompt(d: dict) -> str:
    """Запрос человека: не ответ инструмента, не служебная строка, не обёртка команды («<command-name>…»)."""
    if d.get("isCompactSummary"):
        return ""
    content = d["message"].get("content")
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return ""
        content = " ".join(str(b.get("text") or "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    text = " ".join(str(content or "").split())
    return "" if text.startswith(("<", "[Request interrupted")) else _clip(text, PROMPT_MAX)


def _step(blocks: list) -> str:
    """Последний шаг ассистента: «Tool: описание|файл|команда» или «ответ: текст»; размышления — не шаг."""
    for b in reversed(blocks):
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_use":
            name = str(b.get("name") or "?")
            name = name.rsplit("__", 1)[-1] if name.startswith("mcp__") else name
            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
            key = next((k for k in _WHAT if isinstance(inp.get(k), str) and inp[k].strip()), None)
            if key is None:
                return _clip(name, ACTION_MAX)
            what = " ".join(inp[key].split())
            # у пути важен конец — имя файла
            what = "…" + what[1 - WHAT_MAX:] if key == "file_path" and len(what) > WHAT_MAX else _clip(what, WHAT_MAX)
            return _clip(f"{name}: {what}", ACTION_MAX)
        if b.get("type") == "text" and (text := " ".join(str(b.get("text") or "").split())):
            return _clip(f"ответ: {text}", ACTION_MAX)
    return ""


def _scan(lines) -> tuple:
    """(запрос, ts) и (шаг, ts) — самые новые среди строк (сначала новые); None — не нашлось."""
    prompt = action = None
    for raw in lines:
        if prompt and action:
            break
        if not _KIND.search(raw) or _SKIP.search(raw):
            continue
        try:
            d = json.loads(raw)
        except ValueError:  # недописанная или битая строка
            continue
        msg = d.get("message") if isinstance(d, dict) else None
        ts = _iso(d.get("timestamp")) if isinstance(msg, dict) else None
        if ts is None or d.get("isSidechain") or d.get("isMeta"):
            continue
        if d.get("type") == "user" and not prompt and (text := _prompt(d)):
            prompt = (text, ts)
        elif d.get("type") == "assistant" and not action and isinstance(msg.get("content"), list):
            if text := _step(msg["content"]):
                action = (text, ts)
    return prompt, action


def activity(path) -> dict:
    """last_prompt/last_action с метками времени из хвоста транскрипта (до 3 MB с конца). Кэш по (путь, размер,
    mtime): неизменный файл не читаем, а дописанный в конец разбираем только с прошлого конца."""
    key = str(path)
    try:
        st = os.stat(key)
    except OSError:
        return dict(NO_ACTIVITY)
    hit = _acts.get(key)
    if hit and hit["stat"] == (st.st_size, st.st_mtime_ns):
        return hit["out"]
    grown = bool(hit) and hit["ino"] == st.st_ino and 0 <= st.st_size - hit["end"] <= ACT_TAIL
    start = hit["end"] if grown else max(0, st.st_size - ACT_TAIL)
    try:
        with open(key, "rb") as f:
            f.seek(start)
            data = f.read(st.st_size - start)
    except OSError:
        return dict(NO_ACTIVITY)
    cut = data.rfind(b"\n") + 1  # недописанную последнюю строку разберём в следующий раз
    lines = data[:cut].split(b"\n")
    if start and not grown:
        lines = lines[1:]  # первая строка окна обрезана
    prompt, action = _scan(reversed(lines))
    out = dict(hit["out"]) if grown else dict(NO_ACTIVITY)
    if prompt:
        out["last_prompt"], out["last_prompt_ts"] = prompt
    if action:
        out["last_action"], out["last_action_ts"] = action
    _acts[key] = {"stat": (st.st_size, st.st_mtime_ns), "ino": st.st_ino, "end": start + cut, "out": out}
    return out


def _child(p, now: float) -> dict:
    return {"pid": p.pid, "uid": p.uid, "name": procs_mod.label(p), "kind": child_kind(p),
            "mem_mb": None if p.mem_mb is None else round(p.mem_mb), "age_s": int(now - p.start_ts) if p.start_ts else 0}


def claude_sessions(procs, sessions_dir, projects_dir, roots, *, self_pid: int | None = None) -> list[dict]:
    """Живые сессии Claude Code. Ищем по процессам; <pid>.json только дополняет — если pid жив, это claude
    и файл не старше процесса. _tree — pid сессии и потомков, сначала самые глубокие."""
    kids = procs_mod.children(procs)
    above_me = set(procs_mod.ancestors(procs, self_pid or os.getpid()))
    now = time.time()
    items, seen = [], set()
    for p in procs.values():
        if p.user != os.getuid() or not is_claude(p):
            continue
        meta = _session_json(Path(sessions_dir) / f"{p.pid}.json", p)
        cwd = str(meta.get("cwd") or p.cwd or "")
        proj = attrib.session_project(cwd, roots)
        sid = meta.get("sessionId") if isinstance(meta.get("sessionId"), str) else None
        tree = procs_mod.tree(procs, p.pid, kids)
        status = meta.get("status")
        app = host_app(p, procs)
        if path := _transcript(projects_dir, cwd, sid):
            seen.add(str(path))
        items.append({
            "pid": p.pid,
            "uid": p.uid,
            "session_id": sid,
            "name": str(meta.get("name") or (proj[0] if proj else os.path.basename(cwd) or "claude")),
            "project": proj[0] if proj else None,
            "cwd": cwd,
            "status": status if status in ("idle", "busy", "shell") else "unknown",
            "started_ts": _ms(meta.get("startedAt")) or int(p.start_ts),
            "last_activity_ts": _last_activity(meta, projects_dir, cwd, sid) or int(p.start_ts),
            **(activity(path) if path else NO_ACTIVITY),
            "mem_mb": round(sum(procs_mod.mem(procs[q]) for q in tree)),
            "version": str(meta.get("version") or (os.path.basename(p.exe) if "/claude/versions/" in p.exe else "")),
            "children": sorted((_child(procs[q], now) for q in tree[:-1]), key=lambda c: -(c["mem_mb"] or 0)),
            "resume_cmd": f"claude --resume {sid}" if sid and not app else "",
            "host_app": app,
            "is_self": p.pid in above_me,
            "_tree": tree,
        })
    for k in _acts.keys() - seen:  # кэш разбора — только для живых сессий
        del _acts[k]
    return sorted(items, key=lambda s: -s["mem_mb"])


def terminals(procs, roots) -> list[dict]:
    """Вкладки терминалов: шелл, чей родитель — хост терминала или login под ним. Проект — по своему cwd."""
    hosts: dict[int, dict] = {}
    for p in procs.values():
        if p.name not in SHELLS or p.user != os.getuid():
            continue
        host = procs.get(p.ppid)
        if host and host.name == "login":
            host = procs.get(host.ppid)
        app = host and attrib.terminal_app(host)
        if not app:
            continue
        fg = procs.get(p.tpgid) if p.tpgid not in (0, p.pgid) else None
        proj = attrib.project_of(p.cwd, roots)
        hosts.setdefault(host.pid, {"app": app, "host_pid": host.pid, "shells": []})["shells"].append({
            "pid": p.pid, "uid": p.uid, "tty": p.tty, "cwd": p.cwd,
            "project": proj[0] if proj else None, "fg": fg.name if fg else "",
        })
    for h in hosts.values():
        h["shells"].sort(key=lambda s: s["pid"])
    return sorted(hosts.values(), key=lambda h: h["host_pid"])


def orphans(procs, launchd_pids: set[int]) -> list[dict]:
    """Свои процессы с ppid=1: не .app, не под launchd и похожи на node/python/bun/uv/deno/MCP."""
    kids = procs_mod.children(procs)
    now = time.time()
    out = []
    for p in procs.values():
        if p.ppid != 1 or p.user != os.getuid() or p.pid in launchd_pids or attrib.app_name(p.exe):
            continue
        name = p.name.lower()
        if not (name in INTERPRETERS or name.startswith("python") or "mcp" in " ".join(p.args).lower()):
            continue
        tree = procs_mod.tree(procs, p.pid, kids)
        out.append({
            "pid": p.pid, "uid": p.uid, "name": procs_mod.label(p),
            "mem_mb": round(sum(procs_mod.mem(procs[q]) for q in tree)),
            "age_s": int(now - p.start_ts) if p.start_ts else 0,
            "reason": "родитель завершился, launchd им не управляет",
            "_tree": tree,
        })
    return sorted(out, key=lambda o: -o["mem_mb"])


AI_PARTS = ("Сессии Claude Code", "MCP-серверы", "Claude.app", "Боты и скрипты (claude -p)", "ollama", "whisper")
_SESS, _MCP_PART, _APP, _PRINT, _OLLAMA, _WHISPER = range(len(AI_PARTS))


def ai_mem(procs, claude: list[dict]) -> dict:
    """Сколько памяти держит ИИ. Каждый процесс попадает в одну часть, вместе со своими потомками:
    claude -p, ollama и whisper — целиком; сессия и Claude.app — кроме MCP (своя часть) и dev-серверов
    (это работа проекта, а не ИИ)."""
    kids = procs_mod.children(procs)
    part: dict[int, int | None] = {}

    def walk(root: int, idx: int) -> None:
        stack = [(root, idx)]
        while stack:
            pid, i = stack.pop()
            if pid in part:  # уже посчитан — вместе со своим поддеревом
                continue
            if pid != root and i in (_SESS, _APP):
                kind = child_kind(procs[pid])
                i = None if kind == "dev-server" else _MCP_PART if kind == "mcp" else i
            part[pid] = i
            stack.extend((k, i) for k in kids.get(pid, ()) if k in procs)

    for p in procs.values():
        names = (os.path.basename(p.exe).lower(), p.name.lower())  # whisper на python виден только по argv[0]
        if is_print(p):
            walk(p.pid, _PRINT)
        elif any(n.startswith("ollama") for n in names):
            walk(p.pid, _OLLAMA)
        elif any(n.startswith("whisper") for n in names):
            walk(p.pid, _WHISPER)
    for s in claude:
        if s["pid"] in procs:
            walk(s["pid"], _SESS)
    for p in procs.values():
        if attrib.app_name(p.exe) == "Claude":
            walk(p.pid, _APP)
    mem, count = [0.0] * len(AI_PARTS), [0] * len(AI_PARTS)
    for pid, i in part.items():
        if i is not None:
            mem[i] += procs_mod.mem(procs[pid])
            count[i] += 1
    return {"total_mb": round(sum(mem)),
            "parts": [{"label": label, "mem_mb": round(mem[i]), "count": count[i]} for i, label in enumerate(AI_PARTS)]}


def tmux() -> dict:
    """Сессии tmux — только если есть его сокет: иначе даже не запускаем бинарник."""
    off = {"running": False, "sessions": []}
    if not TMUX_SOCK.exists():
        return off
    try:
        r = subprocess.run([TMUX_BIN, "-S", str(TMUX_SOCK), "list-sessions", "-F",
                            "#{session_name}\t#{session_windows}\t#{session_attached}"],
                           capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return off
    if r.returncode != 0:
        return off
    sessions = []
    for line in r.stdout.splitlines():
        name, _, rest = line.partition("\t")
        windows, _, attached = rest.partition("\t")
        sessions.append({"name": name, "windows": int(windows) if windows.isdigit() else 0,
                         "attached": attached not in ("", "0")})
    return {"running": True, "sessions": sessions}


class _UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path: str):
        super().__init__("localhost", timeout=2)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


def docker() -> dict:
    """Контейнеры — только если сокет Docker есть и к нему подключаемся. Тот же список, что `docker ps`,
    но напрямую через Engine API: без запуска CLI и без зависимости от PATH под launchd."""
    off = {"running": False, "containers": []}
    if not DOCKER_SOCK.exists():
        return off
    conn = _UnixHTTP(str(DOCKER_SOCK))
    try:
        conn.request("GET", "/containers/json")
        resp = conn.getresponse()
        data = json.loads(resp.read()) if resp.status == 200 else None
    except (OSError, ValueError, http.client.HTTPException):
        return off
    finally:
        conn.close()
    if not isinstance(data, list):
        return off
    return {"running": True, "containers": [
        {"id": str(c.get("Id", ""))[:12], "name": ((c.get("Names") or ["?"])[0]).lstrip("/"),
         "image": c.get("Image", ""), "state": c.get("State", ""), "status": c.get("Status", "")}
        for c in data if isinstance(c, dict)
    ]}
