import Foundation

/// Общее для центра и утилит.
enum Kit {
    static let hubBundleID = "local.utilitumus"

    /// Домен настроек один на центр и утилиты. Свой bundle id как suiteName macOS не принимает,
    /// поэтому в центре именно `.standard`.
    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == hubBundleID
        ? .standard
        : UserDefaults(suiteName: hubBundleID)!

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
