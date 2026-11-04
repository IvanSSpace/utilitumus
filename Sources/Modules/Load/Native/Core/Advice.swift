import Foundation

enum AdviceSeverity: Int, Sendable, Comparable {
    case high = 0, med = 1, low = 2

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    static func forMB(_ mb: Double) -> AdviceSeverity { mb >= 2048 ? .high : mb >= 500 ? .med : .low }
}

/// Подсказка «что выключить». Кнопка — остановка процесса `stopPid` (если можно).
struct AdviceItem: Sendable, Identifiable {
    var id: String
    var severity: AdviceSeverity
    var title: String
    var detail: String
    var savesMB: Int
    var stopPid: Int32?
}

/// Правила подсказок lambscape (advice.py): долгоживущие dev-серверы и тяжёлые потомки сессий и вкладок
/// терминала, простаивающие сессии Claude, сироты, одинаковые MCP в нескольких сессиях, модели ollama,
/// рост свопа и высокое давление.
enum Advice {
    static let longRunning: TimeInterval = 2 * 3600
    static let heavyMB = 500.0
    static let swapGrowthMB = 500

    struct Context {
        var procs: [Int32: LoadProcess]
        var tree: ProcessTree
        var planner: StopPlanner
        var memory: MemoryTotals
        var map: MemoryMap
        var swapGrowthMB: Int?
        var launchdPIDs: Set<Int32>
        var ollama: (Bool) -> [OllamaProbe.Model]
        var roots: [String]
        var now: TimeInterval
        /// Сессии Claude (для правил про простой и дубли MCP).
        var sessions: [ClaudeSession] = []
    }

    static func build(_ c: Context) -> [AdviceItem] {
        var items = longRunningItems(c) + idleItems(c) + orphanItems(c) + mcpItems(c) + ollamaItems(c) + swapItems(c)
        items.sort { $0.severity != $1.severity ? $0.severity < $1.severity : $0.savesMB > $1.savesMB }
        return items
    }

    // MARK: Долгоживущие

    /// Кто породил процесс: сессия Claude или вкладка терминала.
    private struct Found {
        var pid: Int32
        var why: String
    }

    /// Потомки сессий Claude и шеллов во вкладках терминала. Сам shell и claude — не кандидаты.
    private static func candidates(_ c: Context) -> [Found] {
        let me = getuid()
        var found: [Found] = []
        var inSessions: Set<Int32> = []
        for s in c.procs.values where s.user == me && Kinds.isClaude(s) {
            let name = Attribution.sessionProject(cwd: s.cwd, roots: c.roots)?.name ?? "claude"
            let order = c.tree.subtree(of: s.pid)
            inSessions.formUnion(order)
            for q in order.dropLast() { found.append(Found(pid: q, why: "его запустила сессия «\(name)»")) }
        }
        for sh in c.procs.values where Kinds.shells.contains(sh.name) && sh.user == me {
            var host = c.procs[sh.ppid]
            if host?.name == "login" { host = host.flatMap { c.procs[$0.ppid] } }
            guard let host, Kinds.terminalApp(host) != nil else { continue }
            let project = Attribution.project(of: sh.cwd, roots: c.roots)?.name
            let where_ = project.map { " (\($0))" } ?? ""
            for q in c.tree.subtree(of: sh.pid).dropLast() where !inSessions.contains(q) {
                found.append(Found(pid: q, why: "запущен во вкладке \(sh.tty ?? String(sh.pid))\(where_)"))
            }
        }
        return found
    }

