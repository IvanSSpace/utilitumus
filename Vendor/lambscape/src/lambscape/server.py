"""HTTP-сервер панели: только 127.0.0.1, проверка Host на каждом запросе, токен + Origin + JSON на POST,
заголовки против встраивания в чужие страницы, статика и JSON API."""

import hmac
import json
import logging
import os
import re
import secrets
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

from . import actions, history, paths, snapshot, system

log = logging.getLogger("lambscape.server")

STATIC_DIR = Path(__file__).parent / "static"
MAX_BODY = 1 << 20
CTYPES = {
    ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8",
    ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
    ".woff2": "font/woff2",
}

# (метод, путь) → обработчик; сегмент «<имя>» — параметр пути: ("GET", "/api/group/<gid>").
# Обработчик получает запрос (h.query, h.json, h.server.token) и параметры пути, возвращает (код, dict | list)
# или (код, bytes, content-type). Ошибка — исключение с полями status и message, например HTTPError.
ROUTES: dict[tuple[str, str], Callable] = {}


class HTTPError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status, self.message = status, message


def route(method: str, path: str):
    def deco(fn):
        ROUTES[(method, path)] = fn
        return fn
    return deco


def _match(method: str, path: str) -> tuple[Callable, dict]:
    if (method, path) in ROUTES:
        return ROUTES[(method, path)], {}
    parts, other_method = path.split("/"), False
    for (m, pattern), fn in ROUTES.items():
        pp = pattern.split("/")
        if len(pp) != len(parts):
            continue
        params = {}
        for want, got in zip(pp, parts):
            if want.startswith("<") and want.endswith(">") and got:
                params[want[1:-1]] = got
            elif want != got:
                break
        else:
            if m == method:
                return fn, params
            other_method = True
    raise HTTPError(405, "метод не поддерживается") if other_method else HTTPError(404, "не найдено")


class Handler(BaseHTTPRequestHandler):
    server_version = "lambscape"
    sys_version = ""

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        try:
            # DNS rebinding: отвечаем только на свой Host
            if self.headers.get("Host") not in self.server.hosts:
                raise HTTPError(403, "чужой Host")
            url = urlsplit(self.path)
            self.query = {k: v[-1] for k, v in parse_qs(url.query).items()}
            self.json = None
            if method == "POST":
                self._guard_post()
                self.json = self._read_json()
            fn, params = _match(method, url.path)
            self._send(*fn(self, **params))
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            status = getattr(e, "status", None)
            if isinstance(status, int) and 400 <= status < 600:
                self._send(status, {"ok": False, "error": str(getattr(e, "message", e))})
            else:
                log.exception("%s %s", method, self.path.split("?")[0])
                self._send(500, {"ok": False, "error": "внутренняя ошибка"})

    def _guard_post(self) -> None:
        # CSRF: Origin из allowlist, токен из index.html (меняется при каждом запуске) и только JSON —
        # кросс-доменный JSON браузер без preflight не отправит
        if self.headers.get("Origin") not in self.server.origins:
            raise HTTPError(403, "чужой Origin")
        if not hmac.compare_digest(self.headers.get("X-Lambscape-Token", "").encode(), self.server.token.encode()):
            raise HTTPError(403, "нет токена")
        if self.headers.get_content_type() != "application/json":
            raise HTTPError(415, "нужен application/json")

    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise HTTPError(400, "плохой Content-Length") from None
        if not 0 <= n <= MAX_BODY:
            raise HTTPError(413, "слишком большое тело")
        try:
            return json.loads(self.rfile.read(n) or b"null")
        except ValueError:
            raise HTTPError(400, "тело — не JSON") from None

    def _send(self, status: int, body, ctype: str | None = None) -> None:
        if not isinstance(body, bytes):
            body, ctype = json.dumps(body, ensure_ascii=False).encode(), "application/json; charset=utf-8"
        self.send_response(status)
        self.send_header("Content-Type", ctype or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        # на всех ответах, включая send_error: с настоящими кнопками «Остановить» clickjacking уже опасен
        for k, v in self.server.security_headers:
            self.send_header(k, v)
        super().end_headers()

    # Тела запросов и токен в лог не пишем; успешный опрос раз в 3 с — тоже
    def log_request(self, code="-", size="-"):
        if isinstance(code, int) and code >= 400:
            log.info("%s %s → %d", self.command, (self.path or "").split("?")[0], code)

    def log_message(self, format, *args):
        log.debug(format, *args)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port: int, token: str):
        super().__init__(("127.0.0.1", port), Handler)
        self.token = token
        port = self.server_address[1]
        self.hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        self.origins = {f"http://{h}" for h in self.hosts}
        # LAMBSCAPE_ALLOW_FRAMING=1 — если панель встраивают в iframe (боковая панель терминала): снимаем только запрет встраивания
        framing = os.environ.get("LAMBSCAPE_ALLOW_FRAMING") == "1"
        self.security_headers = [
            ("Content-Security-Policy", "default-src 'self'" + ("" if framing else "; frame-ancestors 'none'")),
            *([] if framing else [("X-Frame-Options", "DENY")]),
            ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "no-referrer"),
        ]


def make_server(port: int, token: str) -> ThreadingHTTPServer:
    return Server(port, token)


@route("GET", "/")
def index(h):
    try:
        html = (STATIC_DIR / "index.html").read_text("utf-8")
    except FileNotFoundError:
        raise HTTPError(404, "нет static/index.html") from None
    return 200, html.replace("{{TOKEN}}", h.server.token).encode(), CTYPES[".html"]


@route("GET", "/static/<name>")
def static(h, name: str):
    # только файлы прямо в static/: без «..», скрытых файлов и подкаталогов
    path = STATIC_DIR / name
    if not re.fullmatch(r"[\w-][\w.-]*", name, re.ASCII) or not path.is_file():
        raise HTTPError(404, "не найдено")
    return 200, path.read_bytes(), CTYPES.get(path.suffix, "application/octet-stream")


@route("GET", "/api/snapshot")
def api_snapshot(h):
    return 200, snapshot.get(fresh=h.query.get("fresh") == "1")[0]


@route("GET", "/api/group/<gid>")
def api_group(h, gid: str):
    # «показать все»: id группы приходит закодированным («app%3AGoogle%20Chrome»)
    rows = snapshot.group(unquote(gid))
    if rows is None:
        raise HTTPError(404, "Нет такой группы — обнови панель")
    return 200, rows


@route("GET", "/api/history")
def api_history(h):
    try:
        hours = int(h.query.get("hours", "24"))
    except ValueError:
        raise HTTPError(400, "hours — целое число часов") from None
    data = history.read(history.query, hours)
    if data is None:
        raise HTTPError(500, "история недоступна")
    return 200, data


@route("POST", "/api/action")
def api_action(h):
    aid = h.json.get("action_id") if isinstance(h.json, dict) else None
    if not isinstance(aid, str) or not aid:
        return 400, {"ok": False, "error": "Нужен action_id"}
    try:
        # цель — только из снимка не старше 5 с; старше — пересчитываем, и если действия там нет, оно устарело
        return 200, actions.execute(aid, snapshot.get(max_age_s=actions.SPEC_MAX_AGE_S)[1])
    except actions.ActionError as e:
        return e.status, {"ok": False, "error": e.message}
    finally:
        snapshot.invalidate()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    srv = make_server(paths.PORT, secrets.token_urlsafe(24))
    system.root_footprints()  # top для root-процессов — в фоне, к открытию панели память уже будет
    history.Sampler().start()  # история памяти — раз в минуту, и при закрытой панели
    log.info("lambscape: http://127.0.0.1:%d", srv.server_address[1])
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
