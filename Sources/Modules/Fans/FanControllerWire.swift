import Foundation

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

extension FansHelperStatus {
    @MainActor init(_ status: FanHelperInstaller.Status) {
        switch status {
        case .notInstalled: self = .notInstalled
        case .installed: self = .installed
        case .outdated: self = .outdated
        case .ready: self = .ready
        }
    }
}