    /// dev-сервер дольше 2 ч или любой потомок больше 500 MB и дольше 2 ч. Вложенные (npm start:dev → webpack)
    /// не дублируем: кнопка обёртки гасит и то, что под ней.
    private static func longRunningItems(_ c: Context) -> [AdviceItem] {
        var hits: [(pid: Int32, why: String, plan: StopPlan, age: Double)] = []
        for f in candidates(c) {
            guard let p = c.procs[f.pid], let age = p.age(now: c.now), age >= longRunning,
                  Kinds.childKind(p) == .devServer || p.mem >= heavyMB,
                  let plan = c.planner.plan(process: f.pid) else { continue }
            hits.append((f.pid, f.why, plan, age))
        }
        var inner: Set<Int32> = []
        for h in hits { for t in h.plan.targets where t.pid != h.pid { inner.insert(t.pid) } }
        var out: [AdviceItem] = []
        var seen: Set<Int32> = []
        for h in hits where !inner.contains(h.pid) && seen.insert(h.pid).inserted {
            guard let p = c.procs[h.pid] else { continue }
            let mb = h.plan.totalMB > 0 ? h.plan.totalMB : p.mem
            out.append(AdviceItem(
                id: "adv:dev-server:\(h.pid)", severity: .forMB(mb),
                title: "\(Kinds.label(p, width: 40)) висит \(Int(h.age) / 3600) ч и держит \(Fmt.mb(mb)) — остановить?",
                detail: h.why, savesMB: Int(mb.rounded()), stopPid: h.pid))
        }
        return out
    }

    // MARK: Сессии Claude

    static let idleAfter: TimeInterval = 6 * 3600

    /// Сессия «ждёт» больше 6 ч, и её можно остановить (не текущая и не под приложением).
    private static func idleItems(_ c: Context) -> [AdviceItem] {
        c.sessions.compactMap { s in
            let idle = c.now - (s.lastActivity > 0 ? s.lastActivity : c.now)
            guard s.status == .idle, idle > idleAfter, s.stoppable else { return nil }
            let detail = s.resumeCommand.isEmpty ? "sessionId неизвестен — продолжить через --resume не выйдет"
                : "продолжить потом: \(s.resumeCommand)"
            return AdviceItem(id: "adv:idle:\(s.pid)", severity: .forMB(s.memMB), title: "Сессия \(s.name) простаивает \(Int(idle) / 3600) ч",
                              detail: detail, savesMB: Int(s.memMB.rounded()), stopPid: s.pid)
        }
    }

    /// «github-mcp-server» из «node …/github-mcp-server/dist/index.js»: первое слово с признаком MCP.
    private static func mcpName(_ label: String) -> String {
        label.split(whereSeparator: { $0 == "/" || $0.isWhitespace }).first { $0.range(of: "mcp", options: .caseInsensitive) != nil }
            .map(String.init) ?? label
    }

    /// Один и тот же MCP-сервер в двух сессиях и больше: каждая сессия поднимает свою копию. Совет без кнопки.
    private static func mcpItems(_ c: Context) -> [AdviceItem] {
        var per: [String: [Int32: Double]] = [:] // сервер → сессия → MB
        for s in c.sessions {
            for k in s.children where k.kind == .mcp { per[mcpName(k.name), default: [:]][s.pid, default: 0] += k.memMB ?? 0 }
        }
        let dups = per.filter { $0.value.count >= 2 }
        guard !dups.isEmpty else { return [] }
        let names = dups.keys.sorted { a, b in
            let (x, y) = (dups[a]!.values.reduce(0, +), dups[b]!.values.reduce(0, +))
            return x != y ? x > y : a < b
        }
        let total = dups.values.reduce(0.0) { $0 + $1.values.reduce(0, +) }
        let extra = dups.values.reduce(0.0) { $0 + $1.values.reduce(0, +) - ($1.values.max() ?? 0) } // всё, кроме одной копии
        let more = names.count > 3 ? " и ещё \(names.count - 3)" : ""
        let sessions = dups.values.map(\.count).max() ?? 0
        return [AdviceItem(
            id: "adv:mcp", severity: .low,
            title: "MCP \(names.prefix(3).joined(separator: ", "))\(more) запущены в \(sessions) сессиях — \(Fmt.mb(total))",
            detail: "Подключай их только в нужных проектах (.mcp.json проекта), а не глобально — тогда остальные сессии не будут поднимать свои копии",
            savesMB: Int(extra.rounded()), stopPid: nil)]
    }

    // MARK: Сироты

    struct Orphan: Sendable, Identifiable {
        var pid: Int32
        var name: String
        var memMB: Double
        var age: Double
        var id: Int32 { pid }
    }

