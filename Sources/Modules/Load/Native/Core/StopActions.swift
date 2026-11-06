import AppKit
import Darwin

/// Что и почему не трогаем, составление плана остановки и сама остановка.
/// Правила один в один с lambscape (actions.py):
/// - не трогаем pid ≤ 1, саму панель и всех её предков, всё дерево сессии Claude, из которой запущена панель,
///   сессии, которые ведёт приложение (Claude.app, IDE), хост вкладок терминала, чужие uid и
///   WindowServer, loginwindow, Dock, Finder, SystemUIServer, ControlCenter;
/// - системный файл (кроме шелла) не бывает целью, но в дереве цели он — команда пользователя
///   (sleep, tail, ssh) и останавливается вместе с деревом;
/// - SIGTERM всем, сначала глубоким; до 5 с ждём; SIGKILL только тем, кто жив и всё ещё тот же процесс.
enum Protection {
    static let systemNames: Set<String> = ["WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer", "ControlCenter"]
    static let systemDirs = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

    /// Запущенные лаунчер, утилиты и помощники. Панель может работать в утилите, и тогда лаунчер ей не предок.
    static func ownPids() -> Set<Int32> {
        Set(Kit.ownBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .map(\.processIdentifier))
    }

    /// pid → почему не трогаем: панель и её предки, дерево сессии Claude, из которой запущена панель,
    /// наши приложения и сессии Claude, которые ведёт приложение. `extra` — процессы ботов из bots.toml со всеми потомками.
    static func fence(procs: [Int32: LoadProcess], tree: ProcessTree, selfPid: Int32 = getpid(),
                      ownPids: Set<Int32> = Protection.ownPids(), extra: [Int32: String] = [:]) -> [Int32: String] {
        var out: [Int32: String] = [selfPid: "это сама панель"]
        let ups = tree.ancestors(of: selfPid, in: procs)
        for pid in ups { out[pid] = "предок панели" }
        for pid in ups {
            if let p = procs[pid], Kinds.isClaude(p) {
                for q in tree.subtree(of: pid) where out[q] == nil { out[q] = "сессия, из которой запущена панель" }
            }
        }
        for pid in ownPids where out[pid] == nil { out[pid] = "компонент Utilitumus" }
        for (pid, why) in extra where out[pid] == nil { out[pid] = why }
        // .app панель не останавливает: убить агента Claude.app значит сломать чат, а не освободить память.
        for p in procs.values where Kinds.isClaude(p) {
            if let app = Kinds.hostApp(of: p, procs: procs), out[p.pid] == nil { out[p.pid] = "сессией управляет \(app).app" }
        }
        return out
    }

    /// Почему процесс нельзя трогать, или nil. `root` — цель действия: системный файл ею быть не может,
    /// кроме шелла. Потомок цели — свой процесс пользователя, даже если это sleep или ssh.
    static func why(_ p: LoadProcess, fence: [Int32: String], root: Bool) -> String? {
        if p.pid <= 1 { return "системный процесс" }
        if let why = fence[p.pid] { return why }
        if p.user != getuid() { return "процесс другого пользователя" }
        // Только вместе с путём: процесс может назваться Dock, а файл из системного каталога ему не подложить.
        if systemNames.contains(p.exeName), Kinds.isOSExecutable(p.exe) { return "системный процесс" }
        if Kinds.terminalApp(p) != nil { return "хост вкладок терминала" }
        if p.exe.isEmpty { return "не удалось прочитать путь" }
        let isShell = p.exe.hasPrefix("/bin/") && Kinds.shells.contains(p.exeName)
        if root, systemDirs.contains(where: { p.exe.hasPrefix($0) }), !p.exe.hasPrefix("/usr/local/"),
           !p.exe.hasPrefix("/System/Volumes/Data/"), !isShell {
            return "системный файл"
        }
        return nil
    }
}

/// Что остановится по кнопке. Строится по снимку для подтверждения, а перед сигналом
/// `StopExecutor` проверяет всё заново по свежему скану.
struct StopPlan: Sendable, Identifiable {
    struct Target: Sendable, Identifiable {
        var pid: Int32
        var uniqueID: UInt64
        /// Подпись для экрана: с аргументами.
        var name: String
        /// Для журнала: только имя, в аргументах бывают пароли.
        var processName: String
        var memMB: Double
        /// Цель верхнего уровня: к ней применяется правило «системный файл».
        var isRoot: Bool
        var id: Int32 { pid }
    }

