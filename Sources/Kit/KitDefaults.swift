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
