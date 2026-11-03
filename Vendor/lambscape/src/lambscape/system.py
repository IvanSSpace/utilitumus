"""Итоги памяти мака (как в Мониторе активности), своп, давление, хост, задания launchd и из top — память
root-процессов и сжатое у всех."""

import ctypes as C
import os
import re
import struct
import subprocess
import threading
import time

from . import paths

_lib = C.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_lib.sysctlbyname.argtypes = [C.c_char_p, C.c_void_p, C.POINTER(C.c_size_t), C.c_void_p, C.c_size_t]
_lib.mach_host_self.restype = C.c_uint32
_lib.host_statistics64.argtypes = [C.c_uint32, C.c_int, C.c_void_p, C.POINTER(C.c_uint32)]

MB = 1024 * 1024


class _VMStats(C.Structure):  # vm_statistics64 (rev1)
    _fields_ = (
        [(n, C.c_uint32) for n in ("free", "active", "inactive", "wire")]
        + [(n, C.c_uint64) for n in ("zero_fill", "reactivations", "pageins", "pageouts", "faults",
                                     "cow_faults", "lookups", "hits", "purges")]
        + [(n, C.c_uint32) for n in ("purgeable", "speculative")]
        + [(n, C.c_uint64) for n in ("decompressions", "compressions", "swapins", "swapouts")]
        + [(n, C.c_uint32) for n in ("compressor", "throttled", "external", "internal")]
        + [("total_uncompressed", C.c_uint64)]
    )


assert C.sizeof(_VMStats) == 152


def _sysctl(name: str) -> bytes:
    size = C.c_size_t(0)
    if _lib.sysctlbyname(name.encode(), None, C.byref(size), None, 0) == 0:
        buf = C.create_string_buffer(size.value)
        if _lib.sysctlbyname(name.encode(), buf, C.byref(size), None, 0) == 0:
            return buf.raw[: size.value]
    raise OSError(C.get_errno(), f"sysctl {name}")


def _sysctl_int(name: str) -> int:
    return int.from_bytes(_sysctl(name), "little")


def _sysctl_str(name: str) -> str:
    return _sysctl(name).rstrip(b"\0").decode()


_HOST = _lib.mach_host_self()
PAGE = C.c_size_t.in_dll(_lib, "vm_kernel_page_size").value
TOTAL_MB = _sysctl_int("hw.memsize") // MB
CHIP = _sysctl_str("machdep.cpu.brand_string")
MACOS = _sysctl_str("kern.osproductversion")
BOOT_TS = struct.unpack_from("<q", _sysctl("kern.boottime"))[0]


