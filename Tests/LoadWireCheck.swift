import AppKit
import SwiftUI

// «Нагрузка» перед переносом: состояние и действия через JSON, проверка каждого действия, экран на подставной модели.
// Запуск: Tests/run-load-wire-check.sh. Движок и исполнители подставные: ничего не останавливается, не запускается и не
// пишется в настоящие load-history.json и actions.log. Pid стенда больше настоящих (PID_MAX на macOS 99999).
// Роли: logic, render <папка>, render-remote <папка>, diff <папка> <папка>, measure <копия истории>.
// LOAD_BASELINE — сборка из исходников до подготовки, чтобы сравнить снимки: там другие типы и остановка по строкам.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// MARK: - Данные стенда

let fixedNow: TimeInterval = 1_780_000_000
let secret = "hunter2"

func proc(_ pid: Int32, ppid: Int32 = 1, name: String, exe: String, args: [String] = [], mem: Double? = 100, user: UInt32 = getuid(),
          claude: Bool = false, terminal: String? = nil, cwd: String? = nil, tty: String? = nil, cpu: Double? = nil, age: Double = 9000) -> LoadProcess {
    LoadProcess(pid: pid, ppid: ppid, user: user, uniqueID: 7_000_000 + UInt64(pid), startTime: fixedNow - age, name: name, exe: exe,
                exeName: String(exe.split(separator: "/").last ?? ""), isClaude: claude, terminal: terminal, cwd: cwd, args: args, tty: tty,
                memMB: mem, residentMB: mem.map { $0 * 0.8 }, wiredMB: pid == 900006 ? 80 : nil, compressedMB: mem.map { $0 * 0.1 }, readable: true,
                pgid: pid, tpgid: 0, cpuPercent: cpu)
}

