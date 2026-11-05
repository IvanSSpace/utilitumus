import Foundation
import Carbon

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

/// Системное действие клавиши 🌐 и диктовка: то, что может сработать вместе с нашим переключением.
enum FnSystemAction {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    /// Прежнее значение, пока мы держим 0: Int, а -1 — ключа не было.
    private static let savedKey = "Keyboard.SavedFnUsage"

    /// Текущее значение; nil — ключа нет (система действует по умолчанию, это не «ничего»).
    static var usage: Int? {
        (CFPreferencesCopyAppValue(key, domain) as? NSNumber)?.intValue
    }

    /// Система сама переключит язык или сделает что-то ещё по одному нажатию 🌐.
    static var conflicts: Bool { usage != 0 }

    /// Что делает системное действие, для строки статуса.
    static func title(for usage: Int?) -> String {
        switch usage {
        case 0: return "Ничего не делает"
        case 1: return "Переключает раскладку"
        case 2: return "Показывает эмодзи"
        case 3: return "Запускает диктовку"
        case nil: return "По умолчанию в macOS"
        default: return "Другое действие"
        }
    }

    /// Мы выставили 0 и помним, что было.
    static var isOverridden: Bool { UserDefaults.standard.object(forKey: savedKey) != nil }

    static func disable() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedKey) == nil { defaults.set(usage ?? -1, forKey: savedKey) }
        write(0)
    }

    /// Вернуть значение, если его меняли мы.
    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.object(forKey: savedKey) as? Int else { return }
        write(saved < 0 ? nil : saved)
        defaults.removeObject(forKey: savedKey)
    }

    private static func write(_ value: Int?) {
        CFPreferencesSetAppValue(key, value.map { NSNumber(value: $0) }, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// Диктовка по двойному нажатию Fn: горячая клавиша 164 в symbolichotkeys с модификатором Fn.
    static var dictationOnDoubleFn: Bool {
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        guard let item = (all as? [String: Any])?["164"] as? [String: Any],
              (item["enabled"] as? NSNumber)?.boolValue == true,
              let value = item["value"] as? [String: Any],
              value["type"] as? String == "modifier",
              let params = value["parameters"] as? [NSNumber], let mask = params.first else { return false }
        return mask.intValue & 0x800000 != 0
    }
}
