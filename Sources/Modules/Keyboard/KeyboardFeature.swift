import Foundation

/// Фишка модуля «Клавиатура»: отдельная возможность со своим переключателем, настройками и шагами настройки.
/// Модуль включён — работают включённые фишки; ресурсы (tap, наблюдатели) поднимаются только под них.
enum KeyboardFeature: String, CaseIterable, Identifiable {
    case fnLanguage, perAppLayout, capsLock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fnLanguage: return "Язык по Fn"
        case .perAppLayout: return "Раскладка для каждого приложения"
        case .capsLock: return "Caps Lock — смена языка"
        }
    }

    /// Одна строка «что делает».
    var tagline: String {
        switch self {
        case .fnLanguage: return "Тап по Fn/🌐 меняет язык сразу, без паузы macOS"
        case .perAppLayout: return "Помнит язык в каждом приложении и возвращает его при переключении"
        case .capsLock: return "Мгновенно, без задержки macOS"
        }
    }

    var icon: String {
        switch self {
        case .fnLanguage: return "globe"
        case .perAppLayout: return "square.on.square"
        case .capsLock: return "capslock.fill"
        }
    }

    /// Фишка уже работает; «Скоро» — карточка без переключателя.
    var isAvailable: Bool { self != .capsLock }

    /// Короткая подпись в строке статуса на дашборде.
    var shortName: String {
        switch self {
        case .fnLanguage: return "Fn"
        case .perAppLayout: return "по приложениям"
        case .capsLock: return "Caps Lock"
        }
    }

    private var key: String { "Keyboard.Feature.\(rawValue)" }

    /// Включена ли. Миграция: до появления фишек модуль «Клавиатура» умел только Fn,
    /// поэтому «Язык по Fn» без записи считается включённым — у кого модуль был включён, всё работает как раньше.
    var isOn: Bool {
        get {
            guard isAvailable else { return false }
            let defaults = UserDefaults.standard
            if defaults.object(forKey: key) == nil { return self == .fnLanguage }
            return defaults.bool(forKey: key)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Включённые фишки в порядке экрана.
    static var enabled: [KeyboardFeature] { allCases.filter(\.isOn) }
}
