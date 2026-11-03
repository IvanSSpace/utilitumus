"""SQLite панели: история памяти. WAL + busy_timeout, автокоммит."""

import sqlite3
import time
from pathlib import Path

from . import paths

SCHEMA = """
-- история памяти: key = группа ('project:x', 'app:Chrome', …) или итог ('_used', '_swap', '_compressed')
CREATE TABLE IF NOT EXISTS samples (
  ts     INTEGER NOT NULL,
  key    TEXT    NOT NULL,
  mem_mb INTEGER NOT NULL,
  PRIMARY KEY (ts, key)
) WITHOUT ROWID;
"""


def connect(path: Path | None = None) -> sqlite3.Connection:
    path = path or paths.DB
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=10, isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=10000")
    # WAL записан в самом файле — включаем один раз. Смена режима не ждёт busy_timeout:
    # при одновременном первом открытии новой базы сразу падает «database is locked», поэтому повторяем
    for attempt in range(100):
        try:
            if conn.execute("PRAGMA journal_mode").fetchone()[0] != "wal":
                conn.execute("PRAGMA journal_mode=WAL")
            break
        except sqlite3.OperationalError:
            if attempt == 99:
                raise
            time.sleep(0.05)
    conn.executescript(SCHEMA)
    return conn
