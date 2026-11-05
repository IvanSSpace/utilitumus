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

    static func decide(launchedByLaunchd: Bool, hubRunning: Bool, hubVersion: String?, hubModuleOn: Bool, handedOver: Bool) -> Mode {
        guard launchedByLaunchd else { return .forwardAndExit }
        guard hubRunning, hubModuleOn else { return .active }
        guard isArbiter(hubVersion) else { return .passive(reason: "Модуль уже работает в Utilitumus — обновите центр") }
        return handedOver ? .active : .passive(reason: "Ждём передачу от центра")
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
    static func load(id: String, defaults: UserDefaults) -> Bool {
        if let stored = defaults.object(forKey: key(id)) as? Bool { return stored }
        let inherited = defaults.bool(forKey: SatelliteRole.hubModuleOnKey(id))
        defaults.set(inherited, forKey: key(id))
        return inherited
    }
}

/// Что утилита видит о центре. В сборке со швом — подставное из suite стенда: настоящий центр на этом Mac
/// может быть запущен, и стенд не должен от этого зависеть.
enum SatelliteHub {
    static var isRunning: Bool {
        #if KIT_TEST_DEFAULTS
        Kit.defaults.bool(forKey: "Test.HubRunning")
        #else
        !NSRunningApplication.runningApplications(withBundleIdentifier: Kit.hubBundleID).isEmpty
        #endif
    }

    static var version: String? {
        #if KIT_TEST_DEFAULTS
        Kit.defaults.string(forKey: "Test.HubVersion")
        #else
        NSDictionary(contentsOfFile: "/Applications/Utilitumus.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
        #endif
    }
}