    /// Свои процессы с ppid=1: не .app, не под launchd и похожи на node/python/bun/uv/deno/MCP.
    /// Без списка заданий launchd не отличить сироту от KeepAlive-бота, поэтому тогда их нет.
    static func orphans(procs: [Int32: LoadProcess], tree: ProcessTree, launchdPIDs: Set<Int32>, now: TimeInterval) -> [Orphan] {
        guard !launchdPIDs.isEmpty else { return [] }
        let me = getuid()
        var out: [Orphan] = []
        for p in procs.values where p.ppid == 1 && p.user == me && !launchdPIDs.contains(p.pid) && Kinds.appName(of: p.exe) == nil {
            let name = p.name.lowercased()
            guard Kinds.interpreters.contains(name) || name.hasPrefix("python")
                    || p.args.joined(separator: " ").lowercased().contains("mcp") else { continue }
            let mem = tree.subtree(of: p.pid).reduce(0.0) { $0 + (procs[$1]?.mem ?? 0) }
            out.append(Orphan(pid: p.pid, name: Kinds.label(p), memMB: mem.rounded(), age: p.age(now: now) ?? 0))
        }
        return out.sorted { $0.memMB > $1.memMB }
    }

    private static func orphanItems(_ c: Context) -> [AdviceItem] {
        let all = orphans(procs: c.procs, tree: c.tree, launchdPIDs: c.launchdPIDs, now: c.now)
        let stoppable = all.filter { c.planner.plan(process: $0.pid) != nil }
        guard let big = stoppable.max(by: { $0.memMB < $1.memMB }) else { return [] }
        let n = all.count, total = all.reduce(0.0) { $0 + $1.memMB }
        let title = "\(n) \(Fmt.word(n, "осиротевший процесс держит", "осиротевших процесса держат", "осиротевших процессов держат")) \(Fmt.mb(total))"
        return [AdviceItem(
            id: "adv:orphans", severity: .forMB(big.memMB), title: title,
            detail: "Родитель завершился, launchd ими не управляет. Кнопка — для самого большого: \(big.name) (\(Fmt.mb(big.memMB)))",
            savesMB: Int(big.memMB), stopPid: big.pid)]
    }

    // MARK: ollama

    private static func ollamaItems(_ c: Context) -> [AdviceItem] {
        let running = c.procs.values.contains {
            $0.name.lowercased().hasPrefix("ollama") || ($0.exe.split(separator: "/").last.map { $0.lowercased().hasPrefix("ollama") } ?? false)
        }
        let models = c.ollama(running)
        guard !models.isEmpty else { return [] }
        let mb = Double(models.reduce(0) { $0 + $1.mb })
        let names = models.map(\.name).joined(separator: ", ")
        return [AdviceItem(
            id: "adv:ollama", severity: .forMB(mb), title: "ollama держит в памяти \(names) — \(Fmt.mb(mb))",
            detail: "Выгрузить: ollama stop \(models[0].name) — или закрой ollama, если она сейчас не нужна",
            savesMB: Int(mb), stopPid: nil)]
    }

    // MARK: Своп и давление

    /// Своп вырос на 500 MB за 30 мин или давление warn/critical — что выключить первым:
    /// три главных кандидата из «Что можно освободить», кроме самой macOS.
    private static func swapItems(_ c: Context) -> [AdviceItem] {
        let growth = c.swapGrowthMB ?? 0
        guard growth >= swapGrowthMB || c.memory.pressure != .normal else { return [] }
        let top = c.map.freeCandidates.filter { $0.key != "macos" }.prefix(3)
        let title = growth >= swapGrowthMB ? "Своп растёт: +\(Fmt.mb(growth)) за 30 мин"
            : "Давление памяти \(c.memory.pressure == .critical ? "критическое" : "повышенное")"
        let detail = top.isEmpty ? "Закрой то, что сейчас не нужно"
            : "Что выключить первым: " + top.map { "\($0.name) (\(Fmt.mb($0.totalMB)))" }.joined(separator: ", ")
        return [AdviceItem(
            id: "adv:swap", severity: c.memory.pressure == .critical ? .high : .med, title: title, detail: detail,
            savesMB: top.reduce(0) { $0 + $1.totalMB }, stopPid: nil)]
    }
}
