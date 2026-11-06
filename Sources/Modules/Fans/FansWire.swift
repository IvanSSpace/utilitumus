import Foundation

/// Состояние доступа к службе, как его показывает экран.
enum FansHelperStatus: String, Codable, Sendable {
    case notInstalled, installed, outdated, ready

    @MainActor init(_ status: FanHelperInstaller.Status) {
        switch status {
        case .notInstalled: self = .notInstalled
        case .installed: self = .installed
        case .outdated: self = .outdated
        case .ready: self = .ready
        }
    }
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

extension FanController {
    /// Шире любого настоящего вентилятора: отсекает мусор, когда диапазон вентилятора ещё не прочитан.
    static let rpmLimits = 0.0...20_000.0
    /// Те же границы, что у ползунков экрана. Экран падает на границах, из которых не собрать диапазон ползунка.
    static let curveLimits = 30.0...100.0
    static let curveMinSpan = 5.0

    var wireState: FansState {
        let model = BuiltInFansModel.shared
        return FansState(
            fans: model.fans, configs: model.configs, cpuSensors: model.cpuSensors, gpuSensors: model.gpuSensors,
            fullPower: model.fullPower, safetyTripped: model.safetyTripped, conflict: model.conflict,
            lastError: model.lastError, helperStatus: model.helperStatus, helperError: model.helperError,
            gameModeEnabled: model.gameModeEnabled, myGames: model.myGames,
            gameLaunchers: GameRules.defaultLaunchers.map(\.key).filter(model.isLauncherGame),
            addable: model.addable.map { GameEntry(key: $0.key, name: $0.name) },
            gameName: model.gameName, gameLeavingUntil: model.gameLeavingUntil)
    }

    /// Настройки со связи целиком или nil: один плохой вентилятор отменяет всё. Обороты в пределах `rpmLimits`
    /// зажимаются диапазоном вентилятора; служба зажимает ещё раз, но NaN дошёл бы раньше неё до `Int(rpm)` в `apply`.
    func validatedConfigs(_ new: [FanConfig]) -> [FanConfig]? {
        guard new.count == configs.count else { return nil }
        var clean = new
        for (i, config) in new.enumerated() {
            guard Self.rpmLimits.contains(config.rpm),
                  Self.curveLimits.contains(config.fromTemp), Self.curveLimits.contains(config.toTemp),
                  config.toTemp - config.fromTemp >= Self.curveMinSpan else { return nil }
            // 0 — «ещё не выбирали», экран подставит минимум сам.
            if config.rpm > 0, let fan = fans.first(where: { $0.index == i }) {
                clean[i].rpm = min(max(config.rpm, fan.min), fan.max)
            }
        }
        return clean
    }

    /// Действие из связи. Самое длинное настоящее — настройки двух-трёх вентиляторов, до 1 КБ; запас на шесть.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: FansAction.self, limit: 2048, state: { wireState }) { action in
            let error = handle(action)
            return error
        }
    }

    /// Действие со связи: сначала проверка, изменения только после неё. Текст — почему не выполнено, nil — выполнено.
    func handle(_ action: FansAction) -> String? {
        let installer = FanHelperInstaller.shared
        let game = GameModeController.shared
        // Как на экране: без доступа или при конфликте управлять нечем.
        let canControl = installer.status == .ready && conflictingApp == nil
        let noControl = "Сейчас вентиляторами управлять нельзя"
        switch action {
        case .setFullPower(let on):
            guard canControl || !on else { return noControl }
            fullPower = on
        case .setAllAuto:
            guard canControl else { return noControl }
            setAllAuto()
        case .setConfigs(let new):
            guard canControl else { return noControl }
            guard let clean = validatedConfigs(new) else { return "Такие настройки вентиляторов нельзя" }
            configs = clean
        case .closeConflictingApp(let id):
            guard closeConflictingApp(id: id) else { return "Этой программы уже нет" }
        case .installHelper:
            // Окно пароля — только когда экран сам его предлагает.
            guard installer.status == .outdated || installer.status == .notInstalled else { return "Доступ обновлять не нужно" }
            installer.install()
        case .uninstallHelper:
            guard installer.status != .notInstalled else { return "Доступ не установлен" }
            restoreAutoBlocking()
            installer.uninstall()
        case .setScreenOpen(let open):
            installer.screenOpen = open
            if open { installer.refresh() }
        case .setGameModeEnabled(let on):
            game.isEnabled = on
        case .addGame(let key):
            guard let candidate = game.addable.first(where: { $0.key == key }) else { return "Такой программы нет в списке" }
            game.addGame(candidate)
        case .removeGame(let key):
            guard let entry = game.myGames.first(where: { $0.key == key }) else { return "Такой игры нет в списке" }
            game.removeGame(entry)
        case .setLauncherGame(let key, let isGame):
            guard GameRules.launcherKeys.contains(key) else { return "Такого лаунчера нет" }
            game.setLauncherGame(key, isGame)
        case .refreshRunning:
            game.refreshRunning()
        }
        return nil
    }
}
