import Darwin
import Foundation

/// Что модуль знает о процессе бота. Боты опознаются по метке launchd из bots.toml, а не по имени процесса.
struct BotProc: Sendable, Equatable {
    var memMB: Double
    var start: TimeInterval
    var children: [Int32]
}

/// Статус ботов из файла, `launchctl list` и процессов. Читает только; ничего не запускает и никого не сигналит.
enum BotsMonitor {
    typealias Probe = (Int32) -> BotProc?

    /// Карточки по описанию в файле. `launchd` — разобранный `launchctl list`, `appPIDs` — pid запущенных приложений
    /// по bundle id. Чистая функция: проверка подставляет и то и другое.
    static func cards(_ bots: [BotSpec], launchd: [String: Int32?], appPIDs: [String: [Int32]] = [:], dirPIDs: [String: [Int32]] = [:], now: Date = Date(),
                      probe: Probe, ports: (Set<Int32>) -> [String] = { BotRegistry.cachedListenPorts(of: $0) }) -> [BotCard] {
        bots.prefix(BotsState.maxBots).map { spec in
            let labelled = Set(spec.launchd.compactMap { launchd[$0] ?? nil })
            let apps = Set(spec.bundleIDs.flatMap { appPIDs[$0] ?? [] })
            let byDir = Set(spec.watchDir.flatMap { dirPIDs[$0] } ?? [])
            let mains = labelled.union(apps).union(byDir).sorted()
            var all = Set<Int32>()
            for root in mains { all.formUnion(subtree(of: root, probe: probe)) }
            let up: Int, total: Int
            if !spec.launchd.isEmpty {
                up = spec.launchd.filter { (launchd[$0] ?? nil) != nil }.count
                total = spec.launchd.count
            } else if spec.bundleIDs.isEmpty, spec.watchDir != nil {
                up = byDir.isEmpty ? 0 : 1
                total = 1
            } else {
                up = spec.bundleIDs.filter { !(appPIDs[$0] ?? []).isEmpty }.count
                total = spec.bundleIDs.count
            }
            let missing = BotRegistry.envMissing(spec)
            let state = BotRegistry.classify(up: up, total: total, missing: missing)
            // Аптайм — по процессам launchd: менюбар-приложение бота живёт неделями и врало бы.
            let starts = (labelled.isEmpty ? Set(mains) : labelled).compactMap { probe($0)?.start }.filter { $0 > 0 }
            let uptime = starts.min().map { max(0, Int(now.timeIntervalSince1970 - $0)) / 60 * 60 } ?? 0
            return BotCard(
                id: spec.id, name: spec.name, project: spec.project, state: state,
                memMB: Int(all.reduce(0.0) { $0 + (probe($1)?.memMB ?? 0) }.rounded()), uptime: uptime,
                ports: all.isEmpty ? [] : ports(all), url: safeURL(spec.url),
                note: state == .noConfig ? BotRegistry.noConfigNote(spec, missing: missing) : spec.note,
                verbs: BotRegistry.offered(spec, state))
        }
    }

    /// Процессы бота без метки launchd: интерпретатор или сама программа с рабочей папкой `watch_dir`. Только чтение.
    /// Стенд настоящие процессы не смотрит.
    static func pidsByDir(_ dirs: Set<String>) -> [String: [Int32]] {
        #if KIT_TEST_DEFAULTS
        return [:]
        #else
        guard !dirs.isEmpty else { return [:] }
        var out: [String: [Int32]] = [:]
        for p in BotsDiscovery.liveProcesses() where dirs.contains(p.cwd) && BotsDiscovery.isRuntime(exe: p.exe, cwd: p.cwd) {
            out[p.cwd, default: []].append(p.pid)
        }
        return out
        #endif
    }

    /// Процесс и потомки. Предел на случай кольца в ответе.
    static func subtree(of root: Int32, probe: Probe) -> Set<Int32> {
        var seen: Set<Int32> = [root]
        var queue = [root]
        var i = 0
        while i < queue.count, seen.count < 256 {
            for child in probe(queue[i])?.children ?? [] where seen.insert(child).inserted { queue.append(child) }
            i += 1
        }
        return seen
    }

    /// Правило живёт в `BotsText`: его же применяет экран.
    static func safeURL(_ raw: String?) -> String? { BotsText.safeURL(raw) }

    /// Файл целиком в состояние экрана; список ботов отдельно, чтобы экран не зависел от причины.
    static func fileState(_ file: BotRegistry.File) -> BotsFileState {
        if !file.exists { return BotsFileState(kind: .missing, detail: "") }
        switch file.problem {
        case .unsafe(let why)?: return BotsFileState(kind: .unsafe, detail: why)
        case .invalid?: return BotsFileState(kind: .invalid, detail: "Не удалось разобрать файл: проверь кавычки и скобки.")
        case nil: return .ok
        }
    }

    // MARK: Живые данные

    /// `launchctl list` без shell и без прав; пусто, если не ответил.
    static func readLaunchd() -> [String: Int32?] {
        let r = Exec.run([Exec.launchctl, "list"], env: Exec.launchctlEnv(), timeout: 10)
        guard r.launchError == nil, !r.timedOut, r.code == 0 else { return [:] }
        return LaunchdList.parse(r.stdout)
    }

    /// Память (phys_footprint), время запуска и дети одного процесса через libproc. nil — процесса нет или он чужой.
    static func liveProbe(_ pid: Int32) -> BotProc? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        var ru = rusage_info_v4()
        let readable = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        var kids = [Int32](repeating: 0, count: 128)
        let got = proc_listchildpids(pid, &kids, Int32(kids.count * MemoryLayout<Int32>.size))
        let children = got > 0 ? Array(kids.prefix(Int(got))).filter { $0 > 0 } : []
        return BotProc(memMB: readable ? Double(ru.ri_phys_footprint) / 1_048_576 : 0,
                       start: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6, children: children)
    }
}
