"""Подставная «Студия» для Tests/run-studio-screen-check.sh: тот же вход, что у настоящей (токен в .cache, /api/ping, /api/boot,
/api/session, код в #b=…), страница-заглушка. Слушает только 127.0.0.1:$STUDIO_PORT, пишет файлы только рядом с собой.
Запросы пишутся в $FAKE_STUDIO_LOG: метод, путь без запроса, код ответа. Тела POST-запросов к API — рядом, в <лог>.bodies
(одна строка JSON на запрос): проверка видит, что именно ушло.

Ручки как у настоящей Студии (app/studio.py): GET /api/state, GET /api/unit/<id>, POST /api/unit/<id>/open|task|hub|stand|release|rotate,
POST /api/commit, GET /icons/<id>.png. Данные подставные и меняются от действий, как у настоящей (задача растит очередь).
Нарочные отказы, чтобы проверять ошибки: `fans` на open → 409 «мастер ждёт ответа», задача с текстом «БУМ» → 500."""
import hmac
import http.server
import json
import os
import re
import secrets
import signal
import struct
import sys
import threading
import time
import zlib
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache"
PORT = int(os.environ["STUDIO_PORT"])
LOG = Path(os.environ["FAKE_STUDIO_LOG"])
TOKEN = secrets.token_urlsafe(32)
BOOTS = {}
HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}

PAGE = """<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Студия (подставная)</title>
<style>
body{margin:0;font:14px -apple-system,sans-serif;background:#16181d;color:#e8eaf0}
header{padding:18px 22px;border-bottom:1px solid #2a2e37;display:flex;gap:12px;align-items:center}
h1{font-size:17px;margin:0}.dot{width:9px;height:9px;border-radius:50%;background:#4ade80}
main{padding:22px;display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
.card{background:#1f232b;border:1px solid #2a2e37;border-radius:12px;padding:14px}
.card b{display:block;margin-bottom:6px}.muted{color:#8b93a5}
#state{padding:0 22px 22px}
</style></head><body>
<header><span class="dot"></span><h1>Студия (подставная страница для проверки)</h1><span class="muted" id="who">вход…</span></header>
<main>
<div class="card"><b>Утилита один</b><span class="muted">мастер: готов</span></div>
<div class="card"><b>Утилита два</b><span class="muted">мастер: работает, контекст 41%</span></div>
<div class="card"><b>Утилита три</b><span class="muted">не выпущена</span></div>
</main><div id="state" class="muted"></div>
<script>
// Как app.js настоящей Студии: код из #b=… меняется на токен при загрузке и при каждой смене фрагмента (hashchange).
async function login() {
  const m = location.hash.match(/^#b=([A-Za-z0-9_-]+)$/);
  if (location.hash) history.replaceState(null, "", location.pathname);
  let token = null;
  try { token = localStorage.getItem("studio-token"); } catch (e) {}
  if (m) {
    const r = await fetch("/api/session", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({boot: m[1]})});
    if (r.ok) { token = (await r.json()).token; try { localStorage.setItem("studio-token", token); } catch (e) {} }
  }
  document.getElementById("who").textContent = token ? "вход выполнен" : "нужен вход";
}
window.addEventListener("hashchange", login);
login();
</script></body></html>"""


NOW_MS = int(time.time() * 1000)
STATE_LOCK = threading.Lock()


def unit(uid, title, version, status, master, tasks=0, bugs=0, icon=False, ctx=None, ago_min=None, kind="utility",
         branch=None, ahead=0, tint="#0a84ff", summary=""):
    session = None if ctx is None else {"id": "s-" + uid, "lastActive": NOW_MS - (ago_min or 0) * 60_000,
                                         "contextTokens": ctx * 10_000, "contextPct": ctx}
    return {"id": uid, "kind": kind, "title": title, "summary": summary or f"Подставная утилита {title}", "tint": tint,
            "version": version, "status": status, "openTasks": tasks, "bugs": bugs, "icon": icon,
            "worktree": None if branch is None else {"path": "/tmp/fake/" + uid, "branch": branch, "ahead": ahead},
            "master": {"state": master, "session": session}, "rotation": None}


