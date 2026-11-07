import Foundation

// Типы данных, которые показывает экран и передаёт связь. Заполняет их логика модуля.

/// Строка экрана, которую можно остановить: pid вместе с p_uniqueid, как его выдала сама «Нагрузка».
/// В действии из связи принимается, только если такая строка есть на экране и процесс всё ещё тот же.
struct LoadRowID: Sendable, Codable, Hashable {
    var pid: Int32
    var uniqueID: UInt64
}

/// Окно истории для графика: корзины по 5 минут, ряды — топ-5 групп и «прочее».
struct HistoryWindow: Sendable, Codable, Equatable {
    struct Series: Sendable, Codable, Identifiable, Equatable {
        var key: String
        var name: String
        var id: String { key }
    }

    struct Point: Sendable, Codable, Identifiable, Equatable {
        var ts: Int
        var usedMB: Int
        var swapMB: Int
        var pressure: Int
        /// По рядам `series`.
        var values: [Int]
        var id: Int { ts }
    }

    var stepSeconds: Int
    var from: Int
    var to: Int
    var series: [Series]
    var points: [Point]
    var firstSample: Int?
}

enum GroupKind: String, Sendable, Codable {
    case project, app, system, other

    var title: String {
        switch self {
        case .project: return "Проекты"
        case .app: return "Приложения"
        case .system: return "Система"
        case .other: return "Прочее"
        }
    }
}

/// Процесс в составе группы. Сам процесс берётся из `LoadSnapshot.procs` по pid.
struct GroupMember: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    /// Округлённая память; nil — неизвестна (root вне кэша `top`).
    var memMB: Int?
    var why: String = ""
    /// Можно ли остановить его кнопкой (не системный, не чужой, не сама панель).
    var stoppable: Bool
    var uniqueID: UInt64 = 0
    /// Подпись строки: `Kinds.label`.
    var label = "—"
    var note: String?
    var cpuPercent: Double?
    var id: Int32 { pid }
    var rowID: LoadRowID { LoadRowID(pid: pid, uniqueID: uniqueID) }

    /// `why` экран не показывает.
    private enum CodingKeys: String, CodingKey { case pid, memMB, stoppable, uniqueID, label, note, cpuPercent }
}

struct SystemHint: Sendable, Codable, Equatable, Identifiable {
    var title: String
    var how: String
    var savesMB: Int
    var id: String { title }
}

/// Группа процессов: проект, приложение, система или прочее.
struct ProcessGroup: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var kind: GroupKind
    var name: String
    var path: String?
    var memMB: Int
    var count: Int
    /// Все процессы группы: по убыванию памяти, с неизвестной памятью — в конце.
    var members: [GroupMember]
    /// Пять самых тяжёлых и «ещё N»: сумма строк и остатка ровно `memMB` (округление подогнано).
    var topMB: [Int]
    var restCount: Int
    var restMB: Int
    /// Сколько памяти группы освободит кнопка «Остановить группу».
    var stoppableMB: Double
    var hints: [SystemHint] = []

    var top: ArraySlice<GroupMember> { members.prefix(topMB.count) }
}

enum MemoryPressure: Int, Sendable, Codable {
    case normal = 1, warn = 2, critical = 4

    init(level: Int) {
        self = MemoryPressure(rawValue: level) ?? .normal
    }
}

/// Итоги памяти мака — как в Мониторе активности, в целых MB.
struct MemoryTotals: Sendable, Codable, Equatable {
    var totalMB: Int
    /// Занято = приложения + wired + сжатое.
    var usedMB: Int
    var appMB: Int
    var wiredMB: Int
    var compressedMB: Int
    var cachedMB: Int
    var freeMB: Int
    var swapUsedMB: Int
    var swapTotalMB: Int
    var pressure: MemoryPressure
}

struct HostInfo: Sendable, Codable, Equatable {
    var chip: String
    var ramMB: Int
    var macOS: String
    var bootTime: TimeInterval
    var uptime: TimeInterval { Date().timeIntervalSince1970 - bootTime }
}

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

enum AgentVerb: String, Sendable, Codable {
    case stop, disable, enable
}

struct AgentTarget: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var name: String
    var memMB: Double
    var id: Int32 { pid }
}

struct AgentItem: Sendable, Codable, Equatable, Identifiable {
    var label: String
    var name: String
    var vendor: String
    var plist: String?
    var pids: [Int32]
    var memMB: Int
    var keepalive: Bool
    var runAtLoad: Bool
    var disabled: Bool
    /// "gui" или "system": у системных служб (root) кнопок нет, только подсказка sudo.
    var domain: String
    var note: String
    var sudoHint: String?
    var verbs: [AgentVerb]
    /// Процессы задания: корень первым, дальше по убыванию памяти. Для подтверждения.
    var targets: [AgentTarget] = []
    var loaded = false
    /// Почему панель не трогает задание (терминал, сама панель, macOS…).
    var refusal: String?
    /// Где запущен главный процесс; у служб с cwd «/» и из домашней папки — nil.
    var place: ProcessPlace? = nil

