import Foundation

// Снимок Студии на проводе: утилиты, мастера, дела, очередь хаба. Собирает его только утилита (у неё токен), центр лишь рисует.
// Всё здесь ограничено по размеру при сборке (`StudioBoardParser`), а не при показе: что дошло до экрана, уже короткое.

enum StudioMasterState: String, Codable, Sendable {
    case working, waiting, idle, asleep, none

    var label: String {
        switch self {
        case .working: return "мастер работает"
        case .waiting: return "мастер ждёт ответа"
        case .idle: return "мастер на связи"
        case .asleep: return "мастер спит"
        case .none: return "мастера ещё нет"
        }
    }
}

enum StudioUnitKind: String, Codable, Sendable {
    case utility, launcher, orchestrator
}

/// Статус карточки так, как его считает страница Студии (app.js: statusKey).
enum StudioStatusKey: String, CaseIterable, Sendable {
    case work, ready, stable, bug, dev

    var label: String {
        switch self {
        case .work: return "в работе"
        case .ready: return "готова к выпуску"
        case .stable: return "стабильна"
        case .bug: return "есть баг"
        case .dev: return "в разработке"
        }
    }
}

/// Смена мастера идёт в фоне у сервера Студии; её стадия приходит в снимке.
struct StudioRotation: Codable, Equatable, Sendable {
    var stage: String
    var message: String

    var failed: Bool { stage == "error" }
    var running: Bool { stage == "handover" || stage == "launching" }
}

struct StudioUnit: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: StudioUnitKind
    var title: String
    var summary: String
    /// `#RRGGBB` плашки, пока значка нет.
    var tint: String
    var version: String?
    /// `stable`, `wip`, `ready`, `bug` из дела; nil — дела нет.
    var status: String?
    var openTasks: Int
    var bugs: Int
    var hasIcon: Bool
    var branch: String?
    var ahead: Int?
    var master: StudioMasterState
    var contextPct: Int?
    /// Миллисекунды с 1970: когда мастер последний раз работал.
    var lastActive: Int64?
    var rotation: StudioRotation?

    var statusKey: StudioStatusKey {
        if kind == .utility && (version ?? "").isEmpty { return .dev }
        let key: StudioStatusKey
        switch status {
        case "wip": key = .work
        case "ready": key = .ready
        case "bug": key = .bug
        default: key = .stable
        }
        return key == .stable && bugs > 0 ? .bug : key
    }

    var released: Bool { !(version ?? "").isEmpty }

    /// Контекст мастера выше порога: пора менять.
    var contextHot: Bool { (contextPct ?? 0) >= 60 }
}

struct StudioHubTask: Codable, Equatable, Sendable {
    var name: String
    var status: String
    var comment: String

    /// Подпись и вид статуса задачи Orca.
    var label: String {
        switch status {
        case "in-progress": return "в работе"
        case "in-review": return "готово"
        case "todo": return "ждёт"
        default: return status.isEmpty ? "—" : status
        }
    }
}

struct StudioQueueItem: Codable, Equatable, Sendable {
    var done: Bool
    var text: String
}

/// Дело и очередь выбранной утилиты. Грузится только для выбранной, не на каждом опросе.
struct StudioDetail: Codable, Equatable, Sendable {
    var id: String
    var caseText: String
    var casePath: String
    var queue: [StudioQueueItem]
}

/// Короткое сообщение о последнем действии. Номер растёт: экран показывает каждое новое, даже с тем же текстом.
struct StudioNotice: Codable, Equatable, Sendable {
    var id: Int
    var text: String
    var isError: Bool
}

enum StudioFilter: String, CaseIterable, Sendable {
    case all, work, ready, bug, dev

    var title: String {
        switch self {
        case .all: return "Все"
        case .work: return "В работе"
        case .ready: return "Готовы"
        case .bug: return "С багами"
        case .dev: return "В разработке"
        }
    }

    /// Как `match` на странице: только утилиты, поиск по названию и id, «с багами» — и по счётчику багов.
    func matches(_ unit: StudioUnit, query: String) -> Bool {
        guard unit.kind == .utility else { return false }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, !unit.title.lowercased().contains(q), !unit.id.contains(q) { return false }
        switch self {
        case .all: return true
        case .bug: return unit.statusKey == .bug || unit.bugs > 0
        case .work: return unit.statusKey == .work
        case .ready: return unit.statusKey == .ready
        case .dev: return unit.statusKey == .dev
        }
    }
}

/// Всё, что центр показывает про утилиты. Пусто, пока сервер не работает или экран закрыт.
struct StudioBoard: Codable, Equatable, Sendable {
    var units: [StudioUnit] = []
    var hubTasks: [StudioHubTask] = []
    /// Что сказал Orca, если не ответила: страница показывает это баннером.
    var orcaError: String?
    /// Значки утилит: PNG до `StudioBoardParser.maxIconBytes`.
    var icons: [String: Data] = [:]
    var selected: String?
    var detail: StudioDetail?
    var notice: StudioNotice?
    /// Не вышло прочитать состояние Студии: готовая строка. Прежний снимок остаётся на экране.
    var problem: String?
    /// Утилиты, у которых сейчас идёт действие: кнопки на них не нажимаются повторно. Ключ — id утилиты или `commit`.
    var working: [String] = []

    func unit(_ id: String) -> StudioUnit? { units.first { $0.id == id } }
}

enum StudioUnitID {
    /// Так же, как у сервера: `[a-z]+`, плюс предел длины.
    static func isValid(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A }
    }
}

enum StudioAgo {
    /// «сейчас», «5 мин назад», «3 ч назад», «вчера», «4 дн назад»; nil — мастер ещё не работал.
    static func text(_ lastActive: Int64?, now: Date = Date()) -> String {
        guard let lastActive, lastActive > 0 else { return "ещё не работал" }
        let minutes = Int(((now.timeIntervalSince1970 * 1000 - Double(lastActive)) / 60_000).rounded())
        if minutes < 2 { return "сейчас" }
        if minutes < 60 { return "\(minutes) мин назад" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return "\(hours) ч назад" }
        let days = Int((Double(hours) / 24).rounded())
        return days == 1 ? "вчера" : "\(days) дн назад"
    }
}
