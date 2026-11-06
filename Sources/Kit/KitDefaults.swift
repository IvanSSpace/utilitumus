import ApplicationServices
import Foundation

/// Общее для центра и утилит.
enum Kit {
    static let hubBundleID = "local.utilitumus"

    /// Домен настроек один на центр и утилиты. Свой bundle id как suiteName macOS не принимает,
    /// поэтому в центре именно `.standard`.
    /// Сборка со швом `KIT_TEST_DEFAULTS` (тесты и стенды) пишет только в свой suite: код Kit в процессе
    /// без bundle id центра иначе менял бы настоящие настройки. Переменная окружения есть только в этой сборке:
    /// так проверки разных модулей живут в своих suite и идут одновременно. Домен вне тестовых сборка не примет.
    #if KIT_TEST_DEFAULTS
    static let defaults: UserDefaults = {
        let suite = ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? "local.utilitumus.test.kit"
        precondition(suite.hasPrefix("local.utilitumus.test."), "Стенд пишет только в тестовый домен")
        return UserDefaults(suiteName: suite)!
    }()
    #else
    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == hubBundleID
        ? .standard
        : UserDefaults(suiteName: hubBundleID)!
    #endif

    /// Сборка со швом не должна касаться ничего настоящего. Стенд под launchd живёт с настоящим домом, поэтому
    /// путь в настоящем доме, в `/Applications` или `/Library` значит ошибку шва: стенд падает, а не трогает.
    /// Домены настроек `local.utilitumus.test.*` разрешены: это сам шов. Вне тестовой сборки вызов пустой.
    static func assertStandPath(_ path: String, _ what: String = "") {
        #if KIT_TEST_DEFAULTS
        if let found = standForbiddenRoot(of: path) {
            fputs("СТЕНД ЗАТРОНУЛ НАСТОЯЩЕЕ (\(what)): \(path) внутри \(found)\n", stderr)
            fatalError("Стенд не трогает настоящее: \(path)")
        }
        #endif
    }

    static func assertStandPath(_ url: URL, _ what: String = "") { assertStandPath(url.path, what) }

    /// Внешнее действие (закрыть чужую программу, сменить настройку системы, спросить пароль): стенд отказывается
    /// и говорит об этом в stderr. Вне тестовой сборки всегда false, действие идёт как обычно.
    static func standRefuses(_ what: String) -> Bool {
        #if KIT_TEST_DEFAULTS
        fputs("стенд отказал: \(what)\n", stderr)
        return true
        #else
        return false
        #endif
    }

    /// Можно ли стенду закрыть программу с таким бандлом: подставные из временных папок можно, настоящие
    /// (в `/Applications`, `/System`, настоящем доме) нет. Вне тестовой сборки всегда да.
    static func standMayClose(bundlePath: String?, _ what: String) -> Bool {
        #if KIT_TEST_DEFAULTS
        guard let bundlePath, standForbiddenRoot(of: bundlePath) != nil else { return true }
        return !standRefuses("закрыть \(what)")
        #else
        return true
        #endif
    }

    #if KIT_TEST_DEFAULTS
    /// Настоящий дом по паспорту пользователя: `CFFIXED_USER_HOME` и `HOME` его не подменяют.
    static var realHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/Users/\(NSUserName())"
    }

    static func standForbiddenRoot(of path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: realHome).resolvingSymlinksInPath().path
        let prefs = home + "/Library/Preferences/local.utilitumus.test."
        if resolved.hasPrefix(prefs) { return nil }
        // Подставной дом (`CFFIXED_USER_HOME` во временной папке) разрешён, настоящий нет.
        for root in [home, "/Applications", "/Library", "/System", "/usr", "/Users"] where resolved == root || resolved.hasPrefix(root + "/") {
            return root
        }
        return nil
    }
    #endif

    /// Универсальный доступ у этого процесса. Стенд (сборка со швом) задаёт его ключом `Test.AXTrusted`: у центра в терминале
    /// и у утилиты под launchd он разный, а пиксели двух экранов сравниваются.
    static func accessTrusted() -> Bool {
        #if KIT_TEST_DEFAULTS
        if let forced = defaults.object(forKey: "Test.AXTrusted") as? Bool { return forced }
        #endif
        return AXIsProcessTrusted()
    }

    /// Сравнение по числам: 0.10.0 новее 0.9.1.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
