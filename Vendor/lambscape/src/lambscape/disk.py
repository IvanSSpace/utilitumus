"""Карточка «Диск»: износ SSD из smartctl, запись на диск с загрузки из ioreg, запись в своп — с загрузки
(счётчик ядра) и за сутки (сэмплы истории; пока их меньше суток — оценка на сутки, swap_24h_span_h — по скольким
часам), доля свопа во всей записи.

Инструменты запускаются только в фоне и с кэшем: smartctl раз в час (`-a disk0`, таймаут 10 с, только если он
установлен), ioreg раз в 10 мин. Снимок их не ждёт. Нет инструмента или вывод не разобрался — null, а не ошибка.
Объёмы — в десятичных GB/TB, как у производителя диска и в smartctl.
"""

import logging
import os
import plistlib
import re
import shutil
import subprocess
import threading
import time

from . import history, system

log = logging.getLogger(__name__)

# Homebrew: /opt/homebrew на Apple Silicon, /usr/local на Intel; под launchd PATH минимальный
SMARTCTL = shutil.which("smartctl", path="/opt/homebrew/bin:/usr/local/bin") or "/opt/homebrew/bin/smartctl"
IOREG = "/usr/sbin/ioreg"
SMART_EVERY_S = 3600.0
IOREG_EVERY_S = 600.0
SMART_TIMEOUT_S = 10.0
IOREG_TIMEOUT_S = 10.0
GB = 1e9
KEYS = {"model", "size_gb", "wear_pct", "written_tb", "spare_pct", "media_errors", "swap_written_gb_boot",
        "swap_gb_per_day", "writes_gb_per_day", "swap_share_pct", "swap_written_24h_gb", "swap_24h_span_h",
        "uptime_days", "updated_ts"}


def _num(v: str) -> int:
    return int(v.replace(",", ""))


# поле smartctl → (регулярка, преобразование); NVMe: Data Unit — 1000 блоков по 512 байт
_SMART = {
    "model": (r"^(?:Model Number|Device Model):\s*(\S.*?)\s*$", str),
    "wear_pct": (r"^Percentage Used:\s*(\d+)%", int),
    "written_tb": (r"^Data Units Written:\s*([\d,]+)", lambda v: round(_num(v) * 512_000 / 1e12, 1)),
    "spare_pct": (r"^Available Spare:\s*(\d+)%", int),
    "media_errors": (r"^Media and Data Integrity Errors:\s*([\d,]+)", _num),
}


def parse_smart(text: str) -> dict:
    out = {}
    for key, (rx, conv) in _SMART.items():
        if m := re.search(rx, text, re.M):
            out[key] = conv(m[1])
    return out


def parse_ioreg(text: str) -> dict:
    """`ioreg -a -r -c IOBlockStorageDriver -d 2 -l`: у драйвера внутреннего диска (его носитель — disk0) берём
    «Bytes (Write)» с загрузки, у носителя — размер и имя модели."""
    try:
        drivers = plistlib.loads(text.encode())
    except Exception:  # пусто, не plist
        return {}
    for drv in drivers if isinstance(drivers, list) else []:
        kids = drv.get("IORegistryEntryChildren") if isinstance(drv, dict) else None
        for media in kids if isinstance(kids, list) else []:
            if not isinstance(media, dict) or media.get("BSD Name") != "disk0":
                continue
            stats = drv.get("Statistics") if isinstance(drv.get("Statistics"), dict) else {}
            written, size, name = stats.get("Bytes (Write)"), media.get("Size"), media.get("IORegistryEntryName")
            out = {"written_bytes": written if isinstance(written, int) else None,
                   "size_gb": round(size / GB) if isinstance(size, int) and size > 0 else None,
                   "model": name.removesuffix(" Media") if isinstance(name, str) else None}
            return {k: v for k, v in out.items() if v is not None}
    return {}


def _run(argv: list[str], timeout: float) -> str:
    """stdout инструмента; нет файла, сбой запуска или таймаут — пустая строка. Код выхода не важен: smartctl
    выходит с 4, когда не прочитался журнал ошибок, а остальное отдаёт."""
    if not os.path.exists(argv[0]):
        return ""
    try:
        return subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout,
                              stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _card(smart: dict, io: dict, swap24: tuple[float, float] | None) -> dict:
    up_days = max(time.time() - system.BOOT_TS, 1.0) / 86400
    swap24_mb, span_h = swap24 or (None, None)
    swap_gb = system.swapouts_mb() * system.MB / GB
    writes_gb = io["written_bytes"] / GB if io.get("written_bytes") is not None else None
    return {
        "model": smart.get("model") or io.get("model"),
        "size_gb": io.get("size_gb"),
        "wear_pct": smart.get("wear_pct"),
        "written_tb": smart.get("written_tb"),
        "spare_pct": smart.get("spare_pct"),
        "media_errors": smart.get("media_errors"),
        "swap_written_gb_boot": round(swap_gb, 1),
        "swap_gb_per_day": round(swap_gb / up_days, 1),
        "writes_gb_per_day": round(writes_gb / up_days, 1) if writes_gb is not None else None,
        "swap_share_pct": round(100 * swap_gb / writes_gb) if writes_gb else None,
        "swap_written_24h_gb": round(swap24_mb * system.MB / GB, 1) if swap24_mb is not None else None,
        # меньше ~23 ч — число выше пересчитано на сутки, а не замерено за 24 ч
        "swap_24h_span_h": round(span_h, 1) if span_h is not None else None,
        "uptime_days": round(up_days, 1),
        "updated_ts": int(time.time()),
    }


def empty_state() -> dict:
    return {"smart": {}, "smart_ts": float("-inf"), "io": {}, "io_ts": float("-inf"), "swap24": None,
            "card": dict.fromkeys(KEYS)}


_state = empty_state()
_lock = threading.Lock()


def refresh() -> dict:
    """Синхронно перечитать то, что устарело (smartctl — раз в час, ioreg и своп за сутки — раз в 10 мин),
    и собрать карточку."""
    st, now = _state, time.monotonic()
    if now - st["smart_ts"] >= SMART_EVERY_S:
        st["smart"], st["smart_ts"] = parse_smart(_run([SMARTCTL, "-a", "disk0"], SMART_TIMEOUT_S)), now
    if now - st["io_ts"] >= IOREG_EVERY_S:
        out = _run([IOREG, "-a", "-r", "-c", "IOBlockStorageDriver", "-d", "2", "-l"], IOREG_TIMEOUT_S)
        st["io"], st["io_ts"] = parse_ioreg(out), now
        st["swap24"] = history.read(history.swapouts_24h)
    return _card(st["smart"], st["io"], st["swap24"])


def _refresh_and_release() -> None:
    try:
        _state["card"] = refresh()
    except Exception:
        log.exception("карточка «Диск» не обновилась")
    finally:
        _lock.release()


def get() -> dict:
    """Карточка для снимка: никогда не ждёт инструменты. Устарела — обновляется в фоне, а пока отдаём прошлую
    (до первого обновления — все поля null)."""
    st, now = _state, time.monotonic()
    if (now - st["smart_ts"] >= SMART_EVERY_S or now - st["io_ts"] >= IOREG_EVERY_S) and _lock.acquire(blocking=False):
        threading.Thread(target=_refresh_and_release, name="disk", daemon=True).start()
    return st["card"]
