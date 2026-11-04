import Foundation

/// Один готовый замер: всё, что нужно экрану. Структура неизменяемая и `Sendable`, поэтому
/// безопасно уходит с фонового потока в главный.
struct LoadSnapshot: Sendable {
    var timestamp: Date
    var host: HostInfo
    var memory: MemoryTotals
    /// Все процессы мака. Этап 2 (сессии Claude, агенты launchd) строит свои списки поверх них.
    var procs: [Int32: LoadProcess]
    var tree: ProcessTree
    /// pid → группа.
    var assigned: [Int32: Assignment]
    var groups: [ProcessGroup]
    var map: MemoryMap
    var advice: [AdviceItem]
    /// Сессии Claude, терминалы, tmux/Docker, сироты, память ИИ. В лёгком замере пусто.
    var sessions: SessionsData
    var disk: DiskCard
    /// pid → почему не трогаем.
    var fence: [Int32: String]
    var launchd: [String: Int32?]
    var roots: [String]
    var selfPid: Int32
    var selfMemMB: Double
    var selfCPU: Double?
    /// Сколько занял сам замер, мс.
    var measureMillis: Double

    func process(_ pid: Int32) -> LoadProcess? { procs[pid] }

    func group(_ id: String) -> ProcessGroup? { groups.first { $0.id == id } }

    /// Кнопка «Остановить» для процесса: план или nil, если трогать нельзя.
    func stopPlan(process pid: Int32) -> StopPlan? {
        StopPlanner(procs: procs, fence: fence, tree: tree).plan(process: pid)
    }

    func stopPlan(group id: String) -> StopPlan? {
        guard let g = group(id) else { return nil }
        return StopPlanner(procs: procs, fence: fence, tree: tree).plan(group: g)
    }
}

/// Сбор данных: скан процессов, память системы, группы, карта памяти, подсказки, история.
/// Актор — вся тяжёлая работа вне главного потока, замеры идут строго по одному.
actor LoadEngine {
    private let scanner = ProcessScanner()
    private let attribution = Attribution()
    private let rootMemory = RootMemory()
    private let launchd = LaunchdJobs()
    private let ollama = OllamaProbe()
    private let disk = DiskMonitor()
    private let roots = ProjectRoots()
    private let sessionsBuilder = SessionsBuilder()
    private let history: LoadHistory
    private var lastRecorded = Date.distantPast

    init(historyURL: URL? = LoadHistory.defaultURL) {
        history = LoadHistory(url: historyURL)
        roots.loadExtraInBackground()
    }

    /// Один проход замера. `light` — без карты памяти и подсказок (для истории).
    func measure(light: Bool = false) -> LoadSnapshot {
        let started = DispatchTime.now().uptimeNanoseconds
        rootMemory.refreshIfStale()
        launchd.refreshIfStale()

        let top = rootMemory.current()
        let procs = scanner.scan(rootMemory: top.memory, compressed: top.compressed)
        let tree = ProcessTree(procs)
        let memory = SystemMemory.read()
        let rootList = roots.current
        let assigned = attribution.assign(procs, tree: tree, roots: rootList)
        // Процессы ботов из bots.toml трогают только их кнопки.
        let botFence = BotRegistry.fence(BotRegistry.load(), procs: procs, tree: tree, launchd: launchd.current())
        let fence = Protection.fence(procs: procs, tree: tree, extra: botFence)
        let planner = StopPlanner(procs: procs, fence: fence, tree: tree)

        var groups = Grouping.groups(procs: procs, assigned: assigned, stoppable: planner.canStop)
        var map = MemoryMap()
        var advice: [AdviceItem] = []
        var sessions = SessionsData.empty
        if !light {
            for i in groups.indices where groups[i].id == "system" { groups[i].hints = Grouping.systemHints(procs) }
            map = MemoryMap.build(procs: procs, assigned: assigned, groups: groups, memory: memory, stoppable: planner.canStop)
            let jobs = launchd.current()
            sessionsBuilder.refreshMux()
            sessions = sessionsBuilder.build(SessionsBuilder.Input(
                procs: procs, tree: tree, planner: planner, roots: rootList, launchdPIDs: Set(jobs.values.compactMap { $0 }),
                selfPid: getpid(), now: Date().timeIntervalSince1970))
            advice = Advice.build(Advice.Context(
                procs: procs, tree: tree, planner: planner, memory: memory, map: map,
                swapGrowthMB: history.swapGrowth(), launchdPIDs: Set(jobs.values.compactMap { $0 }),
                ollama: { [ollama] running in ollama.current(processRunning: running) }, roots: rootList,
                now: Date().timeIntervalSince1970, sessions: sessions.claude))
        }
        let me = getpid()
        let snapshot = LoadSnapshot(
            timestamp: Date(), host: SystemMemory.host, memory: memory, procs: procs, tree: tree, assigned: assigned,
            groups: groups, map: map, advice: advice, sessions: sessions, disk: disk.card(swap24: history.swapWrittenLastDay()), fence: fence,
            launchd: launchd.current(), roots: rootList, selfPid: me, selfMemMB: procs[me]?.mem ?? 0,
            selfCPU: procs[me]?.cpuPercent,
            measureMillis: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        return snapshot
    }

    /// Раз в минуту: замер и запись в историю. Возвращает окно для графика.
    func recordHistory() -> HistoryWindow {
        let s = measure(light: true)
        history.record(memory: s.memory, groups: s.groups, swapoutsMB: SystemMemory.swapoutsMB())
        lastRecorded = Date()
        return history.window()
    }

    func historyWindow() -> HistoryWindow { history.window() }

    /// «Обновить»: заодно перечитать `top` (память root-процессов), не дожидаясь пяти минут.
    func refreshNow() -> LoadSnapshot {
        rootMemory.refreshIfStale(maxAge: 0)
        launchd.refreshIfStale(maxAge: 0)
        sessionsBuilder.refreshMux(maxAge: 0)
        return measure()
    }

    /// Остановка по плану: свежий скан, повторная проверка защищённых, SIGTERM → через 5 с SIGKILL.
    func execute(_ plan: StopPlan) -> StopResult {
        let top = rootMemory.current()
        let procs = scanner.scan(rootMemory: top.memory, compressed: top.compressed)
        // Список заданий свежий: pid бота мог смениться после перезапуска, а кэш живёт до минуты.
        let bots = BotRegistry.load()
        var botFence: [Int32: String] = [:]
        if !bots.isEmpty {
            // Без списка заданий не отличить процесс бота от сироты.
            guard let text = Tool.run(Exec.launchctl, ["list"], timeout: 10), !LaunchdJobs.parse(text).isEmpty else {
                return StopResult(ok: false, message: "launchctl не ответил — не могу проверить ботов, повтори позже", freedMB: 0)
            }
            botFence = BotRegistry.fence(bots, procs: procs, tree: ProcessTree(procs), launchd: LaunchdJobs.parse(text))
        }
        let result = StopExecutor.execute(plan, procs: procs, extraFence: botFence)
        ActionLog.record(stop: plan, result: result)
        return result
    }
}
