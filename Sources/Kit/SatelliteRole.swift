import AppKit

/// Как утилите работать сейчас. Арбитр передачи — центр: см. «Переезд модуля» в дизайне.
enum SatelliteRole {
    enum Mode: Equatable {
        case active
        case passive(reason: String)
        case forwardAndExit
    }

    /// Первая версия центра, которая умеет передавать модуль.
    private static let arbiterVersion = "0.6.0"
    private static let outdatedHubReason = "Модуль уже работает в Utilitumus — обновите центр"

    static func decide(launchedByLaunchd: Bool, hubRunning: Bool, hubVersion: String?, hubModuleOn: Bool, handedOver: Bool) -> Mode {
        guard launchedByLaunchd else { return .forwardAndExit }
        guard hubRunning, hubModuleOn else { return .active }
        guard isArbiter(hubVersion) else { return .passive(reason: outdatedHubReason) }
        return handedOver ? .active : .passive(reason: "Ждём передачу от центра")
    }

    /// Блокировку включил сам человек, поэтому запуск центра её не снимает: встроенный модуль без нажатия кнопки
    /// блокировку не держит, двойной работы нет. Снимают только выключение утилиты и старый центр: тот не передаст
    /// модуль никогда, и там он уже может работать.
    static func mustRelease(mode: Mode, enabled: Bool) -> Bool {
        !enabled || mode == .passive(reason: outdatedHubReason)
    }

    /// Строгая проверка формы: `Kit.isNewer` считает мусор нулём, и «0.6.0abc» оказалась бы равна 0.6.0.
    private static func isArbiter(_ version: String?) -> Bool {
        guard let version, SatelliteCatalog.isValidVersion(version) else { return false }
        return !Kit.isNewer(arbiterVersion, than: version)
    }

    /// Пишет центр, выключив встроенный модуль.
    static func handedOverKey(_ id: String) -> String { "App.\(id).HandedOver" }
    static func hubModuleOnKey(_ id: String) -> String { "ModuleOn.\(id)" }
}

enum SatelliteEnabled {
    static func key(_ id: String) -> String { "App.\(id).Enabled" }

    /// Первый запуск берёт значение у встроенного модуля и больше на него не смотрит.
    /// Ключа нет — центра тут не было, утилиту поставили отдельно: включена. Явный false остаётся false.
    static func load(id: String, defaults: UserDefaults) -> Bool {
        if let stored = defaults.object(forKey: key(id)) as? Bool { return stored }
        let inherited = defaults.object(forKey: SatelliteRole.hubModuleOnKey(id)) as? Bool ?? true
        defaults.set(inherited, forKey: key(id))
        return inherited
    }
}

/// Что утилита видит о центре: запущенный процесс и Info.plist его бандла, где бы тот ни лежал.
/// В сборке со швом — подставное из suite стенда: настоящий центр на этом Mac может быть запущен, и стенд не должен
/// от этого зависеть. `Test.HubBundleID` включает настоящий поиск, но подставного центра.
enum SatelliteHub {
    static var isRunning: Bool {
        #if KIT_TEST_DEFAULTS
        if Kit.defaults.string(forKey: "Test.HubBundleID") == nil { return Kit.defaults.bool(forKey: "Test.HubRunning") }
        #endif
        return process != nil
    }

    static var version: String? {
        #if KIT_TEST_DEFAULTS
        if Kit.defaults.string(forKey: "Test.HubBundleID") == nil { return Kit.defaults.string(forKey: "Test.HubVersion") }
        #endif
        guard let bundle = process?.bundleURL else { return nil }
        return NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private static var process: NSRunningApplication? {
        #if KIT_TEST_DEFAULTS
        let id = Kit.defaults.string(forKey: "Test.HubBundleID") ?? ""
        #else
        let id = Kit.hubBundleID
        #endif
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { !$0.isTerminated }
    }
}
