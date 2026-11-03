"""Скан процессов через libproc (ctypes), без ps и psutil.

Свои процессы видны целиком: память (phys_footprint, как «Память» в Мониторе активности), exe, cwd, args, tty.
У root и чужих uid ядро отдаёт только ppid, имя, exe и uniqueid — их память берём из кэша top,
а кого top не покрыл, у того память неизвестна (None), а не 0. Сжатое (CMPRS) libproc не отдаёт ни у кого — тоже из top.
"""

import ctypes as C
import mmap
import os
import re
import socket
import struct
import threading
from dataclasses import dataclass

from . import system

_lib = C.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_lib.proc_listallpids.argtypes = [C.c_void_p, C.c_int]
_lib.proc_pidinfo.argtypes = [C.c_int, C.c_int, C.c_uint64, C.c_void_p, C.c_int]
_lib.proc_pidfdinfo.argtypes = [C.c_int, C.c_int, C.c_int, C.c_void_p, C.c_int]
_lib.proc_pid_rusage.argtypes = [C.c_int, C.c_int, C.c_void_p]
_lib.proc_pidpath.argtypes = [C.c_int, C.c_void_p, C.c_uint32]
_lib.sysctl.argtypes = [C.POINTER(C.c_int), C.c_uint, C.c_void_p, C.POINTER(C.c_size_t), C.c_void_p, C.c_size_t]
_lib.devname.argtypes = [C.c_int32, C.c_uint16]
_lib.devname.restype = C.c_char_p

MB = 1024 * 1024
_u8, _u32, _u64, _i32 = C.c_uint8, C.c_uint32, C.c_uint64, C.c_int32

# flavor'ы proc_pidinfo
_LISTFDS, _VNODEPATHINFO, _SHORTBSD, _UNIQID, _BSDINFO_UNIQ = 1, 9, 13, 17, 18


class _RUsage(C.Structure):  # rusage_info_v4
    _fields_ = [("uuid", _u8 * 16)] + [(n, _u64) for n in (
        "user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint "
        "proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups "
        "child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten "
        "cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility "
        "cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time "
        "serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy "
        "serviced_energy interval_max_phys_footprint runnable_time").split()]


_UNIQ_FIELDS = [("exe_uuid", _u8 * 16), ("uniqueid", _u64), ("puniqueid", _u64),
                ("idversion", _i32), ("orig_ppidversion", _i32), ("reserved", _u64 * 2)]


class _BSDInfoUniq(C.Structure):  # proc_bsdinfowithuniqid: proc_bsdinfo + proc_uniqidentifierinfo, только свои процессы
    _fields_ = (
        [(n, _u32) for n in "flags status xstatus pid ppid uid gid ruid rgid svuid svgid rfu".split()]
        + [("comm", C.c_char * 16), ("name", C.c_char * 32)]
        + [(n, _u32) for n in "nfiles pgid pjobc tdev tpgid".split()]
        + [("nice", _i32), ("start_sec", _u64), ("start_usec", _u64)]
        + _UNIQ_FIELDS
    )


class _ShortBSD(C.Structure):  # proc_bsdshortinfo: отдаётся для любых процессов
    _fields_ = ([(n, _u32) for n in "pid ppid pgid status".split()] + [("comm", C.c_char * 16)]
                + [(n, _u32) for n in "flags uid gid ruid rgid svuid svgid rfu".split()])


class _Uniq(C.Structure):  # proc_uniqidentifierinfo
    _fields_ = _UNIQ_FIELDS


class _VnodePath(C.Structure):  # proc_vnodepathinfo: из него нужен только путь cwd
    _fields_ = [("cdir_info", _u8 * 152), ("cdir", C.c_char * 1024), ("rdir", _u8 * 1176)]


for _cls, _size in ((_RUsage, 296), (_BSDInfoUniq, 192), (_ShortBSD, 64), (_Uniq, 56), (_VnodePath, 2352)):
    assert C.sizeof(_cls) == _size, (_cls.__name__, C.sizeof(_cls))


