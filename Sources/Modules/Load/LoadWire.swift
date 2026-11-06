import Foundation

/// Данные замера, которые показывает экран. Процессы, дерево и защита остаются в модуле: планы остановки строит он.
struct LoadMeasure: Codable, Equatable {
    var timestamp: Date
    var host: HostInfo
    var memory: MemoryTotals
    var groups: [ProcessGroup]
    var map: MemoryMap
    var advice: [AdviceItem]
    var sessions: SessionsData
    var disk: DiskCard
}

/// Подвал экрана: своя память и CPU, длительность замера.
struct LoadLive: Codable, Equatable {
    var measureMillis: Double
    var selfMemMB: Double
    var selfCPU: Double?
}

/// Подтверждение остановки: только текст и строки. Что и как останавливать, знает план в модуле.
struct LoadStopPrompt: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var message: String
    var targets: [AgentTarget]
    var kept: [StopPlan.Kept]
    var totalMB: Double
}

/// Подтверждение действия над агентом или ботом. `command` — только подпись, обратно не принимается.
struct LoadBackgroundPrompt: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var message: String
    var command: String
    var targets: [AgentTarget]
    var totalMB: Double
    var confirmTitle: String
    var destructive: Bool
}

/// Вкладка «Фоновое».
struct LoadBackgroundState: Codable, Equatable {
    var data: BackgroundData
    var prompt: LoadBackgroundPrompt?
    var running: Bool
    var journal: [ActionLog.Entry]
}

/// То, что экран «Нагрузка» показывает. Цвета программ лаунчер считает сам по `measure.map`.
struct LoadState: Codable, Equatable {
    var measure: LoadMeasure?
    var live: LoadLive
    var history: HistoryWindow?
    var stopPrompt: LoadStopPrompt?
    var stopRunning: Bool
    var notice: LoadNotice?
    var background: LoadBackgroundState
}

/// Что можно попросить остановить: только строки, которые выдал сам модуль.
enum LoadStopTarget: Codable, Equatable {
    case process(LoadRowID)
    case group(String)
    case session(LoadRowID)
    case sessionChild(session: LoadRowID, child: LoadRowID)
    case shell(LoadRowID)
    case shellChild(shell: LoadRowID, child: LoadRowID)
    case orphan(LoadRowID)

    /// Процессы цели: каждый должен быть всё тем же процессом, что и в выданной строке.
    fileprivate var rows: [LoadRowID] {
        switch self {
        case .process(let id), .session(let id), .shell(let id), .orphan(let id): return [id]
        case .sessionChild(let owner, let child), .shellChild(let owner, let child): return [owner, child]
        case .group: return []
        }
    }
}

/// Что вкладка центра может попросить. Планов, pid-списков и команд здесь нет: подтверждение называет только
/// id плана, который лежит в модуле.
enum LoadAction: Codable, Equatable {
    case refreshNow
    case screenAppeared
    case screenDisappeared
    case requestStop(LoadStopTarget)
    case cancelStop
    case confirmStop(planID: UUID)
    case dismissNotice
    case requestAgent(label: String, verb: AgentVerb)
    case requestBot(id: String, verb: BotVerb)
    case cancelBackground
    case confirmBackground(planID: UUID)
    case setBackgroundTabOpen(Bool)
    case reloadJournal
}

extension LoadMeasure {
    init(_ s: LoadSnapshot) {
        self.init(timestamp: s.timestamp, host: s.host, memory: s.memory, groups: s.groups, map: s.map,
                  advice: s.advice, sessions: s.sessions, disk: s.disk)
    }

    /// Без полей, которые в связь не идут: так состояние после разбора равно исходному.
    var forWire: LoadMeasure {
        var m = self
        for g in m.groups.indices {
            for i in m.groups[g].members.indices { m.groups[g].members[i].why = "" }
        }
        for i in m.sessions.claude.indices { m.sessions.claude[i].activity.lastPromptTS = nil }
        for h in m.sessions.terminals.indices {
            for s in m.sessions.terminals[h].shells.indices { m.sessions.terminals[h].shells[s].sessions = [] }
        }
        for i in m.sessions.tmux.sessions.indices { m.sessions.tmux.sessions[i].windows = 0 }
        for i in m.sessions.docker.containers.indices {
            m.sessions.docker.containers[i].id = ""
            m.sessions.docker.containers[i].image = ""
        }
        m.disk.swapWrittenGBSinceBoot = 0
        return m
    }

    /// Есть ли на экране кнопка для этой цели: те же условия, что у кнопок.
    func offers(_ target: LoadStopTarget) -> Bool {
        func stoppable(_ kids: [SessionChild], _ id: LoadRowID) -> Bool {
            kids.contains { $0.rowID == id && $0.stoppable }
        }
        let shells = sessions.terminals.flatMap(\.shells)
        switch target {
        case .process(let id):
            return advice.contains { $0.stopID == id }
                || map.compressedBreakdown.contains { $0.rowID == id && $0.stoppable }
                || groups.contains { $0.members.contains { $0.rowID == id && $0.stoppable } }
        case .group(let id):
            return map.freeCandidates.contains { $0.stoppableGroup == id }
                || groups.contains { $0.id == id && ($0.kind == .project || $0.kind == .app) && $0.stoppableMB > 0 }
        case .session(let id):
            return sessions.claude.contains { $0.rowID == id && $0.stoppable && !$0.isSelf }
        case .sessionChild(let owner, let child):
            return sessions.claude.contains { $0.rowID == owner && stoppable($0.children, child) }
        case .shell(let id):
            return shells.contains { $0.rowID == id && $0.stoppable }
        case .shellChild(let owner, let child):
            return shells.contains { $0.rowID == owner && stoppable($0.children, child) }
        case .orphan(let id):
            return sessions.orphans.contains { $0.rowID == id } && sessions.stoppableOrphans.contains(id.pid)
        }
    }
}

