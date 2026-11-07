import Foundation

// Статус бота по замеру «Нагрузки»: процессы, дерево и launchd берутся из снимка.

struct BotItem: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var state: BotState
    var pids: [Int32]
    var memMB: Int
    var uptime: TimeInterval
    var ports: [String]
    var url: String?
    var note: String
    var actions: [BotVerb]
    /// Команды из bots.toml: остаются в модуле, в связь не идут.
    var spec = BotSpec.none

    var isOn: Bool { state == .running || state == .partial }

    private enum CodingKeys: String, CodingKey { case id, name, state, pids, memMB, uptime, ports, url, note, actions }
}

extension BotRegistry {
    /// Главные процессы бота: pid его меток launchd, запущенные .app с его bundle id и процессы из `watch_dir`.
    static func pids(of spec: BotSpec, procs: [Int32: LoadProcess], launchd: [String: Int32?]) -> [Int32] {
        var out = Set<Int32>()
        for label in spec.launchd {
            if let outer = launchd[label], let pid = outer, procs[pid] != nil { out.insert(pid) }
        }
        if !spec.bundleIDs.isEmpty {
            for p in procs.values where p.exe.contains(".app/Contents/MacOS/") {
                if let id = bundleID(ofExe: p.exe), spec.bundleIDs.contains(id) { out.insert(p.pid) }
            }
        }
        if let dir = spec.watchDir {
            for p in procs.values where p.cwd == dir && isRuntime(exe: p.exe, cwd: dir) { out.insert(p.pid) }
        }
        return out.sorted()
    }

    /// pid → причина: процессы ботов со всеми потомками трогает только команда из bots.toml
    /// (kill агента с KeepAlive — это перезапуск, а не остановка).
    static func fence(_ bots: [BotSpec], procs: [Int32: LoadProcess], tree: ProcessTree, launchd: [String: Int32?]) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for b in bots {
            for main in pids(of: b, procs: procs, launchd: launchd) {
                for q in tree.subtree(of: main) where out[q] == nil { out[q] = "процесс бота \(b.id) — только его кнопками" }
            }
        }
        return out
    }


    static func status(_ spec: BotSpec, procs: [Int32: LoadProcess], tree: ProcessTree, launchd: [String: Int32?]) -> BotItem {
        let mains = pids(of: spec, procs: procs, launchd: launchd)
        let all = Set(mains.flatMap { tree.subtree(of: $0) })
        // Статус — по меткам launchd (их и гасит команда из конфига); .app вроде менюбара — только в pid и памяти.
        let up: Int, total: Int
        if !spec.launchd.isEmpty {
            up = spec.launchd.filter { label in (launchd[label] ?? nil).map { procs[$0] != nil } ?? false }.count
            total = spec.launchd.count
        } else if spec.bundleIDs.isEmpty, spec.watchDir != nil {
            up = mains.isEmpty ? 0 : 1
            total = 1
        } else {
            let found = Set(mains.compactMap { procs[$0].flatMap { bundleID(ofExe: $0.exe) } })
            up = spec.bundleIDs.filter { found.contains($0) }.count
            total = spec.bundleIDs.count
        }
        let missing = envMissing(spec)
        let state = classify(up: up, total: total, missing: missing)
        let note = state == .noConfig ? noConfigNote(spec, missing: missing) : spec.note
        let wanted = offered(spec, state)
        // Аптайм — по процессам launchd: менюбар-приложение бота живёт неделями и врало бы.
        let labelled = Set(spec.launchd.compactMap { launchd[$0] ?? nil }).intersection(mains)
        let starts = (labelled.isEmpty ? Set(mains) : labelled).compactMap { procs[$0]?.startTime }.filter { $0 > 0 }
        let ports = cachedListenPorts(of: all)
        return BotItem(
            id: spec.id, name: ScreenText.clean(spec.name, BotRunner.maxShown), state: state, pids: mains,
            memMB: Int(all.reduce(0.0) { $0 + (procs[$1]?.mem ?? 0) }.rounded()),
            uptime: starts.min().map { Date().timeIntervalSince1970 - $0 } ?? 0, ports: ports, url: spec.url,
            note: ScreenText.clean(note, BotRunner.maxShown), actions: wanted, spec: spec)
    }
}
