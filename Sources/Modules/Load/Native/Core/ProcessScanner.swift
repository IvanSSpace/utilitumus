import Darwin
import Foundation

/// proc_uniqidentifierinfo: в публичных заголовках структуры нет, раскладка — 56 байт
/// (uuid, p_uniqueid, p_puniqueid, p_idversion, …). Нужен только uniqueid и idversion.
private struct UniqInfo {
    var uuid0: UInt64 = 0
    var uuid1: UInt64 = 0
    var uniqueID: UInt64 = 0
    var parentUniqueID: UInt64 = 0
    var idVersion: Int32 = 0
    var origParentIDVersion: Int32 = 0
    var reserved0: UInt64 = 0
    var reserved1: UInt64 = 0
}

private let flavorUniqueID: Int32 = 17 // PROC_PIDUNIQIDENTIFIERINFO

/// Строка из C-массива фиксированного размера (поля libproc приходят кортежами).
private func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Скан процессов через libproc, без `ps` и без запуска чего-либо. Не потокобезопасен:
/// живёт внутри `LoadEngine` (актор), один проход за раз.
///
/// Свои процессы читаются целиком (память, путь, cwd, аргументы); у root и чужих
/// uid ядро отдаёт только ppid, имя, путь и uniqueid — их память подставляется
/// из кэша `top`, а у кого его нет, остаётся неизвестной (nil), а не нулём.
final class ProcessScanner {
    private struct Key: Hashable {
        let pid: Int32
        let uniqueID: UInt64
        let idVersion: Int32
    }

    /// Всё, что не меняется, пока процесс не сделал exec: считаем один раз.
    private struct Static {
        let exe: String
        let args: [String]
        let name: String
        let exeName: String
        let isClaude: Bool
        let terminal: String?

        init(exe: String, args: [String], comm: String) {
            self.exe = exe
            self.args = args
            name = ProcessScanner.processName(args: args, exe: exe, comm: comm)
            exeName = String(exe.split(separator: "/").last ?? "")
            isClaude = Kinds.isClaudeSession(exe: exe, exeName: exeName, name: name, args: args)
            terminal = Kinds.terminalApp(name: name, exe: exe)
        }
    }

    /// Путь и аргументы живут, пока жив процесс: ключ (pid, uniqueid, idversion) меняется при exec.
    private var cache: [Key: Static] = [:]
    private var cpuPrev: [Key: UInt64] = [:]
    private var lastScan: UInt64 = 0
    private var ttys: [UInt32: String?] = [:]

    private let argCapacity = 2 << 20
    private let argBuffer: UnsafeMutableRawPointer
    private let pathBuffer: UnsafeMutablePointer<CChar>
    private let timebase: mach_timebase_info_data_t

