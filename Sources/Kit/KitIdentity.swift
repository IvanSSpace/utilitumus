import Foundation

extension Kit {
    /// Всё наше: лаунчер, утилита каждого модуля, помощники. Те же строки служат метками launchd.
    /// Список, а не префикс: id назначает себе само приложение, и `local.utilitumus.evil` или
    /// `local.utilitumus.app.x.y` (формат id утилит такое допускает) не должны стать нашими.
    static let ownBundleIDs: Set<String> = Set(
        [hubBundleID, "local.utilitumus.links", "local.utilitumus.fan", "local.utilitumus.voice"]
            + Module.allCases.map { KitLink.bundleID($0.rawValue) })

    /// Только точное совпадение. Подлинность приложения это не проверяет: заявить наш точный id может и чужое.
    /// Годится, чтобы не трогать своё, но не чтобы чему-то доверять.
    static func isOurs(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ownBundleIDs.contains(bundleID)
    }
}
