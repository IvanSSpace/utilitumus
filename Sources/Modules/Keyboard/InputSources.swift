import Foundation
import Carbon
import AppKit

/// Тонкая обёртка над Text Input Sources. Все вызовы — с главного потока.
enum InputSources {
    struct Source {
        let id: String
        let name: String
        let ref: TISInputSource
    }

    /// Включённые раскладки в том порядке, в каком их отдаёт система (без сортировки).
    static func enabled() -> [Source] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue(),
              let refs = list as? [TISInputSource] else { return [] }
        return refs.compactMap(source)
    }

    static func current() -> Source? {
        TISCopyCurrentKeyboardInputSource().flatMap { source($0.takeRetainedValue()) }
    }

    static func select(_ source: Source) {
        // Стенд не переключает настоящую раскладку автора.
        if Kit.standRefuses("раскладка \(source.id)") { return }
        TISSelectInputSource(source.ref)
    }

    /// Имя уведомления о смене раскладки.
    static let changedNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    private static func source(_ ref: TISInputSource) -> Source? {
        guard let id = string(ref, kTISPropertyInputSourceID) else { return nil }
        return Source(id: id, name: string(ref, kTISPropertyLocalizedName) ?? id, ref: ref)
    }

    private static func string(_ ref: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(ref, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

/// Защищённый ввод (поле пароля, Secure Keyboard Entry): пока он включён, listen-tap не получает
/// клавиатурных событий, и Fn не слышно.
enum SecureInput {
    /// Приложение, держащее защищённый ввод; nil — выключен.
    static func owner() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName else {
            return "неизвестном приложении"
        }
        return name
    }
}
