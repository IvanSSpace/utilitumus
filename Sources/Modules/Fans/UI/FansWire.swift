import Foundation

/// Состояние доступа к службе, как его показывает экран.
enum FansHelperStatus: String, Codable, Sendable {
    case notInstalled, installed, outdated, ready
}

/// Чужая программа, которая управляет вентиляторами. `id` выдала утилита, pid наружу не выходит.
struct FansConflict: Codable, Equatable, Sendable {
    let id: String
    let name: String?
}

/// То, что вкладка центра показывает на экране.
struct FansState: Codable, Equatable, Sendable {
    var fans: [FanReading]
    var configs: [FanConfig]
    var cpuSensors: [SensorReading]
    var gpuSensors: [SensorReading]
    var fullPower: Bool
    var safetyTripped: Bool
    var conflict: FansConflict?
    var lastError: String?
    var helperStatus: FansHelperStatus
    var helperError: String?
    var gameModeEnabled: Bool
    var myGames: [GameEntry]
    /// Только известные лаунчеры, по порядку: набор кодировался бы всякий раз по-разному.
    var gameLaunchers: [String]
    /// Запущенные программы для меню «Добавить…». Иконки по связи не идут.
    var addable: [GameEntry]
    var gameName: String?
    var gameLeavingUntil: Date?
}

/// Что вкладка центра может попросить. Больше утилита ничего не примет.
enum FansAction: Codable, Equatable, Sendable {
    case setFullPower(Bool)
    case setAllAuto
    /// Настройки всех вентиляторов сразу: так частые движения ползунка склеиваются до последнего значения.
    case setConfigs([FanConfig])
    case closeConflictingApp(id: String)
    /// Покажет окно пароля macOS.
    case installHelper
    case uninstallHelper
    case setScreenOpen(Bool)
    case setGameModeEnabled(Bool)
    /// Ключ из `addable`, имя утилита берёт у себя.
    case addGame(key: String)
    case removeGame(key: String)
    case setLauncherGame(key: String, isGame: Bool)
    case refreshRunning

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setFullPower": self = .setFullPower(try wire.value())
        case "setAllAuto": try wire.none(); self = .setAllAuto
        case "setConfigs": self = .setConfigs(try wire.value())
        case "closeConflictingApp":
            try wire.fields("id")
            self = .closeConflictingApp(id: try wire.field("id"))
        case "installHelper": try wire.none(); self = .installHelper
        case "uninstallHelper": try wire.none(); self = .uninstallHelper
        case "setScreenOpen": self = .setScreenOpen(try wire.value())
        case "setGameModeEnabled": self = .setGameModeEnabled(try wire.value())
        case "addGame":
            try wire.fields("key")
            self = .addGame(key: try wire.field("key"))
        case "removeGame":
            try wire.fields("key")
            self = .removeGame(key: try wire.field("key"))
        case "setLauncherGame":
            try wire.fields("key", "isGame")
            self = .setLauncherGame(key: try wire.field("key"), isGame: try wire.field("isGame"))
        case "refreshRunning": try wire.none(); self = .refreshRunning
        default: throw wire.refuse()
        }
    }
}