    var id: String { label }
    var isRunning: Bool { !pids.isEmpty }
    /// Имя для людей: «Производитель · Приложение» либо метка.
    var title: String {
        let s = [vendor, name].filter { !$0.isEmpty }.joined(separator: " · ")
        return s.isEmpty ? label : s
    }

    /// `targets` и `loaded` нужны только плану действия, его строит модуль.
    private enum CodingKeys: String, CodingKey {
        case label, name, vendor, plist, pids, memMB, keepalive, runAtLoad, disabled, domain, note, sudoHint, verbs, refusal, place
    }
}

/// Готовый список для экрана: сторонние агенты launchd и боты из bots.toml.
struct BackgroundData: Sendable, Codable, Equatable {
    var agents: [AgentItem] = []
    var bots: [BotItem] = []

    var isEmpty: Bool { agents.isEmpty && bots.isEmpty }
}

enum AdviceSeverity: Int, Sendable, Codable, Comparable {
    case high = 0, med = 1, low = 2

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    static func forMB(_ mb: Double) -> AdviceSeverity { mb >= 2048 ? .high : mb >= 500 ? .med : .low }
}

/// Подсказка «что выключить». Кнопка — остановка процесса `stopPid` (если можно).
struct AdviceItem: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var severity: AdviceSeverity
    var title: String
    var detail: String
    var savesMB: Int
    var stopPid: Int32?
    var stopUniqueID: UInt64?

    var stopID: LoadRowID? {
        guard let stopPid, let stopUniqueID else { return nil }
        return LoadRowID(pid: stopPid, uniqueID: stopUniqueID)
    }
}

/// Подтверждение остановки: только текст и строки. Что и как останавливать, знает план в модуле.
struct LoadStopPrompt: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var message: String
    var targets: [AgentTarget]
    var kept: [StopKept]
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

/// Результат последнего действия «Остановить» — показывается баннером на экране.
struct LoadNotice: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var isError: Bool
}

/// Карточка «Диск»: износ SSD из smartctl (только если он установлен), запись на диск с загрузки из ioreg,
/// запись в своп с загрузки и за сутки, доля свопа во всей записи. Объёмы — в десятичных GB/TB,
/// как у производителя диска и в smartctl.
struct DiskCard: Sendable, Codable, Equatable {
    var model: String?
    var sizeGB: Int?
    var wearPct: Int?
    var writtenTB: Double?
    var sparePct: Int?
    var mediaErrors: Int?
    var swapWrittenGBSinceBoot: Double = 0
    var swapGBPerDay: Double
    var swapSharePct: Int?
    var swapWritten24hGB: Double?
    /// Меньше ~23 ч — число за сутки пересчитано, а не замерено; здесь часы, по которым считали.
    var swap24SpanHours: Double?
    /// smartctl установлен и вернул данные об износе.
    var hasSmart: Bool { wearPct != nil || writtenTB != nil || sparePct != nil }

    /// `swapWrittenGBSinceBoot` экран не показывает.
    private enum CodingKeys: String, CodingKey {
        case model, sizeGB, wearPct, writtenTB, sparePct, mediaErrors, swapGBPerDay, swapSharePct, swapWritten24hGB, swap24SpanHours
    }
}

/// Где запущен процесс: проект (папка с `.git` или `package.json`) и полный путь к рабочей папке.
struct ProcessPlace: Sendable, Codable, Equatable {
    /// Имя папки проекта, у домашней папки — пусто.
    var project: String
    /// Рабочая папка с `~` вместо домашней.
    var path: String
    /// Процесс запущен прямо из домашней папки: проекта нет.
    var isHome: Bool

    /// Короткая подпись: имя проекта либо «из домашней папки».
    var title: String { isHome ? "из домашней папки" : project }
}

/// Вид потомка: по нему решаем, что считать dev-сервером, сборкой и что показывать подписью.
enum ProcessKind: String, Sendable, Codable {
    case shell, mcp, devServer, build, other
}

/// Что делает сессия: последний запрос человека и последний шаг ассистента (из хвоста транскрипта).
struct SessionActivity: Sendable, Codable, Equatable {
    var lastPrompt = ""
    var lastPromptTS: TimeInterval?
    var lastAction = ""
    var lastActionTS: TimeInterval?

    /// `lastPromptTS` экран не показывает.
    private enum CodingKeys: String, CodingKey { case lastPrompt, lastAction, lastActionTS }
}

struct AdviceOrphan: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var name: String
    var memMB: Double
    var age: Double
    /// Где запущен: проект и папка. nil — рабочую папку узнать не вышло.
    var place: ProcessPlace?
    var uniqueID: UInt64 = 0
    var id: Int32 { pid }
    var rowID: LoadRowID { LoadRowID(pid: pid, uniqueID: uniqueID) }
}

struct StopKept: Sendable, Codable, Equatable, Identifiable {
    var name: String
    var why: String
    var id: String { "\(name)|\(why)" }
}