@dataclass(frozen=True, slots=True)
class Proc:
    pid: int
    ppid: int
    uid: str  # p_uniqueid (hex): в отличие от pid, не переиспользуется
    start_ts: float
    name: str
    exe: str
    cwd: str | None
    args: tuple[str, ...]
    tty: str | None
    user: int
    mem_mb: float | None  # None — неизвестно: root вне top
    peak_mb: float | None
    readable: bool
    pgid: int = 0
    tpgid: int = 0
    res_mb: float | None = None  # сейчас в RAM (ri_resident_size); у root не виден
    wired_mb: float | None = None  # ri_wired_size
    cmprs_mb: float | None = None  # сжато или в свопе: CMPRS из кэша top; None — top процесс не видел


def mem(p: Proc) -> float:
    """Память для сумм: неизвестная считается нулём."""
    return p.mem_mb or 0.0


def swapped(p: Proc) -> float:
    """Сколько памяти процесса сжато или в свопе, MB (до сжатия). Точно — CMPRS из top; кого top не видел
    (мелкие и запущенные после него), тем оценка footprint − resident: у GPU-хелперов она завышена видеопамятью."""
    if p.cmprs_mb is not None:
        return p.cmprs_mb
    return max(0.0, mem(p) - p.res_mb) if p.res_mb is not None else 0.0


# Буферы общие, поэтому скан идёт под замком
_lock = threading.Lock()
_bi, _sb, _uq, _ru, _vp = _BSDInfoUniq(), _ShortBSD(), _Uniq(), _RUsage(), _VnodePath()
_path = C.create_string_buffer(4096)
_ARGMAX = 1 << 20
# Анонимный mmap вместо create_string_buffer: в footprint попадают только страницы, куда ядро писало
_argmap = mmap.mmap(-1, _ARGMAX)
_argbuf = C.c_char.from_buffer(_argmap)
# exe и args по (pid, uniqueid, idversion): idversion меняется при exec, uniqueid — нет
_cache: dict[tuple[int, int, int], tuple[str, tuple[str, ...]]] = {}
_ttys: dict[int, str | None] = {}


def _pids() -> list[int]:
    n = _lib.proc_listallpids(None, 0)
    buf = (C.c_int * (n + 64))()
    n = _lib.proc_listallpids(buf, C.sizeof(buf))
    return buf[: max(n, 0)]


def _exe(pid: int) -> str:
    return _path.value.decode("utf-8", "replace") if _lib.proc_pidpath(pid, _path, 4096) > 0 else ""