def _vm() -> _VMStats:
    vs = _VMStats()
    count = C.c_uint32(C.sizeof(vs) // 4)
    if _lib.host_statistics64(_HOST, 4, C.byref(vs), C.byref(count)) != 0:  # HOST_VM_INFO64
        raise OSError("host_statistics64")
    return vs


def swapouts_mb() -> int:
    """Сколько записано в своп с загрузки, MB: счётчик Swapouts из vm_stat × размер страницы."""
    return round(_vm().swapouts * PAGE / MB)


def memory() -> dict:
    """Итоги как в Мониторе активности: занято = приложения + wired + сжатое."""
    vs = _vm()

    def mb(pages: int) -> int:
        return round(max(pages, 0) * PAGE / MB)

    app, wired, compressed = mb(vs.internal - vs.purgeable), mb(vs.wire), mb(vs.compressor)
    swap_total, _avail, swap_used = struct.unpack_from("<QQQ", _sysctl("vm.swapusage"))
    level = _sysctl_int("kern.memorystatus_vm_pressure_level")
    return {
        "total_mb": TOTAL_MB,
        "used_mb": app + wired + compressed,
        "app_mb": app,
        "wired_mb": wired,
        "compressed_mb": compressed,
        "cached_mb": mb(vs.external + vs.purgeable),
        "free_mb": mb(vs.free - vs.speculative),
        "swap_used_mb": round(swap_used / MB),
        "swap_total_mb": round(swap_total / MB),
        "pressure": {2: "warn", 4: "critical"}.get(level, "normal"),
    }


def host() -> dict:
    return {"chip": CHIP, "ram_mb": TOTAL_MB, "macos": MACOS, "uptime_s": int(time.time() - BOOT_TS)}


def parse_launchctl(text: str) -> dict[str, int | None]:
    jobs = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and (parts[0].isdigit() or parts[0] == "-"):
            jobs[parts[2]] = int(parts[0]) if parts[0].isdigit() else None
    return jobs


def launchctl(argv: list[str], timeout: float = 10.0) -> subprocess.CompletedProcess:
    """Любой вызов launchctl: только по пути paths.LAUNCHCTL (тесты подставляют заглушку), argv без shell,
    минимальное окружение."""
    if not argv or argv[0] != paths.LAUNCHCTL:
        raise ValueError("launchctl вызывается только через paths.LAUNCHCTL")
    home = os.environ.get("HOME") or os.path.expanduser("~")
    return subprocess.run(argv, env={"HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, errors="replace", timeout=timeout)


def _run_launchctl() -> str:
    return launchctl([paths.LAUNCHCTL, "list"]).stdout


_jobs: dict = {"key": None, "ts": 0.0, "jobs": {}}


def forget_launchd() -> None:
    """После действия над ботом список заданий устарел: следующий вызов перечитает launchctl."""
    global _jobs
    _jobs = {"key": None, "ts": 0.0, "jobs": {}}


def launchd_jobs(key: frozenset | None = None, max_age_s: float = 60.0) -> dict[str, int | None]:
    """Метка → PID (None — загружен, но не запущен) по `launchctl list` (~9 мс на запуск).
    key — набор (pid, uniqueid) прямых потомков launchd: задания меняются только вместе с ним, поэтому при
    том же key отдаём прошлый список, но не старше max_age_s. Без key — всегда свежий список."""
    global _jobs
    last = _jobs
    if key is not None and key == last["key"] and time.monotonic() - last["ts"] < max_age_s:
        return last["jobs"]
    try:
        jobs = parse_launchctl(_run_launchctl())
    except (OSError, subprocess.SubprocessError):
        return {}
    _jobs = {"key": key, "ts": time.monotonic(), "jobs": jobs}
    return jobs


_UNITS = {"B": 1 / MB, "K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}
_SIZE = r"([\d.]+)([BKMGT])[+-]?"


def parse_top(text: str) -> tuple[dict[int, float], dict[int, float]]:
    """Вывод `top -stats pid,mem,cmprs` → (PID → MEM, PID → CMPRS) в MB. MEM — footprint, CMPRS — сколько
    памяти процесса сжато или выгружено в своп (в размере до сжатия)."""
    mem, cmprs = {}, {}
    for m in re.finditer(rf"^[ \t]*(\d+)[ \t]+{_SIZE}(?:[ \t]+{_SIZE})?[ \t]*$", text, re.M):
        mem[int(m[1])] = float(m[2]) * _UNITS[m[3]]
        if m[4]:
            cmprs[int(m[1])] = float(m[4]) * _UNITS[m[5]]
    return mem, cmprs


def _run_top(timeout: float = 30) -> tuple[dict[int, float], dict[int, float]]:
    # все процессы: -n N не экономит CPU (top всё равно читает каждый), а root вне списка остались бы без памяти
    out = subprocess.run(["/usr/bin/top", "-l", "1", "-stats", "pid,mem,cmprs"],
                         capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL).stdout
    return parse_top(out)


# root и чужие uid закрыты для libproc, их память видна только в top (как и сжатое у всех): ~0.6 с CPU на вызов,
# а под нагрузкой и свопом — до десятков секунд. Поэтому кэш и только фоновое обновление,
# раз в 5 мин: раз в минуту top один съедал больше 1 % ядра при бюджете открытой панели 2 %
TOP_EVERY_S = 300.0
_top: dict = {"ts": 0.0, "mem": {}, "cmprs": {}}
_top_lock = threading.Lock()


def _refresh_top(timeout: float = 30) -> bool:
    global _top
    try:
        mem, cmprs = _run_top(timeout)
    except (OSError, subprocess.SubprocessError):
        return False
    _top = {"ts": time.monotonic(), "mem": mem, "cmprs": cmprs}
    return True


def _refresh_top_and_release() -> None:
    global _top
    try:
        if not _refresh_top():
            _top = {**_top, "ts": time.monotonic()}  # сбой — не повторяем top на каждом снимке
    finally:
        _top_lock.release()


def root_footprints(max_age_s: float = TOP_EVERY_S) -> dict[int, float]:
    """PID → MB для процессов, которые не отдают phys_footprint. Никогда не ждёт top: отдаёт кэш
    (до первого обновления — пустой), а если он старше max_age_s — обновляет его в фоновом потоке."""
    if time.monotonic() - _top["ts"] > max_age_s and _top_lock.acquire(blocking=False):
        threading.Thread(target=_refresh_top_and_release, name="top", daemon=True).start()
    return _top["mem"]


def root_footprints_now(timeout_s: float = 5.0) -> dict[int, float]:
    """Свежий top для кнопки «Обновить»: синхронно, но не дольше timeout_s. Не успел — остаётся прошлый кэш."""
    t0 = time.monotonic()
    if not _top_lock.acquire(timeout=timeout_s):
        return _top["mem"]
    try:
        # пока ждали замок, фоновый top мог как раз закончить — тогда он и есть свежий
        left = timeout_s - (time.monotonic() - t0)
        if _top["ts"] < t0 and left > 0.2:
            _refresh_top(left)
    finally:
        _top_lock.release()
    return _top["mem"]


def root_cache() -> dict[int, float]:
    """Последний результат top без обновления (для скана процессов)."""
    return _top["mem"]


def cmprs_cache() -> dict[int, float]:
    """PID → сжато или в свопе, MB, из того же top: libproc этого не отдаёт."""
    return _top["cmprs"]
