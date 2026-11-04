import Foundation

/// Сборка данных «Сессий» по замеру: сессии Claude, вкладки терминалов, tmux/Docker, сироты, память ИИ.
/// Правила один в один с lambscape (sessions.py, snapshot.py).
final class SessionsBuilder: @unchecked Sendable {
    static let heavyMB = 500.0

    private let transcripts = TranscriptReader()
    private let mux = MuxProbe()
    private let sessionsDir: String
    private let projectsDir: String

    init(home: String = NSHomeDirectory()) {
        sessionsDir = home + "/.claude/sessions"
        projectsDir = home + "/.claude/projects"
    }

    func refreshMux(maxAge: TimeInterval = 10) { mux.refreshIfStale(maxAge: maxAge) }

    struct Input {
        var procs: [Int32: LoadProcess]
        var tree: ProcessTree
        var planner: StopPlanner
        var roots: [String]
        var launchdPIDs: Set<Int32>
        var selfPid: Int32
        var now: TimeInterval
    }

    func build(_ i: Input) -> SessionsData {
        let claude = claudeSessions(i)
        var data = SessionsData()
        data.claude = claude
        data.terminals = terminals(i, claude: claude)
        let probes = mux.current()
        data.tmux = probes.tmux
        data.docker = probes.docker
        data.orphans = Advice.orphans(procs: i.procs, tree: i.tree, launchdPIDs: i.launchdPIDs, now: i.now)
        data.stoppableOrphans = Set(data.orphans.map(\.pid).filter { pid in i.procs[pid].map(i.planner.canStop) ?? false })
        data.ai = Self.aiMemory(procs: i.procs, tree: i.tree, claude: claude)
        return data
    }

    // MARK: Сессии Claude