def _args(pid: int) -> tuple[str, ...]:
    mib = (C.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = C.c_size_t(_ARGMAX)
    if _lib.sysctl(mib, 3, C.byref(_argbuf), C.byref(size), None, 0) != 0:
        return ()
    raw = C.string_at(C.addressof(_argbuf), size.value)
    argc = int.from_bytes(raw[:4], "little")
    parts = raw[4:].split(b"\0")
    i = 1  # parts[0] — путь exe, за ним нули выравнивания; после argv идёт окружение — его не читаем
    while i < len(parts) and not parts[i]:
        i += 1
    return tuple(a.decode("utf-8", "replace") for a in parts[i:i + argc])


def _tty(dev: int) -> str | None:
    if dev == 0xFFFFFFFF:  # NODEV: нет управляющего терминала
        return None
    if dev not in _ttys:
        name = _lib.devname(dev - (1 << 32) if dev >= 1 << 31 else dev, 0o020000)  # S_IFCHR
        _ttys[dev] = name.decode() if name and name != b"??" else None
    return _ttys[dev]


def _name(args: tuple[str, ...], exe: str, comm: bytes) -> str:
    a0 = args[0].strip() if args else ""
    name = os.path.basename(a0) or os.path.basename(exe) or comm.decode("utf-8", "replace")
    return name.lstrip("-") or "?"  # «-zsh» у login-шелла


def _read(pid: int, root_mem: dict[int, float], cmprs: dict[int, float], live: dict) -> Proc | None:
    if _lib.proc_pidinfo(pid, _BSDINFO_UNIQ, 0, C.byref(_bi), C.sizeof(_bi)) == C.sizeof(_bi):
        b = _bi
        key = (pid, b.uniqueid, b.idversion)
        exe, args = live[key] = _cache.get(key) or (_exe(pid), _args(pid))
        readable = _lib.proc_pid_rusage(pid, 4, C.byref(_ru)) == 0  # RUSAGE_INFO_V4
        has_cwd = _lib.proc_pidinfo(pid, _VNODEPATHINFO, 0, C.byref(_vp), C.sizeof(_vp)) == C.sizeof(_vp)
        fp = _ru.phys_footprint / MB if readable else root_mem.get(pid)
        return Proc(
            pid=pid, ppid=b.ppid, uid=format(b.uniqueid, "x"), start_ts=b.start_sec + b.start_usec / 1e6,
            name=_name(args, exe, b.comm), exe=exe, cwd=_vp.cdir.decode("utf-8", "replace") if has_cwd else None,
            args=args, tty=_tty(b.tdev), user=b.uid, mem_mb=fp,
            peak_mb=_ru.lifetime_max_phys_footprint / MB if readable else fp,
            readable=readable, pgid=b.pgid, tpgid=b.tpgid,
            res_mb=_ru.resident_size / MB if readable else None, wired_mb=_ru.wired_size / MB if readable else None,
            cmprs_mb=cmprs.get(pid),
        )
    # root и чужие uid: только то, что ядро отдаёт всем
    if _lib.proc_pidinfo(pid, _SHORTBSD, 0, C.byref(_sb), C.sizeof(_sb)) != C.sizeof(_sb):
        return None  # уже завершился или зомби
    if _lib.proc_pidinfo(pid, _UNIQID, 0, C.byref(_uq), C.sizeof(_uq)) != C.sizeof(_uq):
        return None
    key = (pid, _uq.uniqueid, _uq.idversion)
    exe = (live.setdefault(key, _cache.get(key) or (_exe(pid), ())))[0]
    fp = root_mem.get(pid)
    return Proc(
        pid=pid, ppid=_sb.ppid, uid=format(_uq.uniqueid, "x"), start_ts=0.0,
        name=_name((), exe, _sb.comm), exe=exe, cwd=None, args=(), tty=None, user=_sb.uid,
        mem_mb=fp, peak_mb=fp, readable=False, pgid=_sb.pgid, cmprs_mb=cmprs.get(pid),
    )


def scan() -> dict[int, Proc]:
    """Все процессы мака за один проход (~10–25 мс)."""
    global _cache
    root_mem, cmprs = system.root_cache(), system.cmprs_cache()
    with _lock:
        live: dict = {}
        out = {}
        for pid in _pids():
            p = _read(pid, root_mem, cmprs, live)
            if p:
                out[pid] = p
        # кэш живёт ровно столько, сколько процессы: записи мёртвых (pid, uniqueid) выпадают сами
        _cache = live
    return out


def identity(pid: int) -> str | None:
    """Текущий uniqueid процесса или None, если процесса уже нет (зомби тоже считается завершённым)."""
    uq = _Uniq()
    if _lib.proc_pidinfo(pid, _UNIQID, 0, C.byref(uq), C.sizeof(uq)) != C.sizeof(uq):
        return None
    return format(uq.uniqueid, "x")


def children(procs: dict[int, Proc]) -> dict[int, list[int]]:
    kids: dict[int, list[int]] = {}
    for p in procs.values():
        if p.pid != p.ppid:
            kids.setdefault(p.ppid, []).append(p.pid)
    return kids


def tree(procs: dict[int, Proc], root: int, kids: dict[int, list[int]] | None = None) -> list[int]:
    """Процесс и все его потомки: сначала самые глубокие, корень последним — порядок остановки."""
    kids = children(procs) if kids is None else kids
    order, seen = [root], {root}
    for pid in order:
        for k in kids.get(pid, ()):
            if k not in seen:
                seen.add(k)
                order.append(k)
    return order[::-1]


def ancestors(procs: dict[int, Proc], pid: int) -> list[int]:
    """Цепочка предков: родитель, дед, … до launchd."""
    out: list[int] = []
    p = procs.get(pid)
    while p and p.ppid != p.pid and p.ppid not in out:
        out.append(p.ppid)
        p = procs.get(p.ppid)
    return out


_SECRET = re.compile(r"(?i)token|secret|passw|api[-_]?key|auth|bearer|cookie|credential")
_RANDOM = re.compile(r"[A-Za-z0-9+_=:.-]{32,}")  # длинная строка без слешей — похоже на ключ или uuid
_APP = re.compile(r"/([^/]+)\.app/")
SHORT = {"Google Chrome": "Chrome", "Google Chrome Beta": "Chrome Beta", "Google Chrome Canary": "Chrome Canary",
         "Microsoft Edge": "Edge", "Brave Browser": "Brave"}
BROWSERS = {"Arc", "Chrome", "Chrome Beta", "Chrome Canary", "Chromium", "Edge", "Brave", "Opera", "Vivaldi", "Yandex",
            "Dia", "Comet"}
# хелперы Chromium и Electron по --type; рендерер у браузера — вкладка, у Electron-приложения — окно
_TYPES = {"gpu-process": "GPU", "crashpad-handler": "отчёты о сбоях", "ppapi": "плагин", "plugin": "плагин"}
_UTILITY = {"network": "сеть", "audio": "звук", "storage": "хранилище", "video_capture": "камера"}


def app_short(name: str) -> str:
    return SHORT.get(name, name)


def _helper_label(p: Proc) -> str | None:
    """«Arc · вкладка», «Chrome · GPU»: процесс-хелпер браузера или Electron (он всегда внутри .app — так
    «webpack --type=prod» из проекта не примем за хелпер), без сырых аргументов."""
    kind = next((a.partition("=")[2] for a in p.args[1:] if a.startswith("--type=")), None)
    m = _APP.search(p.exe)
    if kind is None or not m:
        return None
    app = app_short(m[1])
    if kind == "renderer":
        what = "расширение" if "--extension-process" in p.args else "вкладка" if app in BROWSERS else "окно"
    elif kind == "utility":
        sub = next((a.partition("=")[2] for a in p.args if a.startswith("--utility-sub-type=")), "")
        what = _UTILITY.get(sub.split(".", 1)[0], "служба")
    else:
        what = _TYPES.get(kind, "служба")
    return f"{app} · {what}"


def label(p: Proc, width: int = 60) -> str:
    """Короткая подпись процесса для UI: имя и значимые аргументы. Секреты из аргументов не показываем,
    хелперы браузеров подписываем по-человечески («Arc · вкладка»)."""
    if helper := _helper_label(p):
        return helper[:width]
    parts, skip = [p.name], False
    for a in p.args[1:]:
        if skip:
            skip = False
            continue
        if _SECRET.search(a):
            skip = a.startswith("-") and "=" not in a  # «--token VALUE»: значение — следующий аргумент
            continue
        if not a or _RANDOM.fullmatch(a):
            continue
        parts.append("/".join(a.split("/")[-3:]) if a.startswith("/") else a)
        if sum(map(len, parts)) >= width:
            break
    return " ".join(parts)[:width]


def listen_ports(pid: int) -> list[str]:
    """Слушающие TCP-сокеты процесса вида '127.0.0.1:8765' — без lsof (он стоит ~25 мс CPU)."""
    size = _lib.proc_pidinfo(pid, _LISTFDS, 0, None, 0)
    if size <= 0:
        return []
    fds = C.create_string_buffer(size)
    size = _lib.proc_pidinfo(pid, _LISTFDS, 0, fds, size)
    sock = C.create_string_buffer(792)  # sizeof(struct socket_fdinfo)
    out = set()
    for fd, fdtype in struct.iter_unpack("<iI", fds.raw[: max(size, 0) // 8 * 8]):
        if fdtype != 2 or _lib.proc_pidfdinfo(pid, fd, 3, sock, 792) != 792:  # PROX_FDTYPE_SOCKET, PROC_PIDFDSOCKETINFO
            continue
        s = sock.raw
        options, kind = struct.unpack_from("<h", s, 188)[0], struct.unpack_from("<i", s, 256)[0]
        if kind != 2 or not options & 0x2:  # SOCKINFO_TCP и SO_ACCEPTCONN — сокет слушает
            continue
        port = socket.ntohs(struct.unpack_from("<i", s, 268)[0] & 0xFFFF)
        if s[288] & 0x2:  # INI_IPV6
            out.add(f"[{socket.inet_ntop(socket.AF_INET6, s[312:328])}]:{port}")
        else:
            out.add(f"{socket.inet_ntop(socket.AF_INET, s[324:328])}:{port}")
    return sorted(out)
