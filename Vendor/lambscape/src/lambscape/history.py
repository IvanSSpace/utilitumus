"""История памяти: сэмплер раз в минуту пишет в samples итоги и топ групп, /api/history отдаёт окно
корзинами по 5 мин. Отсюда же своп за 30 мин (подсказка «своп растёт») и запись в своп за сутки (карточка «Диск»).

Ключи samples: _used, _swap, _compressed, _wired (MB), _pressure (1/2/4), _swapouts_mb (счётчик записи в своп
с загрузки), id групп топ-12 по памяти и other — всё остальное, включая группу «Прочее» (её id тоже other).
В корзине — среднее по сэмплам: так стек групп сходится с итогом за тот же отрезок; давление — худшее.
"""

import logging
import sqlite3
import threading
import time

from . import attrib, db, system

log = logging.getLogger(__name__)

INTERVAL_S = 60.0
TOP_GROUPS = 12
SERIES = 5
STEP_S = 300  # шаг на сутки окна: ≤ 288 точек при любом окне
KEEP_DAYS = 7
PRUNE_EVERY_S = 3600.0
PRESSURE = {"normal": 1, "warn": 2, "critical": 4}


def record(conn: sqlite3.Connection, ts: int, memory: dict, groups: list[dict], swapouts_mb: int | None = None) -> None:
    rows = {"_used": memory["used_mb"], "_swap": memory["swap_used_mb"], "_compressed": memory["compressed_mb"],
            "_wired": memory["wired_mb"], "_pressure": PRESSURE.get(memory["pressure"], 1)}
    if swapouts_mb is not None:
        rows["_swapouts_mb"] = swapouts_mb
    top = sorted((g for g in groups if g["id"] != "other"), key=lambda g: -g["mem_mb"])[:TOP_GROUPS]
    rows |= {g["id"]: g["mem_mb"] for g in top}
    rows["other"] = sum(g["mem_mb"] for g in groups) - sum(g["mem_mb"] for g in top)
    conn.executemany("INSERT OR REPLACE INTO samples (ts, key, mem_mb) VALUES (?, ?, ?)",
                     [(ts, k, round(v)) for k, v in rows.items()])


def _name(key: str) -> str:
    kind, _, name = key.partition(":")
    return name or attrib.NAMES.get(kind, kind)