UNITS = [
    unit("mixer", "Микшер", "1.4.1", "stable", "working", tasks=2, icon=True, ctx=41, ago_min=1, branch="mod/mixer", ahead=3),
    unit("fans", "Вентиляторы", "0.3.0", "ready", "waiting", tasks=0, icon=True, ctx=72, ago_min=12, branch="mod/fans", ahead=1,
         tint="#ff9f0a"),
    unit("clipboard", "Буфер", "1.2.0", "wip", "idle", tasks=1, ctx=18, ago_min=95, branch="mod/clipboard", ahead=0, tint="#bf5af2"),
    unit("keyboard", "Клавиатура", "0.9.2", "bug", "asleep", bugs=2, ctx=63, ago_min=60 * 30, branch="mod/keyboard", tint="#40c8e0"),
    unit("mouse", "Мышь", "0.5.0", "stable", "none", tint="#ff375f"),
    unit("studio", "Студия", None, "wip", "working", tasks=3, ctx=25, ago_min=3, branch="mod/studio", ahead=5, tint="#5e5ce6"),
    unit("launcher", "Лаунчер", "0.9.4", "stable", "idle", kind="launcher", ctx=30, ago_min=40, branch="mod/launcher",
         tint="#636366", summary="Центр Utilitumus: боковая панель, дашборд, Стор"),
    unit("orchestrator", "Оркестратор", None, None, "idle", kind="orchestrator", ctx=55, ago_min=2, branch="main", tint="#48484a",
         summary="hub-utilitumus: права, Стор, иконки, Kit, выпуски"),
]
HUB_TASKS = [
    {"name": "Общий выпуск иконок", "status": "in-progress", "comment": "ждёт проверку Микшера"},
    {"name": "Каталог 0.9.5", "status": "todo", "comment": ""},
    {"name": "Проверка Remote", "status": "in-review", "comment": "готово к показу"},
]
CASES = {u["id"]: f"---\nstatus: {u['status'] or 'stable'}\n---\n# Дело: {u['title']}\n\n## Последнее состояние\n- Работает **штатно**, `fix.sh` зелёный\n- Версия {u['version'] or '—'}\n\n## Известные баги\n"
         + ("".join(f"- баг №{i + 1}\n" for i in range(u["bugs"])) or "- (пока не записаны)\n") for u in UNITS}
QUEUES = {u["id"]: [{"done": i == 0, "text": f"Задача {i + 1} утилиты {u['title']}"} for i in range(u["openTasks"] + 1)] for u in UNITS}
COMMITS = []


def by_id(uid):
    return next((u for u in UNITS if u["id"] == uid), None)