    struct Kept: Sendable, Identifiable {
        var name: String
        var why: String
        var id: String { "\(name)|\(why)" }
    }

    enum Scope: Sendable {
        case process(Int32)
        case group(String)
    }

    let id = UUID()
    var scope: Scope
    var title: String
    var message: String
    /// Сначала самые глубокие, корень последним — порядок остановки.
    var targets: [Target]
    var kept: [Kept]
    var totalMB: Double
}

struct StopPlanner {
    let procs: [Int32: LoadProcess]
    let tree: ProcessTree
    let fence: [Int32: String]

    init(procs: [Int32: LoadProcess], fence: [Int32: String]? = nil, tree: ProcessTree? = nil) {
        self.procs = procs
        let t = tree ?? ProcessTree(procs)
        self.tree = t
        self.fence = fence ?? Protection.fence(procs: procs, tree: t)
    }

    func canStop(_ p: LoadProcess) -> Bool { Protection.why(p, fence: fence, root: true) == nil }

    private func names(_ pids: [Int32]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for q in pids {
            guard let n = procs[q]?.name else { continue }
            if counts[n] == nil { order.append(n) }
            counts[n, default: 0] += 1
        }
        let parts = order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
        return parts.prefix(4).joined(separator: ", ") + (parts.count > 4 ? " и ещё \(parts.count - 4)" : "")
    }

    private func target(_ q: Int32, root: Bool) -> StopPlan.Target {
        let p = procs[q]!
        return StopPlan.Target(pid: q, uniqueID: p.uniqueID, name: Kinds.label(p), processName: p.name, memMB: p.mem, isRoot: root)
    }

    /// Остановка процесса и его потомков. nil — сам процесс трогать нельзя.
    func plan(process pid: Int32) -> StopPlan? {
        guard let p = procs[pid], Protection.why(p, fence: fence, root: true) == nil else { return nil }
        let order = tree.subtree(of: pid)
        var targets: [StopPlan.Target] = []
        var kept: [StopPlan.Kept] = []
        for q in order {
            guard let proc = procs[q] else { continue }
            if let why = Protection.why(proc, fence: fence, root: q == pid) {
                kept.append(StopPlan.Kept(name: proc.name, why: why))
            } else {
                targets.append(target(q, root: q == pid))
            }
        }
        let others = targets.filter { $0.pid != pid }.sorted { $0.memMB > $1.memMB }
        let total = targets.reduce(0.0) { $0 + $1.memMB }
        var text = "Остановит \(Kinds.label(p)), освободит ≈\(Fmt.mb(total))."
        if !others.isEmpty { text += " Остановятся также: \(names(others.map(\.pid)))." }
        if !kept.isEmpty { text += " Не тронет защищённые: \(kept.prefix(4).map(\.name).joined(separator: ", "))." }
        return StopPlan(scope: .process(pid), title: "Остановить \(p.name)", message: text, targets: targets, kept: kept, totalMB: total)
    }

    /// Остановка группы: её процессы, которые можно трогать. Потомки за пределами группы не затрагиваются.
    func plan(group: ProcessGroup) -> StopPlan? {
        var targets: [StopPlan.Target] = []
        var kept: [StopPlan.Kept] = []
        let members = Set(group.members.map(\.pid))
        // Глубокие раньше родителей: считаем глубину по цепочке внутри группы.
        func depth(_ pid: Int32) -> Int {
            var d = 0
            var cur = procs[pid]?.ppid
            while let c = cur, members.contains(c), d < 64 {
                d += 1
                cur = procs[c]?.ppid
            }
            return d
        }
        for m in group.members {
            guard let p = procs[m.pid] else { continue }
            if let why = Protection.why(p, fence: fence, root: !members.contains(p.ppid)) {
                kept.append(StopPlan.Kept(name: p.name, why: why))
            } else {
                // Правило «системный файл» — только для корней группы: sleep или tail под шеллом группы — команда пользователя.
                targets.append(target(m.pid, root: !members.contains(p.ppid)))
            }
        }
        guard !targets.isEmpty else { return nil }
        targets.sort { depth($0.pid) > depth($1.pid) }
        let total = targets.reduce(0.0) { $0 + $1.memMB }
        var text = "Остановит \(Fmt.plural(targets.count, "процесс", "процесса", "процессов")) группы «\(group.name)», освободит ≈\(Fmt.mb(total))."
        if !kept.isEmpty { text += " Не тронет защищённые: \(kept.count)." }
        return StopPlan(scope: .group(group.id), title: "Остановить группу «\(group.name)»", message: text,
                        targets: targets, kept: kept, totalMB: total)
    }
}