    init() {
        // Выделено, но не заполнено: в footprint попадут только страницы, куда пишет ядро.
        argBuffer = UnsafeMutableRawPointer.allocate(byteCount: argCapacity, alignment: 16)
        pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 4096)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb
    }

    deinit {
        argBuffer.deallocate()
        pathBuffer.deallocate()
    }

    /// Все процессы мака за один проход.
    /// - Parameters:
    ///   - rootMemory: PID → footprint MB из `top` для процессов без доступа.
    ///   - compressed: PID → сжато/своп MB из `top`.
    func scan(rootMemory: [Int32: Double], compressed: [Int32: Double]) -> [Int32: LoadProcess] {
        let now = DispatchTime.now().uptimeNanoseconds
        let wallDelta = lastScan == 0 ? 0 : now &- lastScan
        lastScan = now

        var live: [Key: Static] = [:]
        var liveCPU: [Key: UInt64] = [:]
        var out: [Int32: LoadProcess] = [:]
        let unixNow = Date().timeIntervalSince1970

        for pid in allPIDs() {
            if let p = read(pid, rootMemory: rootMemory, compressed: compressed, wallDelta: wallDelta,
                            unixNow: unixNow, live: &live, liveCPU: &liveCPU) {
                out[pid] = p
            }
        }
        // Кэши живут ровно столько, сколько процессы: записи мёртвых выпадают сами.
        cache = live
        cpuPrev = liveCPU
        return out
    }

    /// Текущий uniqueid процесса или nil, если процесса уже нет (зомби тоже считается завершённым).
    static func identity(of pid: Int32) -> UInt64? {
        var u = UniqInfo()
        let size = Int32(MemoryLayout<UniqInfo>.size)
        guard proc_pidinfo(pid, flavorUniqueID, 0, &u, size) == size else { return nil }
        return u.uniqueID
    }

    private func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<Int32>.size))
        return Array(buf.prefix(max(Int(got), 0))).filter { $0 > 0 || $0 == 0 }
    }

    private func ticksToNs(_ t: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer), denom = UInt64(timebase.denom)
        return t / denom * numer + t % denom * numer / denom
    }

    private func read(_ pid: Int32, rootMemory: [Int32: Double], compressed: [Int32: Double], wallDelta: UInt64,
                      unixNow: TimeInterval, live: inout [Key: Static], liveCPU: inout [Key: UInt64]) -> LoadProcess? {
        var uniq = UniqInfo()
        let uniqSize = Int32(MemoryLayout<UniqInfo>.size)

        var task = proc_taskallinfo()
        let taskSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &task, taskSize) == taskSize,
           proc_pidinfo(pid, flavorUniqueID, 0, &uniq, uniqSize) == uniqSize {
            let b = task.pbsd
            let key = Key(pid: pid, uniqueID: uniq.uniqueID, idVersion: uniq.idVersion)
            let known = cache[key] ?? Static(exe: exePath(pid), args: arguments(pid), comm: cString(b.pbi_comm))
            live[key] = known

            var ru = rusage_info_v4()
            let readable = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0

            var vnode = proc_vnodepathinfo()
            let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            let cwd: String? = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize
                ? cString(vnode.pvi_cdir.vip_path) : nil

            // Время CPU в тиках mach (на Apple Silicon тик ≠ наносекунда).
            let cpuNs = ticksToNs(task.ptinfo.pti_total_user &+ task.ptinfo.pti_total_system)
            liveCPU[key] = cpuNs
            var cpu: Double?
            if wallDelta > 0, let prev = cpuPrev[key], cpuNs >= prev {
                cpu = Double(cpuNs - prev) / Double(wallDelta) * 100
            }

            let footprint = readable ? Double(ru.ri_phys_footprint) / 1_048_576 : rootMemory[pid]
            return LoadProcess(
                pid: pid, ppid: Int32(bitPattern: b.pbi_ppid), user: b.pbi_uid, uniqueID: uniq.uniqueID,
                startTime: TimeInterval(b.pbi_start_tvsec) + TimeInterval(b.pbi_start_tvusec) / 1e6,
                name: known.name, exe: known.exe, exeName: known.exeName, isClaude: known.isClaude, terminal: known.terminal, cwd: cwd, args: known.args, tty: tty(Int32(bitPattern: b.e_tdev)),
                memMB: footprint,
                residentMB: readable ? Double(ru.ri_resident_size) / 1_048_576 : nil,
                wiredMB: readable ? Double(ru.ri_wired_size) / 1_048_576 : nil,
                compressedMB: compressed[pid], readable: readable,
                pgid: Int32(bitPattern: b.pbi_pgid), tpgid: Int32(bitPattern: b.e_tpgid), cpuPercent: cpu)
        }

        // root и чужие uid: только то, что ядро отдаёт всем.
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize,
              proc_pidinfo(pid, flavorUniqueID, 0, &uniq, uniqSize) == uniqSize else {
            return nil // уже завершился или зомби
        }
        let key = Key(pid: pid, uniqueID: uniq.uniqueID, idVersion: uniq.idVersion)
        let known = cache[key] ?? Static(exe: exePath(pid), args: [], comm: cString(short.pbsi_comm))
        live[key] = known
        let footprint = rootMemory[pid]
        return LoadProcess(
            pid: pid, ppid: Int32(bitPattern: short.pbsi_ppid), user: short.pbsi_uid, uniqueID: uniq.uniqueID,
            startTime: 0, name: known.name, exe: known.exe, exeName: known.exeName, isClaude: false,
            terminal: known.terminal, cwd: nil, args: [], tty: nil, memMB: footprint, residentMB: nil, wiredMB: nil,
            compressedMB: compressed[pid], readable: false,
            pgid: Int32(bitPattern: short.pbsi_pgid), tpgid: 0, cpuPercent: nil)
    }

    private func exePath(_ pid: Int32) -> String {
        proc_pidpath(pid, pathBuffer, 4096) > 0 ? String(cString: pathBuffer) : ""
    }

    /// argv из KERN_PROCARGS2: argc, путь exe, нули выравнивания, потом argc строк (окружение не читаем).
    private func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argCapacity
        guard sysctl(&mib, 3, argBuffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let bytes = UnsafeRawBufferPointer(start: argBuffer, count: size)
        let argc = Int(bytes.load(as: Int32.self))
        var i = 4
        while i < size, bytes[i] != 0 { i += 1 }
        while i < size, bytes[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc, i < size {
            var j = i
            while j < size, bytes[j] != 0 { j += 1 }
            out.append(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[i..<j]), as: UTF8.self))
            i = j + 1
        }
        return out
    }

    private func tty(_ dev: Int32) -> String? {
        let key = UInt32(bitPattern: dev)
        if key == 0xFFFF_FFFF { return nil } // NODEV: нет управляющего терминала
        if let hit = ttys[key] { return hit }
        var name: String?
        if let c = devname(dev_t(dev), mode_t(S_IFCHR)) {
            let s = String(cString: c)
            name = s == "??" ? nil : s
        }
        ttys[key] = .some(name)
        return name
    }

    /// Имя процесса: basename argv[0], иначе exe, иначе comm; «-zsh» у login-шелла без дефиса.
    static func processName(args: [String], exe: String, comm: String) -> String {
        func base(_ s: String) -> String { s.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "" }
        let a0 = args.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = [base(a0), base(exe), comm].first { !$0.isEmpty } ?? ""
        let trimmed = String(name.drop { $0 == "-" })
        return trimmed.isEmpty ? "?" : trimmed
    }
}
