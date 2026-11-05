import Foundation

/// Режим выбора следующей раскладки.
enum LayoutMode: String, CaseIterable {
    case lastTwo, cycle
    var title: String { self == .lastTwo ? "Между двумя последними" : "По кругу" }
}

/// Какую раскладку включить следом. Чистая логика, id раскладок — строки.
struct LayoutPicker {
    var mode: LayoutMode = .lastTwo
    /// Раскладка, которая была до текущей.
    private(set) var previous: String?
    private(set) var current: String?

    /// Систему переключили (мы или пользователь): помним, с чего ушли.
    mutating func didChange(to id: String) {
        guard id != current else { return }
        previous = current
        current = id
    }

    /// Следующая раскладка из списка включённых (в системном порядке). nil — переключать некуда.
    func next(in enabled: [String]) -> String? {
        guard enabled.count > 1 else { return nil }
        if mode == .lastTwo, let previous, previous != current, enabled.contains(previous) { return previous }
        guard let current, let index = enabled.firstIndex(of: current) else { return enabled.first }
        return enabled[(index + 1) % enabled.count]
    }
}

/// Что делать после `TISSelectInputSource`, когда прочитали раскладку через ~80 мс.
enum SwitchCheck: Equatable {
    case done, retry, failed

    static func after(target: String, actual: String?, retried: Bool) -> SwitchCheck {
        if actual == target { return .done }
        return retried ? .failed : .retry
    }
}

/// Что делать с event tap по итогам дешёвой проверки.
enum TapHealth: Equatable {
    case ok, reenable, rebuild

    /// `valid` — CFMachPortIsValid, `enabled` — CGEvent.tapIsEnabled.
    static func check(valid: Bool, enabled: Bool) -> TapHealth {
        if !valid { return .rebuild }
        return enabled ? .ok : .reenable
    }
}
