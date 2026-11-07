import Foundation

/// То, что вкладка центра показывает на экране. Пути, кадры окон и хэши заголовков сюда не входят.
struct StashState: Codable, Equatable, Sendable {
    struct Program: Codable, Equatable, Sendable {
        var bundleID: String
        var name: String
        /// Закроет ли его «Спрятать выбранные».
        var closing: Bool
    }

    struct Stashed: Codable, Equatable, Sendable {
        var bundleID: String
        var name: String
        var windowCount: Int
    }

    var running: [Program]
    var stubborn: [Program]
    var stashed: [Stashed]
    var usage: [String: AppUsage]
    var scenarios: [StashScenario]
    var busy: String?
    var report: RestoreReport?
}

/// Что вкладка центра может попросить. Больше утилита ничего не примет.
/// Программы называются только id из её же списков: ни путей, ни pid.
enum StashAction: Codable, Equatable, Sendable {
    case setClosing(bundleID: String, closing: Bool)
    case selectOnlyHeavy
    /// Ровно те программы, что были в подтверждении. «Закрыть отмеченные» не годится: за время
    /// ответа в список могла попасть новая программа, а новая по умолчанию отмечена.
    case stash(bundleIDs: [String])
    case restore
    case forceTerminate(bundleIDs: [String])
    case addScenario(name: String)
    case updateScenario(id: UUID)
    case renameScenario(id: UUID, name: String)
    case deleteScenario(id: UUID)
    case selectScenario(id: UUID)
    /// Экран открыт: замерить память и процессор.
    case refreshUsage

    /// Разбор строгий: ровно одно известное действие и ровно его поля, всё лишнее — ошибка.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setClosing":
            try wire.fields("bundleID", "closing")
            self = .setClosing(bundleID: try wire.field("bundleID"), closing: try wire.field("closing"))
        case "selectOnlyHeavy":
            try wire.none()
            self = .selectOnlyHeavy
        case "stash":
            try wire.fields("bundleIDs")
            self = .stash(bundleIDs: try wire.field("bundleIDs"))
        case "restore":
            try wire.none()
            self = .restore
        case "forceTerminate":
            try wire.fields("bundleIDs")
            self = .forceTerminate(bundleIDs: try wire.field("bundleIDs"))
        case "addScenario":
            try wire.fields("name")
            self = .addScenario(name: try wire.field("name"))
        case "updateScenario":
            try wire.fields("id")
            self = .updateScenario(id: try wire.field("id"))
        case "renameScenario":
            try wire.fields("id", "name")
            self = .renameScenario(id: try wire.field("id"), name: try wire.field("name"))
        case "deleteScenario":
            try wire.fields("id")
            self = .deleteScenario(id: try wire.field("id"))
        case "selectScenario":
            try wire.fields("id")
            self = .selectScenario(id: try wire.field("id"))
        case "refreshUsage":
            try wire.none()
            self = .refreshUsage
        default:
            throw wire.refuse()
        }
    }
}
