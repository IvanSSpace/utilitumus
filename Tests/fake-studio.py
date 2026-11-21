"""Подставная «Студия» для Tests/run-studio-screen-check.sh: тот же вход, что у настоящей (токен в .cache, /api/ping, /api/boot,
/api/session, код в #b=…), страница-заглушка. Слушает только 127.0.0.1:$STUDIO_PORT, пишет файлы только рядом с собой.
Запросы пишутся в $FAKE_STUDIO_LOG: метод, путь без запроса, код ответа."""
import hmac
import http.server
import json
import os
import secrets
import signal
import sys
import time
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


def log(method, path, code):
    with LOG.open("a") as f:
        f.write(f"{method} {path} {code}\n")


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
        if path == "/api/ping":
            return self.send_json(200, {"app": "utilitumus-studio"}) if self.authed() else self.send_json(401, {})
        self.send_json(404, {})

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
            return self.send_json(401, {})
        if path == "/api/boot":
            code = secrets.token_urlsafe(24)
            BOOTS[code] = time.time() + 120
            return self.send_json(200, {"boot": code})
        self.send_json(404, {})


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
