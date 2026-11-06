import Foundation

enum SessionStatus: String, Sendable, Codable {
    case idle, busy, shell, unknown

    /// Слово для экрана. `shell` — сессия выполняет команду: для человека это та же работа.
    var title: String {
        switch self {
        case .busy: return "работает"
        case .idle: return "ждёт"
        case .shell: return "выполняет команду"
        case .unknown: return "неизвестно"
        }
    }

    /// Сессия сейчас что-то делает: «Сейчас:» вместо «Последнее:».
    var isWorking: Bool { self == .busy || self == .shell }
}

/// Потомок сессии или шелла: dev-сервер, MCP, шелл, прочее.
struct SessionChild: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var name: String
    var kind: ProcessKind
    var memMB: Double?
    var age: Double
    /// Можно показать кнопку «Остановить» (dev-сервер или от 500 MB, и процесс не под защитой).
    var stoppable: Bool
    /// Где запущен, если не там же, где его хозяин (сессия или шелл).
    var place: ProcessPlace?
    var uniqueID: UInt64 = 0
    var id: Int32 { pid }
    var rowID: LoadRowID { LoadRowID(pid: pid, uniqueID: uniqueID) }

    /// Dev-сервер или от 500 MB: на такие смотрим в первую очередь.
    var isHot: Bool { kind == .devServer || (memMB ?? 0) >= SessionsBuilder.heavyMB }
}

/// Живая сессия Claude Code.
struct ClaudeSession: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var sessionID: String?
    var name: String
    var project: String?
    var cwd: String
    var status: SessionStatus
    var startedAt: TimeInterval
    var lastActivity: TimeInterval
    var activity: SessionActivity
    /// Память сессии вместе со всеми потомками.
    var memMB: Double
    var version: String
    /// Потомки по убыванию памяти.
    var children: [SessionChild]
    var resumeCommand: String
    var hostApp: String?
    /// Панель запущена из этой сессии (она — предок панели).
    var isSelf: Bool
    var stoppable: Bool
    var uniqueID: UInt64 = 0
    var id: Int32 { pid }
    var rowID: LoadRowID { LoadRowID(pid: pid, uniqueID: uniqueID) }

    var kidsMB: Double { children.reduce(0) { $0 + ($1.memMB ?? 0) } }
}

struct TerminalShell: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var tty: String?
    var cwd: String?
    var project: String?
    /// Процесс на переднем плане, если это не сам шелл.
    var foreground: String
    var children: [SessionChild]
    /// Сессии Claude, запущенные в этом шелле: закрытие шелла завершит и их.
    var sessions: [ClaudeSession] = []
    var stoppable: Bool
    var uniqueID: UInt64 = 0
    var id: Int32 { pid }
    var rowID: LoadRowID { LoadRowID(pid: pid, uniqueID: uniqueID) }

    /// `sessions` нужен только тексту подтверждения, его строит модуль; на экране сессии уже есть в своей секции.
    private enum CodingKeys: String, CodingKey { case pid, tty, cwd, project, foreground, children, stoppable, uniqueID }
}

struct TerminalHost: Sendable, Codable, Equatable, Identifiable {
    var app: String
    var hostPid: Int32
    var shells: [TerminalShell]
    var id: Int32 { hostPid }
}

/// Сколько памяти держит ИИ: каждый процесс — в одной части.
struct AIMemory: Sendable, Codable, Equatable {
    struct Part: Sendable, Codable, Equatable, Identifiable {
        var label: String
        var memMB: Double
        var count: Int
        var id: String { label }
    }

    var parts: [Part] = []
    var totalMB: Double { parts.reduce(0) { $0 + $1.memMB.rounded() } }
    var count: Int { parts.reduce(0) { $0 + $1.count } }
}

/// Всё, что экрану «Сессии», карточке «ИИ» и подсказкам нужно знать о сессиях, — один раз за замер.
struct SessionsData: Sendable, Codable, Equatable {
    var claude: [ClaudeSession] = []
    var terminals: [TerminalHost] = []
    var tmux = TmuxInfo()
    var docker = DockerInfo()
    var orphans: [Advice.Orphan] = []
    /// Сироты, которых можно остановить (pid).
    var stoppableOrphans: Set<Int32> = []
    var ai = AIMemory()

    static let empty = SessionsData()

    /// Порядок множества от запуска к запуску разный, а байты состояния должны совпадать.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claude, forKey: .claude)
        try c.encode(terminals, forKey: .terminals)
        try c.encode(tmux, forKey: .tmux)
        try c.encode(docker, forKey: .docker)
        try c.encode(orphans, forKey: .orphans)
        try c.encode(stoppableOrphans.sorted(), forKey: .stoppableOrphans)
        try c.encode(ai, forKey: .ai)
    }
}