    /// Данные `<pid>.json` — только если файл про этот самый процесс: pid переиспользуется, и json прежнего
    /// процесса старше нынешнего.
    static func sessionMeta(_ path: String, process p: LoadProcess) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (meta["pid"] as? NSNumber)?.int32Value == p.pid else { return [:] }
        if let started = ms(meta["startedAt"]), started > 0, Double(started) < p.startTime - 5 { return [:] }
        return meta
    }

    private static func ms(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Int(n.doubleValue / 1000)
    }

    private func claudeSessions(_ i: Input) -> [ClaudeSession] {
        let me = getuid()
        let above = Set(i.tree.ancestors(of: i.selfPid, in: i.procs))
        var out: [ClaudeSession] = []
        var seen: Set<String> = []
        for p in i.procs.values where p.user == me && Kinds.isClaude(p) {
            let meta = Self.sessionMeta("\(sessionsDir)/\(p.pid).json", process: p)
            let cwd = (meta["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? p.cwd ?? ""
            let proj = Attribution.sessionProject(cwd: cwd, roots: i.roots)
            let sid = meta["sessionId"] as? String
            let order = i.tree.subtree(of: p.pid)
            let status = (meta["status"] as? String).flatMap(SessionStatus.init(rawValue:)) ?? .unknown
            let app = Kinds.hostApp(of: p, procs: i.procs)
            let path = TranscriptReader.path(projectsDir: projectsDir, cwd: cwd, sessionID: sid)
            if let path { seen.insert(path) }

            let started = Self.ms(meta["startedAt"]).flatMap { $0 > 0 ? TimeInterval($0) : nil } ?? p.startTime
            // updatedAt/statusUpdatedAt из json или последняя метка транскрипта — что новее: пока сессия busy,
            // json не меняется весь ход, а транскрипт пишется.
            var last = max(Self.ms(meta["updatedAt"]) ?? 0, Self.ms(meta["statusUpdatedAt"]) ?? 0)
            var activity = SessionActivity()
            if let path {
                last = max(last, Int(transcripts.lastTimestamp(path: path)))
                activity = transcripts.activity(path: path)
            }
            let name = (meta["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? proj?.name ?? (cwd.split(separator: "/").last.map(String.init) ?? "claude")
            let version = (meta["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (p.exe.contains("/claude/versions/") ? p.exeName : "")
            out.append(ClaudeSession(
                pid: p.pid, sessionID: sid, name: name, project: proj?.name, cwd: cwd, status: status,
                startedAt: started, lastActivity: last > 0 ? TimeInterval(last) : p.startTime, activity: activity,
                memMB: order.reduce(0.0) { $0 + (i.procs[$1]?.mem ?? 0) }, version: version,
                children: order.dropLast().compactMap { child($0, i) }.sorted { ($0.memMB ?? 0) > ($1.memMB ?? 0) },
                resumeCommand: sid.map(TranscriptReader.isSafeID) == true && app == nil ? "claude --resume \(sid!)" : "",
                hostApp: app, isSelf: above.contains(p.pid), stoppable: i.planner.canStop(p)))
        }
        transcripts.prune(keeping: seen) // кэш разбора — только для живых сессий
        return out.sorted { $0.memMB != $1.memMB ? $0.memMB > $1.memMB : $0.pid < $1.pid }
    }

    private func child(_ pid: Int32, _ i: Input) -> SessionChild? {
        guard let p = i.procs[pid] else { return nil }
        let kind = Kinds.childKind(p)
        let heavy = kind == .devServer || p.mem >= Self.heavyMB
        return SessionChild(pid: pid, name: Kinds.label(p), kind: kind, memMB: p.memMB, age: p.age(now: i.now) ?? 0,
                            stoppable: heavy && i.planner.canStop(p))
    }

    // MARK: Вкладки терминалов

    /// Шелл, чей родитель — хост терминала или login под ним. Проект — по cwd шелла.
    private func terminals(_ i: Input, claude: [ClaudeSession]) -> [TerminalHost] {
        let me = getuid()
        let byPid = Dictionary(claude.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let inSessions = Set(claude.flatMap { i.tree.subtree(of: $0.pid) })
        var hosts: [Int32: TerminalHost] = [:]
        for p in i.procs.values where Kinds.shells.contains(p.name) && p.user == me {
            var host = i.procs[p.ppid]
            if host?.name == "login" { host = host.flatMap { i.procs[$0.ppid] } }
            guard let host, let app = Kinds.terminalApp(host) else { continue }
            let fg = p.tpgid != 0 && p.tpgid != p.pgid ? i.procs[p.tpgid]?.name ?? "" : ""
            let order = i.tree.subtree(of: p.pid)
            // dev-серверы и тяжёлые процессы вкладки, кроме сессий Claude в ней (у них своя карточка).
            let kids = order.dropLast().compactMap { q -> SessionChild? in
                guard !inSessions.contains(q), let c = child(q, i), c.isHot else { return nil }
                return c
            }.sorted { ($0.memMB ?? 0) > ($1.memMB ?? 0) }
            let shell = TerminalShell(
                pid: p.pid, tty: p.tty, cwd: p.cwd, project: Attribution.project(of: p.cwd, roots: i.roots)?.name,
                foreground: fg, children: kids, sessions: order.compactMap { byPid[$0] }, stoppable: i.planner.canStop(p))
            hosts[host.pid, default: TerminalHost(app: app, hostPid: host.pid, shells: [])].shells.append(shell)
        }
        return hosts.values.sorted { $0.hostPid < $1.hostPid }.map { h in
            var h = h
            h.shells.sort { $0.pid < $1.pid }
            return h
        }
    }

    // MARK: Память ИИ

    static let aiLabels = ["Сессии Claude Code", "MCP-серверы", "Claude.app", "Боты и скрипты (claude -p)", "ollama", "whisper"]
    private enum Part: Int { case session, mcp, app, print, ollama, whisper }

    /// Сколько памяти держит ИИ. Каждый процесс попадает в одну часть, вместе со своими потомками:
    /// claude -p, ollama и whisper — целиком; сессия и Claude.app — кроме MCP (своя часть) и dev-серверов
    /// (это работа проекта, а не ИИ).
    static func aiMemory(procs: [Int32: LoadProcess], tree: ProcessTree, claude: [ClaudeSession]) -> AIMemory {
        var part: [Int32: Part?] = [:]

        func walk(_ root: Int32, _ idx: Part) {
            var stack: [(Int32, Part?)] = [(root, idx)]
            while let (pid, cur) = stack.popLast() {
                if part.keys.contains(pid) { continue } // уже посчитан — вместе со своим поддеревом
                var i = cur
                if pid != root, let c = cur, c == .session || c == .app, let p = procs[pid] {
                    switch Kinds.childKind(p) {
                    case .devServer: i = nil
                    case .mcp: i = .mcp
                    default: break
                    }
                }
                part[pid] = .some(i)
                for k in tree.children[pid] ?? [] where procs[k] != nil { stack.append((k, i)) }
            }
        }

        let ordered = procs.values.sorted { $0.pid < $1.pid }
        for p in ordered {
            // whisper на python виден только по argv[0]
            let names = [p.exeName.lowercased(), p.name.lowercased()]
            if Kinds.isPrint(p) { walk(p.pid, .print) }
            else if names.contains(where: { $0.hasPrefix("ollama") }) { walk(p.pid, .ollama) }
            else if names.contains(where: { $0.hasPrefix("whisper") }) { walk(p.pid, .whisper) }
        }
        for s in claude where procs[s.pid] != nil { walk(s.pid, .session) }
        for p in ordered where Kinds.appName(of: p.exe) == "Claude" { walk(p.pid, .app) }

        var mem = [Double](repeating: 0, count: aiLabels.count)
        var count = [Int](repeating: 0, count: aiLabels.count)
        for (pid, idx) in part {
            guard let idx, let p = procs[pid] else { continue }
            mem[idx.rawValue] += p.mem
            count[idx.rawValue] += 1
        }
        return AIMemory(parts: aiLabels.enumerated().map { AIMemory.Part(label: $1, memMB: mem[$0], count: count[$0]) })
    }
}