extension BackgroundStore {
    var wireState: LoadBackgroundState {
        // Без полей, которые в связь не идут: так состояние после разбора равно исходному.
        var d = data
        for i in d.agents.indices { d.agents[i].targets = []; d.agents[i].loaded = false }
        for i in d.bots.indices { d.bots[i].spec = .none }
        var j = journal
        for i in j.indices { j[i].kind = ""; j[i].label = "" }
        return LoadBackgroundState(data: d, prompt: prompt, running: running, journal: j)
    }

    /// Просьба из связи: только агент и кнопка, которые модуль сам показал.
    fileprivate func handleRequest(label: String, verb: AgentVerb) -> String? {
        guard label.utf8.count <= LoadStore.maxIDBytes else { return "Непонятная команда" }
        guard !running else { return "Уже выполняется другое действие" }
        guard let agent = data.agents.first(where: { $0.label == label }), agent.verbs.contains(verb) else {
            return "Такого действия на экране уже нет — обнови экран"
        }
        request(agent, verb)
        return nil
    }

    fileprivate func handleRequest(id: String, verb: BotVerb) -> String? {
        guard id.utf8.count <= LoadStore.maxIDBytes else { return "Непонятная команда" }
        guard !running else { return "Уже выполняется другое действие" }
        guard let bot = data.bots.first(where: { $0.id == id }), bot.actions.contains(verb) else {
            return "Такого действия на экране уже нет — обнови экран"
        }
        request(bot, verb)
        return nil
    }

    fileprivate func handleCancel() -> String? {
        guard !running else { return "Уже выполняется другое действие" }
        cancel()
        return nil
    }

    fileprivate func handleConfirm(_ planID: UUID) -> String? {
        guard !running else { return "Уже выполняется другое действие" }
        guard pending?.id == planID else { return "Подтверждение устарело — попробуй ещё раз" }
        confirm(planID)
        return nil
    }
}

extension LoadStore {
    /// Длиннее настоящих меток launchd и id групп и ботов.
    static let maxIDBytes = 1024
    /// Экран открыт один; с запасом на вкладку, открытую ещё раз до закрытия прошлой.
    static let maxWatchers = 4

    var wireState: LoadState {
        LoadState(measure: measure?.forWire,
                  live: LoadLive(measureMillis: live.measureMillis, selfMemMB: live.selfMemMB, selfCPU: live.selfCPU),
                  history: history, stopPrompt: stopPrompt, stopRunning: stopRunning, notice: notice,
                  background: background.wireState)
    }

    /// Действие из связи: сначала проверка, изменения только после неё. Возвращает текст, если действие не выполнено.
    func handle(_ action: LoadAction) -> String? {
        switch action {
        case .refreshNow:
            refreshNow()
        case .screenAppeared:
            guard watchers < Self.maxWatchers else { return "Экран и так открыт" }
            screenAppeared()
        case .screenDisappeared:
            screenDisappeared()
        case .requestStop(let target):
            return handleRequestStop(target)
        case .cancelStop:
            guard !stopRunning else { return "Остановка уже идёт" }
            cancelStop()
        case .confirmStop(let planID):
            guard !stopRunning else { return "Остановка уже идёт" }
            guard pendingStop?.id == planID else { return "Подтверждение устарело — попробуй ещё раз" }
            confirmStop(planID)
        case .dismissNotice:
            dismissNotice()
        case .requestAgent(let label, let verb):
            return background.handleRequest(label: label, verb: verb)
        case .requestBot(let id, let verb):
            return background.handleRequest(id: id, verb: verb)
        case .cancelBackground:
            return background.handleCancel()
        case .confirmBackground(let planID):
            return background.handleConfirm(planID)
        case .setBackgroundTabOpen(let open):
            background.setTabOpen(open)
        case .reloadJournal:
            background.reloadJournal()
        }
        return nil
    }

    /// Цель должна быть на экране и быть тем же процессом; план строит только модуль, по своему замеру.
    private func handleRequestStop(_ target: LoadStopTarget) -> String? {
        guard !stopRunning else { return "Остановка уже идёт" }
        if case .group(let id) = target, id.utf8.count > Self.maxIDBytes { return "Непонятная команда" }
        guard let shown = measure, shown.offers(target) else { return "Этой строки на экране уже нет — обнови экран" }
        guard target.rows.allSatisfy({ latest?.procs[$0.pid]?.uniqueID == $0.uniqueID }) else {
            return "Процесс сменился — обнови экран"
        }
        guard let plan = stopPlan(for: target) else { return "Это остановить нельзя" }
        pendingStop = plan
        return nil
    }
}
