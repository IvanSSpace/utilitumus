import Foundation

// Подмена InputSources.swift, FnSystemAction.swift и AccessState в проверке связи «Клавиатуры». Настоящие файлы в стенд не собираются,
// поэтому записи в com.apple.HIToolbox и com.apple.symbolichotkeys, снятие TextInputSwitcher и смена раскладки
// в нём невозможны: скрипт проверяет это ещё и по символам готового файла.

@MainActor enum Stub {
    static var calls: [String] = []
    static var usage: Int? = 1
    static var dictation = true
    static var layouts = [InputSources.Source(id: "com.apple.keylayout.ABC", name: "ABC"),
                          InputSources.Source(id: "com.apple.keylayout.Russian", name: "Русская")]
    static var current: InputSources.Source? = layouts[0]
}

@MainActor enum InputSources {
    struct Source {
        let id: String
        let name: String
    }
    static let changedNotification = Notification.Name("test.keyboard.layout.changed")
    static func enabled() -> [Source] { Stub.layouts }
    static func current() -> Source? { Stub.current }
    static func select(_ source: Source) { Stub.calls.append("select") }
}

@MainActor enum FnSystemAction {
    struct Reapplied {
        var usageFixed = false
        var previousUsage: Int?
        var dictationFixed = false
        var any: Bool { usageFixed || dictationFixed }
    }
    static var usage: Int? { Stub.usage }
    static var dictationOnDoubleFn: Bool { Stub.dictation }
    static func migrateKeepOff() { Stub.calls.append("migrateKeepOff") }
    static func reapplyAll() -> Reapplied { Stub.calls.append("reapplyAll"); return Reapplied() }
    static func restore(waitForSystem: Bool = false) { Stub.calls.append("restore") }
    @discardableResult static func disable() -> Bool { Stub.calls.append("disable"); return true }
    @discardableResult static func disableDictation() -> Bool { Stub.calls.append("disableDictation"); return true }
    @discardableResult static func disableAll() -> Bool { Stub.calls.append("disableAll"); return true }

    /// Копия подписей настоящего `FnSystemAction.title`: сравнение «до и после» её одинаково видит с обеих сторон.
    nonisolated static func title(for usage: Int?) -> String {
        switch usage {
        case 0: return "Ничего не делает"
        case 1: return "Переключает раскладку"
        case 2: return "Показывает эмодзи"
        case 3: return "Запускает диктовку"
        case nil: return "По умолчанию в macOS"
        default: return "Другое действие"
        }
    }
}

enum SecureInput {
    static func owner() -> String? { nil }
}

@MainActor final class AccessState {
    static let shared = AccessState()
    func refresh() { Stub.calls.append("access.refresh") }
}
