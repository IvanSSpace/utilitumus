import Foundation

/// Общее для центра и утилит.
enum Kit {
    static let hubBundleID = "local.utilitumus"

    /// Домен настроек один на центр и утилиты. Свой bundle id как suiteName macOS не принимает,
    /// поэтому в центре именно `.standard`.
    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == hubBundleID
        ? .standard
        : UserDefaults(suiteName: hubBundleID)!
}