def png(color):
    """Однотонный PNG 256x256: настоящий файл, который разбирает ImageIO (без внешних библиотек)."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    row = b"\x00" + bytes(color) * 256
    raw = row * 256
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


ICONS = {"mixer": png((10, 132, 255)), "fans": png((255, 159, 10))}


def act(u, action, body):
    """Ответ как у настоящей Студии: ({"message": …}) или (код, {"error": …})."""
    text = body.get("text") if isinstance(body.get("text"), str) else ""
    with STATE_LOCK:
        if action == "open":
            if u["id"] == "fans":
                return 409, {"error": "Мастер ждёт ответа в своём терминале: сначала ответь ему"}
            u["master"]["state"] = "idle"
            return 200, {"message": "Переключил на мастера"}
        if action in ("task", "hub"):
            if not text.strip():
                return 409, {"error": "Пустая задача"}
            if "БУМ" in text:
                return 500, {"error": "Внутренняя ошибка Studio: подробности в её терминале"}
            target = by_id("orchestrator") if action == "hub" else u
            target["openTasks"] += 1
            QUEUES[target["id"]].append({"done": False, "text": text})
            if action == "hub":
                HUB_TASKS.append({"name": text[:40], "status": "todo", "comment": ""})
                return 200, {"message": f"Задача №{target['openTasks']} ушла хабу"}
            return 200, {"message": f"Задача №{target['openTasks']} в очереди и у мастера"}
        if action == "stand":
            if u["kind"] == "orchestrator":
                return 409, {"error": "Стенда у оркестратора нет"}
            return 200, {"message": "Стенд собирается в терминале Orca"}
        if action == "release":
            if u["kind"] == "orchestrator":
                return 409, {"error": "Выпуски и так у оркестратора"}
            u["openTasks"] += 1
            return 200, {"message": "Просьба о патче ушла мастеру, он передаст её оркестратору"}
        if action == "rotate":
            if u["kind"] == "orchestrator":
                return 409, {"error": "Оркестратора меняет автор"}
            u["rotation"] = {"stage": "handover", "message": "Мастер записывает дело"}
            return 200, {"message": "Мастер записывает дело, потом поднимется новый"}
    return 404, {"error": "Нет такого действия"}


def log(method, path, code):
    with LOG.open("a") as f:
        f.write(f"{method} {path} {code}\n")


def log_body(path, body):
    with Path(str(LOG) + ".bodies").open("a") as f:
        f.write(json.dumps({"path": path, "body": body}, ensure_ascii=False, sort_keys=True) + "\n")


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        log(self.command, urlsplit(self.path).path, code)

    def authed(self):
        return hmac.compare_digest(self.headers.get("X-Studio-Token", "").encode(), TOKEN.encode())

    def do_GET(self):
        if self.headers.get("Host") not in HOSTS:
            return self.send_json(403, {"error": "host"})
        path = urlsplit(self.path).path
        if path == "/":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return log("GET", "/", 200)
        m = re.fullmatch(r"/icons/([a-z]+)\.png", path)
        if m and m.group(1) in ICONS:
            body = ICONS[m.group(1)]
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return log("GET", path, 200)
        if not path.startswith("/api/"):
            return self.send_json(404, {})
        if not self.authed():
            return self.send_json(401, {"error": "Нужен токен"})
        if path == "/api/ping":
            return self.send_json(200, {"app": "utilitumus-studio"})
        if path == "/api/state":
            with STATE_LOCK:
                return self.send_json(200, {"units": UNITS, "hubTasks": HUB_TASKS, "orcaError": None})
        m = re.fullmatch(r"/api/unit/([a-z]+)", path)
        u = m and by_id(m.group(1))
        if u:
            with STATE_LOCK:
                return self.send_json(200, {"case": re.sub(r"\A---\n.*?\n---\n", "", CASES[u["id"]], flags=re.S),
                                            "queue": QUEUES[u["id"]], "casePath": f"/tmp/fake/utilities/{u['id']}/case.md"})
        self.send_json(404, {"error": "Нет такой утилиты"})

    def do_POST(self):
        if self.headers.get("Host") not in HOSTS:
            return self.send_json(403, {"error": "host"})
        path = urlsplit(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if path == "/api/session":
            exp = BOOTS.pop(body.get("boot"), 0)
            return self.send_json(200, {"token": TOKEN}) if exp > time.time() else self.send_json(403, {})
        if not self.authed():
            return self.send_json(401, {"error": "Нужен токен"})
        if path == "/api/boot":
            code = secrets.token_urlsafe(24)
            BOOTS[code] = time.time() + 120
            return self.send_json(200, {"boot": code})
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            return self.send_json(415, {"error": "Нужен application/json"})
        log_body(path, body)
        if path == "/api/commit":
            COMMITS.append(1)
            return self.send_json(200, {"message": "Записал дела: mixer" if len(COMMITS) == 1 else "Нечего записывать: дела не менялись"})
        m = re.fullmatch(r"/api/unit/([a-z]+)/(open|task|hub|stand|release|rotate)", path)
        u = m and by_id(m.group(1))
        if not u:
            return self.send_json(404, {"error": "Нет такой утилиты или действия"})
        code, reply = act(u, m.group(2), body)
        self.send_json(code, reply)


def stop(*_):
    raise KeyboardInterrupt


def main():
    CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(CACHE, 0o700)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    write_private(CACHE / "token", TOKEN)
    write_private(CACHE / "server.json", json.dumps({"port": PORT, "pid": os.getpid()}))
    signal.signal(signal.SIGTERM, stop)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        for name in ("token", "server.json"):
            (CACHE / name).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