def query(conn: sqlite3.Connection, hours: int = 24, now: float | None = None) -> dict:
    """Окно за hours (1–168) корзинами: ряды — топ-5 групп по среднему за окно и «прочее» (rest: остальные группы
    и other), values в порядке series. Начало окна — по границе корзины: все корзины полные, кроме текущей, и их
    не больше 288. Пустые корзины пропускаем."""
    hours = max(1, min(int(hours), KEEP_DAYS * 24))
    step = STEP_S * -(-hours // 24)
    hi = int(time.time() if now is None else now)
    lo = -(-(hi - hours * 3600) // step) * step
    buckets: dict[int, dict[str, tuple[int, int, int]]] = {}
    for b, key, total, peak, n in conn.execute(
            "SELECT ts / ? * ? AS b, key, SUM(mem_mb), MAX(mem_mb), COUNT(*) FROM samples WHERE ts >= ? AND ts <= ? "
            "GROUP BY b, key", (step, step, lo, hi)):
        buckets.setdefault(b, {})[key] = (total, peak, n)
    sums: dict[str, int] = {}
    for keys in buckets.values():
        for key, (total, _peak, _n) in keys.items():
            if not key.startswith("_") and key != "other":
                sums[key] = sums.get(key, 0) + total
    top = sorted(sums, key=lambda k: (-sums[k], k))[:SERIES]
    points = []
    for b in sorted(buckets):
        keys = buckets[b]
        n = keys["_used"][2] if "_used" in keys else max(c for _t, _p, c in keys.values())

        def mean(key: str) -> int:
            return round(keys[key][0] / n) if key in keys else 0

        rest = sum(t for k, (t, _p, _c) in keys.items() if not k.startswith("_") and k not in top)
        points.append({"ts": b, "used_mb": mean("_used"), "swap_mb": mean("_swap"),
                       "pressure": keys["_pressure"][1] if "_pressure" in keys else 1,
                       "values": [mean(k) for k in top] + [round(rest / n)]})
    return {"step_s": step, "from_ts": lo, "to_ts": hi,
            "series": [{"key": k, "name": _name(k)} for k in top] + [{"key": "rest", "name": "прочее"}],
            "points": points, "first_sample_ts": conn.execute("SELECT MIN(ts) FROM samples").fetchone()[0]}


def prune(conn: sqlite3.Connection, keep_days: int = KEEP_DAYS, now: float | None = None) -> int:
    now = time.time() if now is None else now
    return conn.execute("DELETE FROM samples WHERE ts < ?", (int(now - keep_days * 86400),)).rowcount


def _series(conn: sqlite3.Connection, key: str, since: float) -> list[tuple[int, int]]:
    return conn.execute("SELECT ts, mem_mb FROM samples WHERE ts >= ? AND key = ? ORDER BY ts",
                        (int(since), key)).fetchall()


def swap_growth(conn: sqlite3.Connection, minutes: int = 30, now: float | None = None) -> int | None:
    """На сколько MB вырос своп за последние minutes: последний сэмпл минус первый в окне; None — меньше двух сэмплов."""
    rows = _series(conn, "_swap", (time.time() if now is None else now) - minutes * 60)
    return rows[-1][1] - rows[0][1] if len(rows) >= 2 else None


def swapouts_24h(conn: sqlite3.Connection, now: float | None = None) -> tuple[float, float] | None:
    """(MB записи в своп за сутки, часов истории за этим числом) — по счётчику из сэмплов за последние 24 ч.
    Истории меньше суток — пересчёт на сутки по тому, что есть (оценка, а не замер: часы для подписи в UI),
    но не меньше 2 ч (иначе None). Счётчик с загрузки: после перезагрузки он сбрасывается — такие шаги назад
    не считаем."""
    rows = _series(conn, "_swapouts_mb", (time.time() if now is None else now) - 86400)
    span = rows[-1][0] - rows[0][0] if rows else 0
    if span < 2 * 3600:
        return None
    written = sum(max(0, b - a) for (_t, a), (_t2, b) in zip(rows, rows[1:]))
    return written * 86400 / span, span / 3600


_lock = threading.Lock()
_conn: sqlite3.Connection | None = None


def read(fn, *args):
    """fn(conn, *args) на общем соединении для чтения (маршрут, подсказки, «Диск») — по одному; None, если база
    недоступна."""
    global _conn
    with _lock:
        try:
            if _conn is None:
                _conn = db.connect()
            return fn(_conn, *args)
        except sqlite3.Error as e:
            log.warning("история не читается: %s", e)
            return None


class Sampler(threading.Thread):
    """Раз в interval_s пишет итоги памяти и группы (collect → (memory, groups), по умолчанию snapshot.sample:
    без top, агентов и кнопок), раз в час удаляет старше 7 дней. Своё соединение с базой."""

    def __init__(self, interval_s: float = INTERVAL_S, collect=None):
        super().__init__(name="sampler", daemon=True)
        if collect is None:
            from . import snapshot  # snapshot → advice → history: импорт здесь, а не наверху

            collect = snapshot.sample
        self.interval_s, self.collect = interval_s, collect
        self.ticks = 0
        self._halt = threading.Event()

    def run(self) -> None:
        conn = db.connect()
        pruned = float("-inf")
        try:
            while not self._halt.wait(self.interval_s):
                try:
                    memory, groups = self.collect()
                    now = time.time()
                    record(conn, int(now), memory, groups, system.swapouts_mb())
                    if now - pruned >= PRUNE_EVERY_S:
                        prune(conn, now=now)
                        pruned = now
                except Exception:  # сэмплер не должен умирать из-за одного сбоя
                    log.exception("сэмпл истории не записан")
                self.ticks += 1
        finally:
            conn.close()

    def stop(self, timeout: float = 10.0) -> None:
        self._halt.set()
        self.join(timeout)