let fixtureProcs: [Int32: LoadProcess] = {
    let list = [
        proc(900001, ppid: 900010, name: "node", exe: "/Users/u/.nvm/bin/node", args: ["node", "vite", "--port", "5173"], mem: 1800, cwd: "/Users/u/shop", cpu: 12),
        proc(900002, ppid: 900010, name: "claude", exe: "/Users/u/.local/share/claude/versions/2.0/claude", args: ["claude"], mem: 900, claude: true, cwd: "/Users/u/shop", cpu: 3),
        proc(900003, ppid: 900002, name: "node", exe: "/Users/u/.nvm/bin/node", args: ["node", "mcp-server", "--token", secret], mem: 120),
        proc(900004, ppid: 900002, name: "node", exe: "/Users/u/.nvm/bin/node", args: ["node", "webpack", "serve"], mem: 950, cwd: "/Users/u/other"),
        proc(900005, name: "python3", exe: "/Users/u/bin/python3", args: ["python3", "worker.py"], mem: 640, cwd: "/Users/u/shop"),
        proc(900006, name: "Google Chrome", exe: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", args: ["Google Chrome"], mem: 2200, cpu: 25),
        proc(900007, ppid: 900006, name: "Google Chrome Helper", exe: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", args: ["Helper", "--type=renderer"], mem: 700),
        proc(900008, name: "WindowServer", exe: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer", mem: 1300),
        proc(900009, name: "kernel_task", exe: "/usr/libexec/rootd", mem: nil, user: 0),
        proc(900010, ppid: 900011, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], mem: 8, terminal: nil, cwd: "/Users/u/shop", tty: "ttys001"),
        proc(900011, name: "iTerm2", exe: "/Applications/iTerm.app/Contents/MacOS/iTerm2", mem: 400, terminal: "iTerm2"),
        proc(900012, ppid: 900010, name: "sleep", exe: "/bin/sleep", args: ["sleep", "100"], mem: 1),
        proc(900013, ppid: 900011, name: "claude", exe: "/Users/u/.local/share/claude/versions/2.0/claude", args: ["claude"], mem: 500, claude: true, cwd: "/Users/u/self"),
        proc(900014, name: "uv", exe: "/Users/u/bin/uv", args: ["uv", "run"], mem: 90),
        proc(900015, ppid: 900011, name: "zsh", exe: "/bin/zsh", args: ["-zsh"], mem: 7, cwd: "/Users/u", tty: "ttys002"),
    ]
    return Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
}()

let fixtureAssigned: [Int32: Assignment] = {
    var out: [Int32: Assignment] = [:]
    for pid in [900001, 900002, 900003, 900004, 900010, 900012, 900013] as [Int32] {
        out[pid] = Assignment(groupID: "project:shop", why: "cwd", path: "/Users/u/shop")
    }
    for pid in [900006, 900007] as [Int32] { out[pid] = Assignment(groupID: "app:Chrome", why: "bundle", path: nil) }
    for pid in [900008, 900009, 900011] as [Int32] { out[pid] = Assignment(groupID: "system", why: "path", path: nil) }
    for pid in [900005, 900014, 900015] as [Int32] { out[pid] = Assignment(groupID: "other", why: "", path: nil) }
    return out
}()

let fixtureFence: [Int32: String] = [900013: "сессия, из которой запущена панель", 900011: "хост вкладок терминала"]

func fixtureSnapshot() -> LoadSnapshot {
    let procs = fixtureProcs
    let tree = ProcessTree(procs)
    let memory = MemoryTotals(totalMB: 32768, usedMB: 21000, appMB: 12000, wiredMB: 4000, compressedMB: 5000, cachedMB: 6000, freeMB: 1500,
                              swapUsedMB: 3500, swapTotalMB: 4096, pressure: .warn)
    let planner = StopPlanner(procs: procs, fence: fixtureFence, tree: tree)
    var groups = Grouping.groups(procs: procs, assigned: fixtureAssigned, stoppable: planner.canStop)
    for i in groups.indices where groups[i].id == "system" {
        groups[i].hints = [SystemHint(title: "Меньше окон", how: "закрой лишние", savesMB: 0), SystemHint(title: "Статичные обои", how: "выбери картинку", savesMB: 80)]
    }
    let map = MemoryMap.build(procs: procs, assigned: fixtureAssigned, groups: groups, memory: memory, stoppable: planner.canStop)

    let webpack = SessionChild(pid: 900004, name: "node webpack serve", kind: .devServer, memMB: 950, age: 7200, stoppable: true,
                               place: ProcessPlace(project: "other", path: "~/other", isHome: false))
    let mcp = SessionChild(pid: 900003, name: "node mcp-server", kind: .mcp, memMB: 120, age: 7200, stoppable: false, place: nil)
    let vite = SessionChild(pid: 900001, name: "node vite --port 5173", kind: .devServer, memMB: 1800, age: 9000, stoppable: true, place: nil)
    let sid = "11111111-2222-3333-4444-555555555555"
    let busy = ClaudeSession(pid: 900002, sessionID: sid, name: "shop-b9", project: "shop", cwd: "/Users/u/shop", status: .busy,
                             startedAt: fixedNow - 7200, lastActivity: fixedNow - 60,
                             activity: SessionActivity(lastPrompt: "почини кнопку", lastPromptTS: fixedNow - 70, lastAction: "Edit: a.swift", lastActionTS: fixedNow - 60),
                             memMB: 1970, version: "2.0", children: [webpack, mcp], resumeCommand: "claude --resume \(sid)", hostApp: nil, isSelf: false, stoppable: true)
    let own = ClaudeSession(pid: 900013, sessionID: nil, name: "self", project: nil, cwd: "/Users/u/self", status: .idle, startedAt: fixedNow - 300, lastActivity: fixedNow - 200,
                            activity: SessionActivity(), memMB: 500, version: "", children: [], resumeCommand: "", hostApp: nil, isSelf: true, stoppable: false)
    let hosted = ClaudeSession(pid: 900016, sessionID: nil, name: "chat", project: nil, cwd: "/Users/u", status: .unknown, startedAt: 0, lastActivity: 0,
                               activity: SessionActivity(), memMB: 300, version: "", children: [], resumeCommand: "", hostApp: "Claude", isSelf: false, stoppable: false)
    let shell = TerminalShell(pid: 900010, tty: "ttys001", cwd: "/Users/u/shop", project: "shop", foreground: "node", children: [vite], sessions: [busy], stoppable: true)
    let idleShell = TerminalShell(pid: 900015, tty: nil, cwd: "/Users/u", project: nil, foreground: "", children: [], sessions: [], stoppable: false)
    let orphan = Advice.Orphan(pid: 900005, name: "python3 worker.py", memMB: 640, age: 86400, place: ProcessPlace(project: "shop", path: "~/shop", isHome: false))
    let lost = Advice.Orphan(pid: 900014, name: "uv run", memMB: 90, age: 3700, place: nil)
    var sessions = SessionsData()
    sessions.claude = [busy, own, hosted]
    sessions.terminals = [TerminalHost(app: "iTerm2", hostPid: 900011, shells: [shell, idleShell])]
    sessions.tmux = TmuxInfo(running: true, sessions: [.init(name: "main", windows: 3, attached: true), .init(name: "bg", windows: 1, attached: false)])
    sessions.docker = DockerInfo(running: true, containers: [.init(id: "abc", name: "db", image: "postgres:16", state: "running", status: "Up 2 hours")])
    sessions.orphans = [orphan, lost]
    sessions.stoppableOrphans = [900005]
    sessions.ai = AIMemory(parts: [.init(label: "Сессии Claude", memMB: 1400, count: 2), .init(label: "Ollama", memMB: 0, count: 0)])

    var advice = [
        AdviceItem(id: "adv:dev-server:900001", severity: .high, title: "node vite висит 2 ч и держит 1.8 GB — остановить?", detail: "запущен из вкладки", savesMB: 1800, stopPid: 900001),
        AdviceItem(id: "adv:idle:900002", severity: .med, title: "Сессия shop-b9 простаивает 2 ч", detail: "можно продолжить", savesMB: 900, stopPid: 900002),
        AdviceItem(id: "adv:swap", severity: .low, title: "Своп растёт", detail: "закрой лишнее", savesMB: 0, stopPid: nil),
    ]
    #if !LOAD_BASELINE
    func uid(_ pid: Int32) -> UInt64 { procs[pid]?.uniqueID ?? 7_000_000 + UInt64(pid) }
    for i in advice.indices { advice[i].stopUniqueID = advice[i].stopPid.map(uid) }
    func fix(_ kids: inout [SessionChild]) { for i in kids.indices { kids[i].uniqueID = uid(kids[i].pid) } }
    for i in sessions.claude.indices {
        sessions.claude[i].uniqueID = uid(sessions.claude[i].pid)
        fix(&sessions.claude[i].children)
    }
    for s in sessions.terminals[0].shells.indices {
        sessions.terminals[0].shells[s].uniqueID = uid(sessions.terminals[0].shells[s].pid)
        fix(&sessions.terminals[0].shells[s].children)
        for k in sessions.terminals[0].shells[s].sessions.indices {
            sessions.terminals[0].shells[s].sessions[k].uniqueID = uid(sessions.terminals[0].shells[s].sessions[k].pid)
        }
    }
    for i in sessions.orphans.indices { sessions.orphans[i].uniqueID = uid(sessions.orphans[i].pid) }
    #else
    _ = advice.count
    #endif

    let disk = DiskCard(model: "APPLE SSD", sizeGB: 1000, wearPct: 3, writtenTB: 12.5, sparePct: 100, mediaErrors: 1, swapWrittenGBSinceBoot: 40,
                        swapGBPerDay: 2.5, swapSharePct: 12, swapWritten24hGB: 2, swap24SpanHours: 24)
    let host = HostInfo(chip: "Apple M4", ramMB: 32768, macOS: "26.2", bootTime: Date().timeIntervalSince1970 - 30 * 86400)
    return LoadSnapshot(timestamp: Date(timeIntervalSince1970: fixedNow), host: host, memory: memory, procs: procs, tree: tree, assigned: fixtureAssigned,
                        groups: groups, map: map, advice: advice, sessions: sessions, disk: disk, fence: fixtureFence, launchd: ["com.vendor.helper": 900020],
                        roots: ["/Users/u"], selfPid: 900013, selfMemMB: 123, selfCPU: 4.5, measureMillis: 42)
}

func fixtureHistory() -> HistoryWindow {
    let from = Int(fixedNow) - 86400 + 3000
    let points = (0..<280).map { i in
        HistoryWindow.Point(ts: from + i * 300, usedMB: 18000 + i * 10, swapMB: 1000 + i, pressure: i > 200 ? 2 : 1, values: [3000 + i, 2000, 1500 - i, 900, 500, 4000])
    }
    let series = [("project:shop", "shop"), ("app:Chrome", "Chrome"), ("system", "Система"), ("app:Slack", "Slack"), ("app:Mail", "Mail"), ("rest", "прочее")]
    return HistoryWindow(stepSeconds: 300, from: from - 3000, to: Int(fixedNow), series: series.map { .init(key: $0.0, name: $0.1) }, points: points, firstSample: from)
}

let botStop = ["/Users/u/bin/stop-bot", "--token", secret]
func loadTestBackground() -> BackgroundData {
    let helper = AgentItem(label: "com.vendor.helper", name: "Helper", vendor: "Vendor", plist: "/Users/u/Library/LaunchAgents/com.vendor.helper.plist", pids: [900020], memMB: 300,
                           keepalive: true, runAtLoad: true, disabled: false, domain: "gui", note: "обновления перестанут приходить", sudoHint: nil, verbs: [.stop, .disable],
                           targets: [AgentTarget(pid: 900020, name: "helper", memMB: 300)], loaded: true, refusal: nil, place: ProcessPlace(project: "vendor", path: "~/vendor", isHome: false))
    let off = AgentItem(label: "com.vendor.off", name: "Off", vendor: "", plist: "/Users/u/Library/LaunchAgents/com.vendor.off.plist", pids: [], memMB: 0,
                        keepalive: false, runAtLoad: false, disabled: true, domain: "gui", note: "", sudoHint: nil, verbs: [.enable], targets: [], loaded: false, refusal: nil)
    let root = AgentItem(label: "com.vendor.daemon", name: "", vendor: "", plist: "/Library/LaunchDaemons/com.vendor.daemon.plist", pids: [900021], memMB: 50,
                         keepalive: false, runAtLoad: true, disabled: false, domain: "system", note: "служба", sudoHint: "sudo launchctl bootout system/com.vendor.daemon", verbs: [], targets: [], loaded: true, refusal: "системная служба")
    let spec = BotSpec(id: "shopbot", name: "Shop bot", project: "shop", url: "https://bot.example", launchd: ["com.shop.bot"], bundleIDs: [],
                       commands: [.stop: .argv(botStop), .restart: .argv(["/Users/u/bin/restart-bot"])], requiresEnv: [], envFile: nil, note: "держит 8765")
    let running = BotItem(id: "shopbot", name: "Shop bot", state: .running, pids: [900022, 900023, 900024], memMB: 292, uptime: 172800, ports: ["8765"], url: "https://bot.example",
                          note: "держит 8765", actions: [.stop, .restart], spec: spec)
    let noConfig = BotItem(id: "newbot", name: "New bot", state: .noConfig, pids: [], memMB: 0, uptime: 0, ports: [], url: nil, note: "Не настроен: впиши TOKEN в .env", actions: [], spec: spec)
    return BackgroundData(agents: [helper, off, root], bots: [running, noConfig])
}

func loadTestJournal() -> [ActionLog.Entry] {
    [ActionLog.Entry(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, time: Date(timeIntervalSince1970: fixedNow - 600), kind: "bot", label: "секрет", ok: true, message: "выполнено"),
     ActionLog.Entry(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!, time: Date(timeIntervalSince1970: fixedNow - 300), kind: "agent", label: "x", ok: false, message: "launchctl не ответил")]
}

// MARK: - Подставной движок

#if !LOAD_BASELINE
final class FakeEngine: LoadMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var _executed: [UUID] = []
    private var _plans: [StopPlan] = []
    private var _refreshes = 0
    private var _hold = false
    let snapshot: LoadSnapshot
    init(_ s: LoadSnapshot) { snapshot = s }

    var executed: [UUID] { lock.withLock { _executed } }
    var plans: [StopPlan] { lock.withLock { _plans } }
    var refreshes: Int { lock.withLock { _refreshes } }
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    func recordHistory() async -> HistoryWindow { fixtureHistory() }
    func measure() async -> LoadSnapshot { snapshot }
    func historyWindow() async -> HistoryWindow { fixtureHistory() }
    func refreshNow() async -> LoadSnapshot {
        lock.withLock { _refreshes += 1 }
        return snapshot
    }
    func execute(_ plan: StopPlan) async -> StopResult {
        lock.withLock {
            _executed.append(plan.id)
            _plans.append(plan)
        }
        while hold { try? await Task.sleep(for: .milliseconds(10)) }
        return StopResult(ok: true, message: "стенд: ничего не остановлено", freedMB: 0)
    }
}

final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var _plans: [BackgroundPlan] = []
    private var _hold = false
    var plans: [BackgroundPlan] { lock.withLock { _plans } }
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    func run(_ plan: BackgroundPlan) -> StopResult {
        lock.withLock { _plans.append(plan) }
        while hold { Thread.sleep(forTimeInterval: 0.01) }
        return StopResult(ok: true, message: "стенд: ничего не запущено", freedMB: 0)
    }
}

