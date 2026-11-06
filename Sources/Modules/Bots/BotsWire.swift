import Foundation

/// Карточка бота на экране. Команд, путей и pid здесь нет: они остаются в bots.toml и в модуле.
struct BotCard: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var project: String
    var state: BotState
    var memMB: Int
    /// Секунды, с точностью до минуты: иначе состояние менялось бы на каждом замере.
    var uptime: Int
    var ports: [String]
    var url: String?
    var note: String
    /// Только кнопки, у которых в bots.toml есть команда и которые подходят состоянию.
    var verbs: [BotVerb]
}

/// Что покажет подтверждение. План строит модуль по своему файлу; центр называет только id плана.
struct BotsPrompt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var message: String
    var command: String
    var confirmTitle: String
    var destructive: Bool
}

struct BotsNotice: Codable, Equatable, Sendable {
    var text: String
    var isError: Bool
}

/// Что с bots.toml: экран объясняет это пустой странице и предупреждением над карточками.
struct BotsFileState: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case ok, missing, unsafe, invalid }
    var kind: Kind
    var detail: String

    static let ok = BotsFileState(kind: .ok, detail: "")
}

struct BotsState: Codable, Equatable, Sendable {
    /// Не больше стольких карточек: файл не должен раздувать ответ.
    static let maxBots = 64

    var file: BotsFileState
    var bots: [BotCard]
    var prompt: BotsPrompt?
    var running: Bool
    var notice: BotsNotice?

    static let empty = BotsState(file: BotsFileState(kind: .missing, detail: ""), bots: [], prompt: nil, running: false, notice: nil)
}

/// Что экран может попросить. Только id бота и кнопка: команду утилита находит в своём bots.toml сама,
/// а plan подтверждается по id, который она же выдала.
enum BotsAction: Codable, Equatable {
    case refresh
    case request(id: String, verb: BotVerb)
    case cancel
    case confirm(planID: UUID)
    case dismissNotice
    /// Быстрое действие дашборда и меню: человека уже спросил центр.
    case quick(id: String, verb: BotVerb)

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "refresh": try wire.none(); self = .refresh
        case "cancel": try wire.none(); self = .cancel
        case "dismissNotice": try wire.none(); self = .dismissNotice
        case "request":
            try wire.fields("id", "verb")
            self = .request(id: try wire.field("id"), verb: try wire.field("verb"))
        case "quick":
            try wire.fields("id", "verb")
            self = .quick(id: try wire.field("id"), verb: try wire.field("verb"))
        case "confirm":
            try wire.fields("planID")
            self = .confirm(planID: try wire.field("planID"))
        default: throw wire.refuse()
        }
    }
}
