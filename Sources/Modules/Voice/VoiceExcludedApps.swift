import SwiftUI
import AppKit

/// Имя, иконка и выбор .app для списка «Не включать голос в этих приложениях».
@MainActor
enum VoiceExcludedApps {
    /// Уменьшенные иконки по bundle id: не перерисовывать на каждое обновление экрана.
    private static var iconCache: [String: NSImage] = [:]

    private static func url(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Имя программы; если она удалена с диска — сам bundle id.
    static func name(_ bundleID: String) -> String {
        guard let url = url(bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let hit = iconCache[bundleID] { return hit }
        guard let url = url(bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 28, height: 28)
        iconCache[bundleID] = icon
        return icon
    }

    /// Окно выбора .app в /Applications; возвращает bundle id выбранной программы.
    static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Выбери программу, где голос Utilitumus не нужен"
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
