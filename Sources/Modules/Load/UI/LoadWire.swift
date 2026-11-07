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

    /// Ровно одна известная цель и ровно её поля.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "process": self = .process(try wire.value())
        case "group": self = .group(try wire.value())
        case "session": self = .session(try wire.value())
        case "sessionChild":
            try wire.fields("session", "child")
            self = .sessionChild(session: try wire.field("session"), child: try wire.field("child"))
        case "shell": self = .shell(try wire.value())
        case "shellChild":
            try wire.fields("shell", "child")
            self = .shellChild(shell: try wire.field("shell"), child: try wire.field("child"))
        case "orphan": self = .orphan(try wire.value())
        default: throw wire.refuse()
        }
    }

    /// Процессы цели: каждый должен быть всё тем же процессом, что и в выданной строке.
    var rows: [LoadRowID] {
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

    /// Ровно одно известное действие и ровно его поля: синтезированный разбор чужих ключей не видит.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "refreshNow": try wire.none(); self = .refreshNow
        case "screenAppeared": try wire.none(); self = .screenAppeared
        case "screenDisappeared": try wire.none(); self = .screenDisappeared
        case "cancelStop": try wire.none(); self = .cancelStop
        case "dismissNotice": try wire.none(); self = .dismissNotice
        case "cancelBackground": try wire.none(); self = .cancelBackground
        case "reloadJournal": try wire.none(); self = .reloadJournal
        case "requestStop": self = .requestStop(try wire.value())
        case "confirmStop":
            try wire.fields("planID")
            self = .confirmStop(planID: try wire.field("planID"))
        case "confirmBackground":
            try wire.fields("planID")
            self = .confirmBackground(planID: try wire.field("planID"))
        case "setBackgroundTabOpen": self = .setBackgroundTabOpen(try wire.value())
        case "requestAgent":
            try wire.fields("label", "verb")
            self = .requestAgent(label: try wire.field("label"), verb: try wire.field("verb"))
        case "requestBot":
            try wire.fields("id", "verb")
            self = .requestBot(id: try wire.field("id"), verb: try wire.field("verb"))
        default: throw wire.refuse()
        }
    }
}

extension LoadMeasure {
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
