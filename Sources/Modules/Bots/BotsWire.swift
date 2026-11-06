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

/// Найденный поиском бот, как его видит экран: имя, где найден, почему похож. Команд, путей к плисту и pid здесь нет:
/// запись для bots.toml утилита строит сама по id кандидата.
struct BotFound: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var place: String
    var why: String
    /// «Возможно»: уверенного признака нет, только название или закрытая папка.
    var possible: Bool
    /// Без launchd: бот только наблюдается, кнопок управления не будет.
    var monitorOnly: Bool
}

/// Результат «Найти ботов». nil у состояния — поиска ещё не было.
struct BotsDiscoveryState: Codable, Equatable, Sendable {
    var scanning: Bool
    var found: [BotFound]
    /// Агенты с именем, которое не подставляется в команду: их не предлагаем.
    var skipped: Int

    static let scanning = BotsDiscoveryState(scanning: true, found: [], skipped: 0)
}

struct BotsState: Codable, Equatable, Sendable {
    /// Не больше стольких карточек: файл не должен раздувать ответ.
    static let maxBots = 64

    var file: BotsFileState
    var bots: [BotCard]
    var prompt: BotsPrompt?
    var running: Bool
    var notice: BotsNotice?
    var discovery: BotsDiscoveryState?

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
    /// Быстрое действие дашборда и меню: человека уже спросил центр. `sum` — отпечаток команды, которую он видел.
    case quick(id: String, verb: BotVerb, sum: String)
    /// Поиск ботов на этом Mac. Идёт только по этой просьбе.
    case find
    /// Добавить найденного бота: только его id, запись строит утилита.
    case add(id: String)
    case dismissFound

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "refresh": try wire.none(); self = .refresh
        case "cancel": try wire.none(); self = .cancel
        case "dismissNotice": try wire.none(); self = .dismissNotice
        case "find": try wire.none(); self = .find
        case "dismissFound": try wire.none(); self = .dismissFound
        case "add":
            try wire.fields("id")
            self = .add(id: try wire.field("id"))
        case "request":
            try wire.fields("id", "verb")
            self = .request(id: try wire.field("id"), verb: try wire.field("verb"))
        case "quick":
            try wire.fields("id", "verb", "sum")
            self = .quick(id: try wire.field("id"), verb: try wire.field("verb"), sum: try wire.field("sum"))
        case "confirm":
            try wire.fields("planID")
            self = .confirm(planID: try wire.field("planID"))
        default: throw wire.refuse()
        }
    }
}