struct StopResult: Sendable {
    var ok: Bool
    var message: String
    var freedMB: Int
}

enum StopExecutor {
    static let grace: TimeInterval = 5

    private static func signal(_ pid: Int32, _ sig: Int32) -> Bool {
        Darwin.kill(pid, sig) == 0
    }

    private static func alive(_ items: [(Int32, UInt64)]) -> [(Int32, UInt64)] {
        items.filter { ProcessScanner.identity(of: $0.0) == $0.1 }
    }

    /// SIGTERM каждой цели (список уже от глубоких к корню), до `grace` ждём выхода, затем SIGKILL тем,
    /// кто жив и всё ещё тот же процесс. Перед каждым сигналом uniqueid сверяется заново.
    static func stopTree(_ targets: [(pid: Int32, uniqueID: UInt64)], grace: TimeInterval, mem: [Int32: Double])
        -> (stopped: Int, killed: Int, survived: Int, freedMB: Int) {
        let termed = targets.filter { ProcessScanner.identity(of: $0.pid) == $0.uniqueID && signal($0.pid, SIGTERM) }
            .map { ($0.pid, $0.uniqueID) }
        var left = termed
        var deadline = Date().addingTimeInterval(grace)
        while !left.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            left = alive(left)
        }
        let killed = left.filter { ProcessScanner.identity(of: $0.0) == $0.1 && signal($0.0, SIGKILL) }
        var survived = killed
        deadline = Date().addingTimeInterval(1)
        while !survived.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            survived = alive(survived)
        }
        let survivedPids = Set(survived.map(\.0))
        let gone = termed.map(\.0).filter { !survivedPids.contains($0) }
        return (termed.count - killed.count, killed.count - survived.count, survived.count,
                Int(gone.reduce(0.0) { $0 + (mem[$1] ?? 0) }.rounded()))
    }

    /// Выполнить план по свежему скану. Всё, что за это время завершилось или сменилось, пропускаем;
    /// защищённое проверяем заново.
    static func execute(_ plan: StopPlan, procs: [Int32: LoadProcess], extraFence: [Int32: String] = [:],
                        grace: TimeInterval = StopExecutor.grace) -> StopResult {
        let tree = ProcessTree(procs)
        let fence = Protection.fence(procs: procs, tree: tree, extra: extraFence)

        if case .process(let pid) = plan.scope {
            guard let want = plan.targets.first(where: { $0.pid == pid }) else {
                return StopResult(ok: false, message: "Нечего останавливать", freedMB: 0)
            }
            guard let now = ProcessScanner.identity(of: pid) else {
                return StopResult(ok: false, message: "Процесс уже завершился — обнови экран", freedMB: 0)
            }
            guard now == want.uniqueID else {
                return StopResult(ok: false, message: "Процесс сменился: этот PID уже занят другим процессом — обнови экран", freedMB: 0)
            }
            if let root = procs[pid], let why = Protection.why(root, fence: fence, root: true) {
                return StopResult(ok: false, message: "Не трогаю \(root.name): \(why)", freedMB: 0)
            }
        }

        var targets: [(pid: Int32, uniqueID: UInt64)] = []
        var kept: [String] = []
        for t in plan.targets {
            guard let p = procs[t.pid], p.uniqueID == t.uniqueID else { continue } // ушёл, а если pid занят другим — тем более не трогаем
            if let why = Protection.why(p, fence: fence, root: t.isRoot) {
                kept.append("\(p.name) (\(why))")
                continue
            }
            targets.append((t.pid, t.uniqueID))
        }
        let keptText = kept.isEmpty ? "" : ". Не тронуты: \(kept.prefix(5).joined(separator: ", "))" + (kept.count > 5 ? "…" : "")
        guard !targets.isEmpty else {
            return StopResult(ok: true, message: "Нечего останавливать: процессы уже завершились" + keptText, freedMB: 0)
        }
        let r = stopTree(targets, grace: grace, mem: procs.mapValues(\.mem))
        let n = r.stopped + r.killed
        var message = "Остановлено \(Fmt.plural(n, "процесс", "процесса", "процессов")), освобождено ≈\(Fmt.mb(r.freedMB))"
        if r.killed > 0 { message += " (\(r.killed) — только через SIGKILL)" }
        if r.survived > 0 { message += ". Не завершились даже после SIGKILL: \(r.survived)" }
        return StopResult(ok: r.survived == 0, message: message + keptText, freedMB: r.freedMB)
    }
}