func encoded(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)) ?? Data()
}

@MainActor func until(_ what: String, _ done: () -> Bool) async {
    for _ in 0..<500 {
        if done() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    check(false, "дождались: \(what)")
}

@MainActor func makeStore(_ engine: FakeEngine, _ runner: FakeRunner) async -> LoadStore {
    let background = BackgroundStore(collect: { _ in loadTestBackground() }, execute: { runner.run($0) }, readJournal: { loadTestJournal() })
    let store = LoadStore(engine: engine, background: background)
    store.apply(engine.snapshot, force: true)
    await until("список фонового") { background.hasContent }
    background.reloadJournal()
    await until("журнал") { !background.journal.isEmpty }
    store.start()
    await until("история") { store.history != nil }
    store.stop()
    return store
}

// MARK: - Логика

func realFileStamp(_ url: URL?) -> String {
    guard let url, let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "нет файла" }
    return "\(a[.size] ?? 0) \(a[.modificationDate] ?? 0)"
}

@MainActor func logic() async {
    // Страховка: если что-то всё же дойдёт до launchctl, это будет не настоящий launchctl.
    Exec.launchctl = "/usr/bin/false"
    let realFiles = [LoadHistory.realURL, ActionLog.file]
    let stamps = realFiles.map(realFileStamp)

    let engine = FakeEngine(fixtureSnapshot())
    let runner = FakeRunner()
    let store = await makeStore(engine, runner)
    let id = { (pid: Int32) in LoadRowID(pid: pid, uniqueID: 7_000_000 + UInt64(pid)) }

    // MARK: Состояние через JSON
    let state = store.wireState
    let json = encoded(state)
    let decoded = try? JSONDecoder().decode(LoadState.self, from: json)
    check(!json.isEmpty && decoded == state, "состояние через JSON с sortedKeys равно исходному, \(json.count) байт")
    check(decoded.map(encoded) == json, "после разбора те же байты")
    check(encoded(store.wireState) == json, "повторное кодирование даёт те же байты")
    let text = String(decoding: json, as: UTF8.self)
    for bad in ["\"procs\"", "\"tree\"", "\"fence\"", "\"launchd\"", "\"commands\"", "\"spec\"", "\"args\"", "\"exe\"", "\"image\"", "\"why\"", "\"targets\":[{\"memMB\":300", secret, "--token", "stop-bot", "lastPromptTS", "swapWrittenGBSinceBoot"] {
        check(!text.contains(bad), "в состоянии нет \(bad)")
    }
    for good in ["\"groups\"", "\"memory\"", "\"map\"", "\"advice\"", "\"sessions\"", "\"disk\"", "\"host\"", "\"history\"", "\"live\"", "\"background\"", "\"journal\""] {
        check(text.contains(good), "в состоянии есть \(good)")
    }
    var stale = state
    stale.live.selfMemMB = 1
    check(stale != state, "сравнение состояний видит разницу в подвале")

    // MARK: Действия через JSON
    let planID = UUID()
    let actions: [LoadAction] = [
        .refreshNow, .screenAppeared, .screenDisappeared, .cancelStop, .dismissNotice, .cancelBackground, .reloadJournal,
        .confirmStop(planID: planID), .confirmBackground(planID: planID), .setBackgroundTabOpen(true),
        .requestAgent(label: "com.vendor.helper", verb: .disable), .requestBot(id: "shopbot", verb: .restart),
        .requestStop(.process(id(900001))), .requestStop(.group("app:Chrome")), .requestStop(.session(id(900002))),
        .requestStop(.sessionChild(session: id(900002), child: id(900004))), .requestStop(.shell(id(900010))),
        .requestStop(.shellChild(shell: id(900010), child: id(900001))), .requestStop(.orphan(id(900005))),
    ]
    var longest = 0
    for action in actions {
        let data = encoded(action)
        longest = max(longest, data.count)
        let back = try? JSONDecoder().decode(LoadAction.self, from: data)
        check(back == action && back.map(encoded) == data, "действие через JSON: \(String(decoding: data, as: UTF8.self))")
    }
    print("     самое длинное действие \(longest) байт")
    let garbage = [
        #"{"confirmStop":{"planID":"not-a-uuid"}}"#, #"{"confirmStop":{}}"#, #"{"confirmStop":{"_0":{"targets":[{"pid":1}]}}}"#,
        #"{"requestStop":{"_0":{"pids":{"_0":[1,2]}}}}"#, #"{"requestStop":{"_0":{"process":{"_0":1234}}}}"#, #"{"requestStop":{"_0":{"process":{"_0":{"pid":1}}}}}"#,
        #"{"requestBot":{"id":"x","verb":"rm"}}"#, #"{"requestAgent":{"label":"x","verb":"bootout"}}"#, #"{"runCommand":{"argv":["/bin/rm"]}}"#, #"{"stop":{"plan":{"targets":[]}}}"#, "{}", "[]",
    ]
    for raw in garbage {
        check((try? JSONDecoder().decode(LoadAction.self, from: Data(raw.utf8))) == nil, "разбор отказал: \(raw)")
    }
    // Лишние поля отсекает сам разбор (LinkActionFields), а не только сверка байтов.
    let extra = Data(#"{"confirmStop":{"pids":[1,2],"planID":"\#(planID.uuidString)"}}"#.utf8)
    check((try? JSONDecoder().decode(LoadAction.self, from: extra)) == nil, "план с лишними pid: разбор отказал")
    let twoKeys = Data(#"{"refreshNow":{},"cancelStop":{}}"#.utf8)
    check((try? JSONDecoder().decode(LoadAction.self, from: twoKeys)) == nil, "два действия в одном: разбор отказал")
    let nestedExtra = Data(#"{"requestStop":{"_0":{"group":{"_0":"x","argv":["/bin/rm"]}}}}"#.utf8)
    check((try? JSONDecoder().decode(LoadAction.self, from: nestedExtra)) == nil, "цель с лишним argv: разбор отказал")
    func replyError(_ raw: Data) -> String? {
        (try? JSONDecoder().decode(LinkReply<LoadState>.self, from: store.handle(raw)))?.error
    }
    check(replyError(extra) == "Непонятная команда", "через связь: лишние поля — «Непонятная команда»")
    check(replyError(Data(repeating: 0x20, count: LoadStore.maxActionBytes + 1)) == "Непонятная команда", "через связь: слишком длинное — «Непонятная команда»")
    check(replyError(encoded(LoadAction.dismissNotice)) == nil, "через связь: настоящее действие принято")

    // MARK: Отказы
    func refuse(_ action: LoadAction, _ name: String, expect: String? = nil) {
        let before = encoded(store.wireState)
        let stops = engine.executed.count, bots = runner.plans.count
        let error = store.handle(action)
        check(error != nil && (expect == nil || error == expect), "\(name): отказ «\(error ?? "нет отказа")»")
        check(encoded(store.wireState) == before && engine.executed.count == stops && runner.plans.count == bots, "\(name): состояние то же, ничего не выполнено")
    }
    let long = String(repeating: "x", count: LoadStore.maxIDBytes + 1)
    refuse(.requestStop(.process(LoadRowID(pid: 900001, uniqueID: 0))), "голый pid")
    refuse(.requestStop(.process(LoadRowID(pid: 900001, uniqueID: 1))), "pid с чужим uniqueID")
    refuse(.requestStop(.process(id(1))), "pid 1")
    refuse(.requestStop(.process(LoadRowID(pid: 500, uniqueID: 7_000_500))), "pid, которого нет на экране")
    refuse(.requestStop(.process(id(900008))), "строка без кнопки (WindowServer)")
    refuse(.requestStop(.group("project:нет")), "неизвестная группа")
    refuse(.requestStop(.group("system")), "группа без кнопки")
    refuse(.requestStop(.group(long)), "длинный id группы", expect: "Непонятная команда")
    refuse(.requestStop(.session(id(900013))), "текущая сессия")
    refuse(.requestStop(.session(id(900016))), "сессия под управлением приложения")
    refuse(.requestStop(.session(id(900001))), "процесс не сессия")
    refuse(.requestStop(.sessionChild(session: id(900002), child: id(900003))), "потомок без кнопки")
    refuse(.requestStop(.sessionChild(session: id(900013), child: id(900004))), "потомок чужой сессии")
    refuse(.requestStop(.shell(id(900015))), "шелл без кнопки")
    refuse(.requestStop(.shellChild(shell: id(900015), child: id(900001))), "потомок чужого шелла")
    refuse(.requestStop(.orphan(id(900014))), "сирота без кнопки")
    refuse(.requestStop(.orphan(id(900001))), "процесс не сирота")
    // Сверка с экраном отказывает сама, не полагаясь на план ниже по цепочке.
    if let shown = store.measure {
        check(!shown.offers(.session(id(900013)))
              && !shown.offers(.process(id(900008))), "сверка с экраном: текущая сессия и строка без кнопки не предлагаются")
        check(shown.offers(.process(id(900001))) && shown.offers(.session(id(900002))), "сверка с экраном: обычные строки предлагаются")
    } else {
        check(false, "у модели есть замер")
    }
    refuse(.confirmStop(planID: UUID()), "подтверждение без плана")
    refuse(.confirmBackground(planID: UUID()), "подтверждение фонового без плана")
    refuse(.requestAgent(label: "com.other.agent", verb: .stop), "чужая метка агента")
    refuse(.requestAgent(label: "com.vendor.helper", verb: .enable), "кнопки «Вернуть» у агента нет")
    refuse(.requestAgent(label: "com.vendor.daemon", verb: .stop), "системный агент без кнопок")
    refuse(.requestAgent(label: long, verb: .stop), "длинная метка", expect: "Непонятная команда")
    refuse(.requestBot(id: "other", verb: .stop), "чужой бот")
    refuse(.requestBot(id: "shopbot", verb: .start), "кнопки «Включить» у бота нет")
    refuse(.requestBot(id: "newbot", verb: .start), "ненастроенный бот")
    refuse(.requestBot(id: long, verb: .stop), "длинный id бота", expect: "Непонятная команда")

    // Строка на экране есть, а процесс уже другой или под защитой: свежий замер решает, тихо, без публикации.
    var changed = engine.snapshot
    let old = changed.procs[900001]!
    changed.procs[900001] = LoadProcess(pid: old.pid, ppid: old.ppid, user: old.user, uniqueID: 99, startTime: old.startTime, name: old.name, exe: old.exe, exeName: old.exeName,
                                        isClaude: old.isClaude, terminal: old.terminal, cwd: old.cwd, args: old.args, tty: old.tty, memMB: old.memMB, residentMB: old.residentMB,
                                        wiredMB: old.wiredMB, compressedMB: old.compressedMB, readable: old.readable, pgid: old.pgid, tpgid: old.tpgid, cpuPercent: old.cpuPercent)
    store.apply(changed)
    refuse(.requestStop(.process(id(900001))), "pid занят другим процессом", expect: "Процесс сменился — обнови экран")
    var fenced = engine.snapshot
    fenced.fence[900001] = "бот"
    store.apply(fenced)
    refuse(.requestStop(.process(id(900001))), "процесс под защитой к моменту просьбы", expect: "Это остановить нельзя")
    store.apply(engine.snapshot)

    // MARK: Просьба и подтверждение
    let targets: [(String, LoadStopTarget, String)] = [
        ("процесс", .process(id(900001)), "Остановить node"),
        ("подсказка: сессия как процесс", .process(id(900002)), "Остановить claude"),
        ("группа", .group("app:Chrome"), "Остановить группу «Chrome»"),
        ("сессия", .session(id(900002)), "Остановить сессию shop-b9"),
        ("потомок сессии", .sessionChild(session: id(900002), child: id(900004)), "Остановить node webpack serve"),
        ("шелл", .shell(id(900010)), "Закрыть шелл ttys001 (shop)"),
        ("потомок шелла", .shellChild(shell: id(900010), child: id(900001)), "Остановить node vite --port 5173"),
        ("сирота", .orphan(id(900005)), "Остановить python3 worker.py"),
    ]
    for (name, target, title) in targets {
        check(store.handle(.requestStop(target)) == nil, "\(name): просьба принята")
        check(store.wireState.stopPrompt?.title == title, "\(name): заголовок «\(store.wireState.stopPrompt?.title ?? "нет")»")
        check(store.handle(.cancelStop) == nil && store.stopPrompt == nil, "\(name): отмена")
    }
    check(engine.executed.isEmpty, "просьбы и отмены ничего не выполнили")

    _ = store.handle(.requestStop(.process(id(900001))))
    let plan = store.pendingStop!
    let firstPrompt = store.stopPrompt
    store.apply(engine.snapshot)
    check(store.stopPrompt == firstPrompt, "план не меняется при новом замере")
    refuse(.confirmStop(planID: UUID()), "чужой id плана при открытом подтверждении")
    refuse(.confirmBackground(planID: plan.id), "id плана остановки в подтверждении фонового")
    store.confirmStop(UUID())
    check(!store.stopRunning && engine.executed.isEmpty, "модель с чужим id плана ничего не выполняет")
    check(store.handle(.cancelStop) == nil, "отмена плана")
    refuse(.confirmStop(planID: plan.id), "id отменённого плана")

    _ = store.handle(.requestStop(.process(id(900001))))
    let live = store.pendingStop!
    engine.hold = true
    check(store.handle(.confirmStop(planID: live.id)) == nil, "подтверждение своим id принято")
    await until("остановка началась") { engine.executed == [live.id] }
    check(store.stopRunning, "остановка идёт")
    refuse(.confirmStop(planID: live.id), "второе подтверждение того же плана", expect: "Остановка уже идёт")
    refuse(.cancelStop, "отмена во время остановки", expect: "Остановка уже идёт")
    refuse(.requestStop(.process(id(900002))), "новая просьба во время остановки", expect: "Остановка уже идёт")
    engine.hold = false
    await until("остановка кончилась") { !store.stopRunning }
    check(engine.executed == [live.id] && engine.plans.first?.targets.allSatisfy { $0.pid >= 900000 } == true, "исполнитель получил ровно план модуля")
    check(store.stopPrompt == nil && store.notice?.text == "стенд: ничего не остановлено", "после остановки баннер, плана нет")
    refuse(.confirmStop(planID: live.id), "id выполненного плана")
    check(store.handle(.dismissNotice) == nil && store.notice == nil, "баннер закрывается")

    // MARK: Фоновое
    check(store.handle(.requestAgent(label: "com.vendor.helper", verb: .stop)) == nil, "агент: просьба принята")
    check(store.wireState.background.prompt?.title == "Остановить Helper", "агент: подтверждение")
    check(store.handle(.cancelBackground) == nil && store.background.prompt == nil, "агент: отмена")
    check(store.handle(.requestBot(id: "shopbot", verb: .stop)) == nil, "бот: просьба принята")
    let botPrompt = store.background.prompt
    check(botPrompt?.command.contains("stop-bot") == true, "бот: команду показывает модуль, из своего bots.toml")
    refuse(.confirmBackground(planID: UUID()), "чужой id плана бота")
    refuse(.confirmStop(planID: botPrompt!.id), "id плана бота в подтверждении остановки")
    store.background.confirm(UUID())
    check(!store.background.running && runner.plans.isEmpty, "модель с чужим id плана бота ничего не выполняет")
    runner.hold = true
    check(store.handle(.confirmBackground(planID: botPrompt!.id)) == nil, "бот: подтверждение своим id принято")
    await until("команда началась") { runner.plans.count == 1 }
    refuse(.confirmBackground(planID: botPrompt!.id), "второе подтверждение", expect: "Уже выполняется другое действие")
    refuse(.requestAgent(label: "com.vendor.helper", verb: .stop), "просьба во время действия", expect: "Уже выполняется другое действие")
    refuse(.requestBot(id: "shopbot", verb: .restart), "просьба во время действия", expect: "Уже выполняется другое действие")
    refuse(.cancelBackground, "отмена во время действия", expect: "Уже выполняется другое действие")
    runner.hold = false
    await until("команда кончилась") { !store.background.running }
    if case .bot(let verb, let spec)? = runner.plans.first?.action, case .argv(let argv)? = spec.commands[verb] {
        check(verb == .stop && argv == botStop, "исполнитель получил команду модуля")
    } else {
        check(false, "исполнитель получил команду модуля")
    }
    await until("баннер") { store.notice?.text == "стенд: ничего не запущено" }

    // MARK: Служебные
    let refreshes = engine.refreshes
    check(store.handle(.refreshNow) == nil, "обновить")
    await until("замер") { engine.refreshes > refreshes }
    check(store.handle(.setBackgroundTabOpen(true)) == nil && store.handle(.setBackgroundTabOpen(false)) == nil, "вкладка «Фоновое»")
    check(store.handle(.reloadJournal) == nil, "журнал")
    for _ in 0..<LoadStore.maxWatchers { check(store.handle(.screenAppeared) == nil, "экран открыт") }
    refuse(.screenAppeared, "открытий экрана больше предела", expect: "Экран и так открыт")
    for _ in 0..<(LoadStore.maxWatchers + 2) { _ = store.handle(.screenDisappeared) }
    check(store.watchers == 0, "закрытий больше, чем открытий: счётчик не уходит в минус")

    // MARK: Единственный писатель истории
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("load-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("load-history.json")
        let snap = fixtureSnapshot()
        let t = Int(Date().timeIntervalSince1970)
        let first = LoadHistory(url: url), second = LoadHistory(url: url)
        first.record(memory: snap.memory, groups: snap.groups, swapoutsMB: nil, now: t)
        let written = try? Data(contentsOf: url)
        check(written != nil, "первый писатель записал файл")
        second.record(memory: snap.memory, groups: snap.groups, swapoutsMB: nil, now: t + 60)
        check((try? Data(contentsOf: url)) == written, "второй писатель файл не меняет")
        check(second.samples.map(\.ts) == [t], "второй видит записанное первым")
        first.releaseWriter()
        second.record(memory: snap.memory, groups: snap.groups, swapoutsMB: nil, now: t + 120)
        check(second.samples.map(\.ts) == [t, t + 120] && (try? Data(contentsOf: url)) != written, "после отпускания замка пишет второй")
        first.record(memory: snap.memory, groups: snap.groups, swapoutsMB: nil, now: t + 180)
        check(LoadHistory(url: url).samples.map(\.ts) == [t, t + 120], "первый, потерявший замок, файл не меняет")
        second.releaseWriter()
    }

    await botCommandIsTheShownOne(engine)

    check(zip(realFiles, stamps).allSatisfy { realFileStamp($0) == $1 }, "настоящие load-history.json и actions.log не менялись")
}

/// Настоящий исполнитель и настоящий разбор файла, но файл из шва, а команды стенд не запускает: Kit отказывает прямо
/// перед запуском («Стенд не запускает…»). Этот отказ и значит «сверка пройдена, дошло бы до запуска».
@MainActor func botCommandIsTheShownOne(_ engine: FakeEngine) async {
    // Файл шва один на домен настроек, а проверки идут одновременно: у процесса свой. Домен настроек уже выбран раньше.
    _ = Kit.defaults
    setenv("KIT_TEST_SUITE", "local.utilitumus.test.load-wire.\(getpid())", 1)
    let file = BotRegistry.url
    check(file.lastPathComponent.contains(".\(getpid()).") && !file.path.hasPrefix(Kit.realHome + "/"), "файл ботов свой и не в настоящем доме: \(file.path)")
    defer { try? FileManager.default.removeItem(at: file) }
    func put(_ start: String) {
        let text = "[[bot]]\nid = \"filebot\"\nname = \"File bot\"\nproject = \"p\"\nlaunchd = [\"com.stand.filebot\"]\nstart = \(start)\n"
        check(FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]), "файл ботов записан")
    }
    let reached = "Стенд не запускает команды ботов"
    let shownA = #"["/nonexistent/stand-bot-a"]"#, shownB = #"["/nonexistent/stand-bot-b"]"#

    put(shownA)
    let background = BackgroundStore(collect: { s in
        BackgroundData(bots: BotRegistry.load().map { BotRegistry.status($0, procs: s.procs, tree: s.tree, launchd: s.launchd) })
    }, readJournal: { [] })
    let store = LoadStore(engine: engine, background: background)

    /// Как экран в центре: просьба и подтверждение через действия связи, на экране только то, что прислал модуль.
    func ask() -> LoadBackgroundPrompt? {
        check(store.handle(.requestBot(id: "filebot", verb: .start)) == nil, "просьба принята")
        return store.background.prompt
    }
    func confirm(_ prompt: LoadBackgroundPrompt?) async -> LoadNotice? {
        store.dismissNotice()
        guard let prompt, store.handle(.confirmBackground(planID: prompt.id)) == nil else { check(false, "подтверждение принято"); return nil }
        await until("итог действия") { !store.background.running && store.notice != nil }
        return store.notice
    }
    func showing(_ command: BotCommand?) async {
        store.apply(engine.snapshot, force: true)
        await until("список по файлу") { background.data.bots.first?.spec.commands[.start] == command }
    }

    await showing(.argv(["/nonexistent/stand-bot-a"]))
    let same = ask()
    check(same?.command == "/nonexistent/stand-bot-a", "вопрос показывает команду из файла")
    check(await confirm(same)?.text == reached, "файл тот же: сверка пройдена, дошло до запуска")

    await showing(.argv(["/nonexistent/stand-bot-a"]))
    let stale = ask()
    put(shownB)
    let refused = await confirm(stale)
    check(refused?.text == BotRunner.changedMessage && refused?.isError == true, "файл изменили после вопроса: отказ «\(refused?.text ?? "нет")»")

    await showing(.argv(["/nonexistent/stand-bot-b"]))
    let again = ask()
    check(again?.command == "/nonexistent/stand-bot-b", "повторный вопрос показывает новую команду")
    check(await confirm(again)?.text == reached, "новую команду подтвердили: дошло до запуска")

    // В файле была не команда: вопрос её не показал, значит и появившуюся без нового вопроса запускать нельзя.
    put(#""не список строк""#)
    await showing(.invalid)
    let unseen = ask()
    check(unseen?.command == "", "вопрос без команды")
    check(await confirm(unseen)?.text.contains("не список строк") == true, "в файле всё ещё не команда: об этом и сообщение")
    await showing(.invalid)
    let unseenThenSet = ask()
    put(shownA)
    check(await confirm(unseenThenSet)?.text == BotRunner.changedMessage, "команда появилась после вопроса без команды: отказ")

    // Смена направления в файле: вопрос её не показывает и команду не переставляет, а сверка идёт по настоящему argv.
    let sly = "/nonexistent/bot\u{202E}gpj.exe", tricks: [UInt32] = [0x202E, 0x200F, 0x2066, 0x0A, 0x07]
    put(#"["/nonexistent/bot\u202Egpj.exe", "a\u200Fb\u2066c\nd\u0007"]"#)
    await showing(.argv([sly, "a\u{200F}b\u{2066}c\nd\u{7}"]))
    let tricky = ask()
    check(tricky?.command == "'/nonexistent/bot gpj.exe' 'a b c d '", "команда в вопросе читается как есть: \(tricky?.command ?? "нет")")
    for (name, text) in [("command", tricky?.command), ("message", tricky?.message)] {
        check(text?.unicodeScalars.contains { tricks.contains($0.value) } == false, "\(name) без смены направления и управляющих символов")
    }
    check(await confirm(tricky)?.text == reached, "очистка только для показа: настоящий argv прошёл сверку")

    // Имя и пояснение из того же файла попадают в заголовок и текст вопроса.
    let plain = FileManager.default.createFile(atPath: file.path, contents: Data(#"""
    [[bot]]
    id = "filebot"
    name = "File\u202Ebot"
    project = "p"
    note = "note\u202Eover"
    launchd = ["com.stand.filebot"]
    start = ["/nonexistent/stand-bot-a"]

    """#.utf8), attributes: [.posixPermissions: 0o600])
    check(plain, "файл ботов записан")
    await showing(.argv(["/nonexistent/stand-bot-a"]))
    let named = ask()
    check(named?.title == "Включить File bot", "заголовок без смены направления: \(named?.title ?? "нет")")
    check(named?.message.unicodeScalars.contains { tricks.contains($0.value) } == false && named?.message.contains("note over") == true, "пояснение без смены направления")
    check(store.handle(.cancelBackground) == nil, "отмена")

    // Те же имя и пояснение в строке списка.
    var dirty = BotSpec.none
    dirty.name = "Row\u{202E}bot"
    dirty.note = "note\u{202E}over"
    let row = BotRegistry.status(dirty, procs: [:], tree: ProcessTree([:]), launchd: [:])
    check(row.name == "Row bot" && !row.note.unicodeScalars.contains { $0.value == 0x202E }, "строка списка без смены направления: \(row.name)")
}
#endif

// MARK: - Снимки

#if !LOAD_LOGIC_ONLY
@MainActor enum Stand {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -12000, y: 0, width: 900, height: 3000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    static func shot(_ view: some View, name: String, into dir: String, width: CGFloat = 900, height: CGFloat = 3000) async {
        let host = NSHostingView(rootView: view
            .environment(\.pageActive, false)
            .defaultAppStorage(Kit.defaults)
            .frame(width: width, height: height, alignment: .top)
            .background(Color.black)
            .dsThemed())
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView = host
        try? await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        window.contentView = nil
    }

    static func setTab(_ tab: LoadTab, _ mode: LoadViewMode) {
        Kit.defaults.set(tab.rawValue, forKey: "LoadTab")
        Kit.defaults.set(mode.rawValue, forKey: "LoadViewMode")
    }

    /// Все вкладки в обоих видах.
    static func tabs(_ make: () -> some View, into dir: String) async {
        for tab in LoadTab.allCases {
            for mode in LoadViewMode.allCases {
                setTab(tab, mode)
                await shot(make(), name: "tab-\(tab.rawValue)-\(mode.rawValue)", into: dir)
            }
        }
    }

    /// То, что на вкладках раскрывается руками, а значит в снимок всей вкладки не попадает.
    static func parts<Data>(_ s: Data, memory: MemoryTotals, groups: [ProcessGroup], sessions: SessionsData, palette: LoadPalette, into dir: String,
                            section: (GroupKind, Data, Bool) -> AnyView, card: (Data, MemoryPart?, Bool) -> AnyView) async {
        for kind in [GroupKind.project, .app, .system, .other] {
            await shot(section(kind, s, false), name: "groups-\(kind.rawValue)", into: dir, height: 1500)
            await shot(section(kind, s, true), name: "groups-all-\(kind.rawValue)", into: dir, height: 1500)
        }
        for part in MemoryPart.allCases { await shot(card(s, part, false), name: "drill-\(part.rawValue)", into: dir, height: 900) }
        await shot(card(s, nil, true), name: "card-big", into: dir, height: 900)
        await shot(AIDrillPanel(ai: sessions.ai), name: "ai", into: dir, height: 300)
        for session in sessions.claude {
            await shot(SessionCard(session: session, now: fixedNow, expanded: .constant(true), onStop: {}, onStopChild: { _ in }), name: "session-\(session.pid)", into: dir, height: 400)
        }
    }
}

func diffPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow, a.bitsPerPixel == b.bitsPerPixel,
          let pa = a.bitmapData, let pb = b.bitmapData else { return max(a.pixelsWide * a.pixelsHigh, b.pixelsWide * b.pixelsHigh) }
    let size = a.bitsPerPixel / 8
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide where memcmp(pa + y * a.bytesPerRow + x * size, pb + y * a.bytesPerRow + x * size, size) != 0 { count += 1 }
    }
    return count
}

func comparePNG(_ dirA: String, _ dirB: String) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dirA)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    let namesB = ((try? FileManager.default.contentsOfDirectory(atPath: dirB)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    check(!names.isEmpty && names == namesB, "снимков \(names.count) и \(namesB.count)")
    var total = 0, reps: [NSBitmapImageRep] = []
    for name in names {
        guard let a = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(dirA)/\(name)"))) ?? Data()),
              let b = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(dirB)/\(name)"))) ?? Data()) else {
            check(false, "прочитать \(name)")
            continue
        }
        let diff = diffPixels(a, b)
        total += diff
        if diff != 0 { check(false, "\(name): разных пикселей \(diff) из \(a.pixelsWide * a.pixelsHigh)") }
        reps.append(a)
    }
    check(total == 0, "\(names.count) снимков: разных пикселей \(total)")
    let distinct = Set(reps.map { $0.representation(using: .png, properties: [:]) ?? Data() }).count
    check(distinct > names.count - 3, "снимки разные между собой, не пустые: \(distinct) из \(names.count)")
}

#if LOAD_BASELINE
/// Снимки сборки до подготовки: те же данные через старый интерфейс.
@MainActor func renderBaseline(_ dir: String) async {
    let store = LoadStore(engine: LoadEngine(historyURL: nil))
    let snapshot = fixtureSnapshot()
    store.apply(snapshot, force: true)
    while !store.background.hasContent { try? await Task.sleep(for: .milliseconds(20)) }
    store.background.reloadJournal()
    while store.background.journal.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    store.history = fixtureHistory()
    await Stand.tabs({ LoadScreen(store: store) }, into: dir)
    store.notice = LoadNotice(text: "Остановлено 2 процесса", isError: false)
    Stand.setTab(.overview, .simple)
    await Stand.shot(LoadScreen(store: store), name: "notice", into: dir, height: 1400)
    store.notice = nil
    await Stand.parts(snapshot, memory: snapshot.memory, groups: snapshot.groups, sessions: snapshot.sessions, palette: store.palette, into: dir,
                      section: { kind, s, all in
                          AnyView(GroupsSection(kind: kind, groups: s.groups.filter { $0.kind == kind }, snapshot: s, expanded: .constant(Set(s.groups.map(\.id))),
                                                showAll: .constant(all ? Set(s.groups.map(\.id)) : []), fullKinds: .constant([]), onStopProcess: { _ in }, onStopGroup: { _ in }))
                      },
                      card: { s, part, big in AnyView(MemoryCard(snapshot: s, palette: store.palette, mode: .full, big: big, drill: .constant(part), onStop: { _ in })) })
    let d = snapshot.sessions
    let busy = d.claude[0], shell = d.terminals[0].shells[0]
    let requests: [(String, () -> Void)] = [
        ("process", { store.requestStop(process: 900001) }),
        ("group", { store.requestStop(group: "app:Chrome") }),
        ("session", { store.requestStop(session: busy) }),
        ("session-child", { store.requestStop(session: busy, child: busy.children[0]) }),
        ("shell", { store.requestStop(shell: shell) }),
        ("shell-child", { store.requestStop(shell: shell, child: shell.children[0]) }),
        ("orphan", { store.requestStop(orphan: d.orphans[0]) }),
    ]
    for (name, request) in requests {
        request()
        await Stand.shot(StopConfirmSheet(store: store, plan: store.pendingStop!), name: "stop-\(name)", into: dir, height: 700)
        store.pendingStop = nil
    }
    let data = store.background.data
    let plans: [(String, BackgroundPlan)] = [
        ("agent-stop", .agent(data.agents[0], .stop)), ("agent-disable", .agent(data.agents[0], .disable)), ("agent-enable", .agent(data.agents[1], .enable)),
        ("bot-stop", .bot(data.bots[0], .stop)), ("bot-restart", .bot(data.bots[0], .restart)),
    ]
    for (name, plan) in plans {
        await Stand.shot(BackgroundConfirmSheet(background: store.background, plan: plan), name: "bg-\(name)", into: dir, height: 700)
    }
}
#else
/// Лаунчер будет держать такую же: только то, что пришло в состоянии.
@MainActor final class RemoteBackgroundStub: LoadBackgroundModel {
    var state: LoadBackgroundState
    init(_ state: LoadBackgroundState) { self.state = state }
    var data: BackgroundData { state.data }
    var prompt: LoadBackgroundPrompt? { state.prompt }
    var running: Bool { state.running }
    var journal: [ActionLog.Entry] { state.journal }
    func setTabOpen(_ open: Bool) {}
    func reloadJournal() {}
    func request(_ agent: AgentItem, _ verb: AgentVerb) {}
    func request(_ bot: BotItem, _ verb: BotVerb) {}
    func cancel() {}
    func confirm(_ planID: UUID) {}
}

@MainActor final class RemoteStub: LoadModel {
    let state: LoadState
    let background: RemoteBackgroundStub
    let live = LiveStats()
    var palette = LoadPalette()
    init(_ state: LoadState) {
        self.state = state
        background = RemoteBackgroundStub(state.background)
        live.update(from: state.live)
        if let map = state.measure?.map { palette.update(from: map) }
    }
    var measure: LoadMeasure? { state.measure }
    var history: HistoryWindow? { state.history }
    var stopPrompt: LoadStopPrompt? { state.stopPrompt }
    var stopRunning: Bool { state.stopRunning }
    var notice: LoadNotice? { state.notice }
    func refreshNow() {}
    func screenAppeared() {}
    func screenDisappeared() {}
    func requestStop(_ target: LoadStopTarget) {}
    func cancelStop() {}
    func confirmStop(_ planID: UUID) {}
    func dismissNotice() {}
}

func throughWire(_ state: LoadState) -> LoadState { try! JSONDecoder().decode(LoadState.self, from: encoded(state)) }

/// `remote`: экран получает только то, что прошло через JSON. Иначе встроенный экран на настоящем `LoadStore`.
@MainActor func render(_ dir: String, remote: Bool) async {
    let engine = FakeEngine(fixtureSnapshot())
    let store = await makeStore(engine, FakeRunner())
    let id = { (pid: Int32) in LoadRowID(pid: pid, uniqueID: 7_000_000 + UInt64(pid)) }
    func sheetState() -> LoadState { throughWire(store.wireState) }
    if remote {
        let model = RemoteStub(sheetState())
        await Stand.tabs({ LoadScreen(model: model) }, into: dir)
    } else {
        await Stand.tabs({ LoadScreen(store: store) }, into: dir)
    }
    store.notice = LoadNotice(text: "Остановлено 2 процесса", isError: false)
    Stand.setTab(.overview, .simple)
    if remote {
        await Stand.shot(LoadScreen(model: RemoteStub(sheetState())), name: "notice", into: dir, height: 1400)
    } else {
        await Stand.shot(LoadScreen(store: store), name: "notice", into: dir, height: 1400)
    }
    store.notice = nil
    let m = remote ? sheetState().measure! : store.measure!
    let palette = remote ? RemoteStub(sheetState()).palette : store.palette
    await Stand.parts(m, memory: m.memory, groups: m.groups, sessions: m.sessions, palette: palette, into: dir,
                      section: { kind, s, all in
                          AnyView(GroupsSection(kind: kind, groups: s.groups.filter { $0.kind == kind }, snapshot: s, expanded: .constant(Set(s.groups.map(\.id))),
                                                showAll: .constant(all ? Set(s.groups.map(\.id)) : []), fullKinds: .constant([]), onStopProcess: { _ in }, onStopGroup: { _ in }))
                      },
                      card: { s, part, big in AnyView(MemoryCard(snapshot: s, palette: palette, mode: .full, big: big, drill: .constant(part), onStop: { _ in })) })
    let targets: [(String, LoadStopTarget)] = [
        ("process", .process(id(900001))), ("group", .group("app:Chrome")), ("session", .session(id(900002))),
        ("session-child", .sessionChild(session: id(900002), child: id(900004))), ("shell", .shell(id(900010))),
        ("shell-child", .shellChild(shell: id(900010), child: id(900001))), ("orphan", .orphan(id(900005))),
    ]
    for (name, target) in targets {
        store.requestStop(target)
        if remote {
            let model = RemoteStub(sheetState())
            await Stand.shot(StopConfirmSheet(store: model, plan: model.stopPrompt!), name: "stop-\(name)", into: dir, height: 700)
        } else {
            await Stand.shot(StopConfirmSheet(store: store, plan: store.stopPrompt!), name: "stop-\(name)", into: dir, height: 700)
        }
        store.cancelStop()
    }
    let data = store.background.data
    let plans: [(String, () -> Void)] = [
        ("agent-stop", { store.background.request(data.agents[0], .stop) }), ("agent-disable", { store.background.request(data.agents[0], .disable) }),
        ("agent-enable", { store.background.request(data.agents[1], .enable) }),
        ("bot-stop", { store.background.request(data.bots[0], .stop) }), ("bot-restart", { store.background.request(data.bots[0], .restart) }),
    ]
    for (name, request) in plans {
        request()
        if remote {
            let model = RemoteStub(sheetState())
            await Stand.shot(BackgroundConfirmSheet(background: model.background, plan: model.background.prompt!), name: "bg-\(name)", into: dir, height: 700)
        } else {
            await Stand.shot(BackgroundConfirmSheet(background: store.background, plan: store.background.prompt!), name: "bg-\(name)", into: dir, height: 700)
        }
        store.background.cancel()
    }
    check(engine.executed.isEmpty, "снимки ничего не выполнили")
}

// MARK: - Замер настоящего состояния

/// Настоящий движок на этом Mac: только чтение процессов и launchctl list. История — копия файла, настоящий не пишется.
@MainActor func measureReal(history: String) async {
    let realFiles = [LoadHistory.realURL, ActionLog.file]
    let stamps = realFiles.map(realFileStamp)
    let engine = LoadEngine(historyURL: URL(fileURLWithPath: history))
    let store = LoadStore(engine: engine)
    store.start()
    while store.history == nil { try? await Task.sleep(for: .milliseconds(50)) }
    store.stop()
    store.apply(await engine.measure(), force: true)
    try? await Task.sleep(for: .seconds(3))
    let snapshot = await engine.refreshNow()
    store.apply(snapshot, force: true)
    while store.background.data.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
    store.background.reloadJournal()
    try? await Task.sleep(for: .seconds(1))

    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    func clock(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    var state = store.wireState
    let m = state.measure!
    let build = median((0..<9).map { _ in clock { _ = store.wireState } })
    state = store.wireState
    let json = encoded(state)
    let enc = median((0..<9).map { _ in clock { _ = encoded(state) } })
    var decoded: LoadState?
    let dec = median((0..<9).map { _ in clock { decoded = try? JSONDecoder().decode(LoadState.self, from: json) } })
    check(!json.isEmpty && decoded == state, "настоящее состояние через JSON равно исходному")
    print("процессов \(snapshot.procs.count), групп \(m.groups.count), участников \(m.groups.reduce(0) { $0 + $1.members.count }), сессий \(m.sessions.claude.count), агентов \(state.background.data.agents.count), ботов \(state.background.data.bots.count), журнал \(state.background.journal.count)")
    print(String(format: "JSON %d байт (%.1f КБ); wireState %.2f мс, кодирование %.2f мс, разбор %.2f мс (медиана из 9, главный поток)", json.count, Double(json.count) / 1024, build, enc, dec))
    let parts: [(String, Int)] = [
        ("measure", encoded(m).count), ("groups", encoded(m.groups).count), ("map", encoded(m.map).count), ("advice", encoded(m.advice).count), ("sessions", encoded(m.sessions).count),
        ("history", encoded(state.history).count), ("background", encoded(state.background).count), ("live", encoded(state.live).count),
    ]
    print("по частям, байт: " + parts.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    let labels = clock { for p in snapshot.procs.values { _ = Kinds.label(p); _ = Kinds.rowNote(p) } }
    print(String(format: "подписи всех процессов в замере: %.2f мс; сам замер %.0f мс", labels, snapshot.measureMillis))
    check(zip(realFiles, stamps).allSatisfy { realFileStamp($0) == $1 }, "настоящие load-history.json и actions.log не менялись")
}
#endif
#endif

// MARK: - Вход

@main
struct LoadWireCheck {
    static func main() {
        let args = CommandLine.arguments
        let role = args.count > 1 ? args[1] : "logic"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            switch role {
            #if LOAD_BASELINE
            case "render": await renderBaseline(args[2])
            #else
            case "logic": await logic()
            #if !LOAD_LOGIC_ONLY
            case "render": await render(args[2], remote: false)
            case "render-remote": await render(args[2], remote: true)
            case "diff": comparePNG(args[2], args[3])
            case "measure": await measureReal(history: args[2])
            #endif
            #endif
            default:
                print("неизвестная роль \(role)")
                failures += 1
            }
            print(failures == 0 ? "LoadWireCheck: всё верно" : "LoadWireCheck: провалов \(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
