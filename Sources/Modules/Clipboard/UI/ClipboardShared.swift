import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Горячая клавиша панели по умолчанию.
enum ClipboardDefaults {
    static let keyCode = UInt32(kVK_ANSI_V)
    static let modifiers = UInt32(cmdKey | shiftKey)
}

/// Палитра пространств: в хранилище лежит только id.
enum ClipPalette {
    static let all: [(id: String, name: String, color: Color)] = [
        ("blue", "Синий", Color(red: 0.30, green: 0.55, blue: 1.0)),
        ("teal", "Бирюзовый", Color(red: 0.20, green: 0.78, blue: 0.78)),
        ("green", "Зелёный", Color(red: 0.30, green: 0.80, blue: 0.45)),
        ("yellow", "Жёлтый", Color(red: 0.98, green: 0.78, blue: 0.25)),
        ("orange", "Оранжевый", Color(red: 1.0, green: 0.55, blue: 0.22)),
        ("red", "Красный", Color(red: 0.97, green: 0.35, blue: 0.38)),
        ("pink", "Розовый", Color(red: 0.96, green: 0.45, blue: 0.70)),
        ("purple", "Фиолетовый", Color(red: 0.68, green: 0.48, blue: 0.98)),
        ("gray", "Серый", Color(red: 0.62, green: 0.64, blue: 0.70)),
    ]

    static func color(_ id: String) -> Color { all.first { $0.id == id }?.color ?? all[0].color }
    static func nextID(after count: Int) -> String { all[count % all.count].id }
}

/// «5 мин назад», «вчера».
func clipAgo(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "только что" }
    if s < 3600 { return "\(s / 60) мин назад" }
    if s < 86400 { return "\(s / 3600) ч назад" }
    if s < 2 * 86400 { return "вчера" }
    return "\(s / 86400) дн. назад"
}

/// Иконки программ-источников: по bundle id, чтобы не перерисовывать на каждый кадр.
@MainActor
enum ClipSourceIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[bundleID] = icon
        return icon
    }
}
