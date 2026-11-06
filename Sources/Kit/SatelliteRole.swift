import AppKit
import Security

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

    /// Снять всё, что модуль держит, что бы он ни переопределял в `enterPassive`: утилита выключена или центр старый.
    /// Тот не передаст модуль никогда, и там он уже может работать. Версию не прочитали (`hubVersion == nil`) — старым
    /// центр не назван: новая работа пассивной всё равно не дана, а о начатой решает `enterPassive`.
    static func mustRelease(mode: Mode, enabled: Bool, hubVersion: String?) -> Bool {
        !enabled || (mode == .passive(reason: outdatedHubReason) && hubVersion != nil)
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

/// Что утилита видит о центре: запущенный процесс с подписью автора и Info.plist его бандла, где бы тот ни лежал.
/// Процесс с чужой подписью центром не считается, как бы он себя ни назвал: иначе подделка с нашим id выключала бы
/// все утилиты. Не удалось проверить — тоже не центр: на сомнении утилита работает.
/// В сборке со швом — подставное из suite стенда: настоящий центр на этом Mac может быть запущен, и стенд не должен
/// от этого зависеть. `Test.HubBundleID` включает настоящий поиск, но подставного центра.
enum SatelliteHub {
    static var isRunning: Bool {
        #if KIT_TEST_DEFAULTS
        if Kit.defaults.string(forKey: "Test.HubBundleID") == nil { return Kit.defaults.bool(forKey: "Test.HubRunning") }
        #endif
        return verified != nil
    }

    static var version: String? {
        #if KIT_TEST_DEFAULTS
        if Kit.defaults.string(forKey: "Test.HubBundleID") == nil { return Kit.defaults.string(forKey: "Test.HubVersion") }
        #endif
        return verified?.version
    }

    /// Бандл проверенного центра: куда вести просьбу «открой модуль». В сборке со швом центра для открытия нет.
    static var bundleURL: URL? {
        #if KIT_TEST_DEFAULTS
        return nil
        #else
        return verified?.bundle
        #endif
    }

    private static var verified: Verified? {
        #if KIT_TEST_DEFAULTS
        let id = Kit.defaults.string(forKey: "Test.HubBundleID") ?? ""
        #else
        let id = Kit.hubBundleID
        #endif
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
            if let found = verify(pid: app.processIdentifier, identifier: id) { return found }
        }
        return nil
    }

    /// Проверенный центр: версия взята из бандла, чью подпись проверили.
    struct Verified: Equatable {
        let bundle: URL
        let version: String?
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [pid_t: Verified] = [:]

    /// Подпись автора с меткой выпуска и нужным identifier: живой процесс и бандл на диске. Удачная проверка запоминается
    /// на pid, неудачная нет: сбой разового вызова не должен навсегда сделать настоящий центр чужим.
    /// Здесь pid не служит доказательством личности: решение «центр запущен» обратимо и пересматривается при каждом
    /// изменении списка приложений, а власти над утилитой подделка не получает.
    static func verify(pid: pid_t, identifier: String) -> Verified? {
        cacheLock.lock()
        if let cached = cache[pid] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let result = check(pid: pid, identifier: identifier) else { return nil }
        cacheLock.lock()
        cache[pid] = result
        cacheLock.unlock()
        return result
    }

    private static func check(pid: pid_t, identifier: String) -> Verified? {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, path: CFURL?
        guard SecRequirementCreateWithString(KitLink.requirement(identifier: identifier) as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: Int(pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess,
              SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let url = path as URL? else { return nil }
        let version = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        return Verified(bundle: url, version: version)
    }
}
