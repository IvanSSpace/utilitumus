import SwiftUI

// Дизайн-система Utilitumus: цвета, радиусы, отступы, шрифты.
//
// Тему выбирают в «Настроить модули» → «Тема» (UserDefaults "Design.Theme"), применяется сразу.
// Компоненты (`DSPage`, `DSRow`, `DSButton` …) сами берут цвета из окружения:
//   `@Environment(\.dsTheme)` — выбранная тема, `@Environment(\.dsTint)` — акцент текущего модуля.
// В экране модуля свои цвета не нужны. Нужен акцентный цвет — `@Environment(\.dsTint) private var tint`.
// Окружение выставляют `MainView` и листы через `.dsThemed()`; в экранах модулей ничего подключать не надо.

// MARK: - Тема

/// Цветовая тема окна. Все цвета считаются от модуля, чтобы тема сама решала, красить ли в его оттенок.
enum DSTheme: String, CaseIterable, Identifiable {
    /// Приглушённые оттенки модулей (по умолчанию).
    case calm
    /// Почти монохромная: нейтральный серый, один общий акцент системы.
    case graphite
    /// Насыщеннее, ближе к прототипу B.
    case vivid
    /// Глубокий сине-фиолетовый фон для всех; оттенок модуля — только у значка и главной кнопки.
    case midnight

    var id: String { rawValue }
    static let storageKey = "Design.Theme"

    var title: String {
        switch self {
        case .calm: return "Спокойная"
        case .graphite: return "Графит"
        case .vivid: return "Цветная"
        case .midnight: return "Полночь"
        }
    }

    // MARK: Параметры

    /// Насыщенность и яркость акцента модуля.
    private var accentSB: (s: Double, b: Double) {
        switch self {
        case .calm: return (0.50, 0.82)
        case .graphite: return (0.20, 0.72)
        case .vivid: return (0.72, 0.98)
        case .midnight: return (0.52, 0.88)
        }
    }

    /// Градиент фона окна (сверху вниз) для модуля.
    func background(_ m: Module) -> [Color] {
        switch self {
        case .calm: return [m.hsb(0.46, 0.27), m.hsb(0.42, 0.10)]
        case .vivid: return [m.hsb(0.74, 0.43), m.hsb(0.72, 0.13)]
        case .graphite: return [Color(white: 0.15), Color(white: 0.085)]
        case .midnight: return [Color(hue: 0.69, saturation: 0.55, brightness: 0.25),
                                Color(hue: 0.72, saturation: 0.62, brightness: 0.09)]
        }
    }

    /// Затемнение боковой панели поверх фона.
    var sidebar: Color { .black.opacity(self == .graphite ? 0.16 : 0.2) }

    /// Заливка страницы-карточки.
    var card: Color { Color.black.opacity(0.30) }

    /// Заливка группы строк внутри карточки.
    var group: Color { .white.opacity(0.055) }

    /// Акцент модуля: главная кнопка, переключатели, активные контролы.
    func accent(_ m: Module) -> Color {
        if self == .graphite { return Color.accentColor }
        return m.hsb(accentSB.s, accentSB.b)
    }

    /// Мягкая подложка акцента: значки в строках, чипы.
    func accentSoft(_ m: Module) -> Color { accent(m).opacity(0.18) }

    /// Заливка выбранной строки боковой панели.
    func selection(_ m: Module) -> Color {
        switch self {
        case .midnight: return .white.opacity(0.13)
        case .graphite: return Color.accentColor.opacity(0.30)
        default: return accent(m).opacity(0.26)
        }
    }

    /// Плашка значка модуля: у «Графита» приглушена, чтобы значки не пестрили.
    func badge(_ m: Module) -> Color {
        switch self {
        case .graphite: return m.hsb(0.22, 0.62)
        case .midnight, .calm: return m.hsb(0.50, 0.78)
        case .vivid: return m.hsb(0.75, 0.95)
        }
    }

    /// Цвет текста и значка на заливке акцентом.
    var onAccent: Color { self == .graphite ? .white : Color.black.opacity(0.78) }

    /// Три цвета для предпросмотра в настройках: фон сверху, фон снизу, акцент.
    var preview: [Color] { [background(.voice)[0], background(.voice)[1], accent(.voice)] }
}

extension Module {
    /// Базовый оттенок модуля (0…1) и множитель насыщенности для серых.
    fileprivate var dsHue: (h: Double, k: Double) {
        switch self {
        case .sound: return (0.58, 1)
        case .load: return (0.07, 1)
        case .stash: return (0.76, 1)
        case .fans: return (0.51, 1)
        case .mixer: return (0.92, 1)
        case .mouse: return (0.60, 0.18)
        case .browser: return (0.66, 1)
        case .voice: return (0.39, 1)
        }
    }

    fileprivate func hsb(_ s: Double, _ b: Double) -> Color {
        let p = dsHue
        return Color(hue: p.h, saturation: s * p.k, brightness: b)
    }
}

// MARK: - Окружение

private struct DSThemeKey: EnvironmentKey { static let defaultValue = DSTheme.calm }
private struct DSTintKey: EnvironmentKey { static let defaultValue = Color.accentColor }

extension EnvironmentValues {
    /// Выбранная цветовая тема.
    var dsTheme: DSTheme {
        get { self[DSThemeKey.self] }
        set { self[DSThemeKey.self] = newValue }
    }
    /// Акцент текущего модуля в текущей теме.
    var dsTint: Color {
        get { self[DSTintKey.self] }
        set { self[DSTintKey.self] = newValue }
    }
}

private struct DSThemed: ViewModifier {
    @AppStorage(DSTheme.storageKey) private var raw = DSTheme.calm.rawValue
    func body(content: Content) -> some View {
        content
            .environment(\.dsTheme, DSTheme(rawValue: raw) ?? .calm)
            .preferredColorScheme(.dark)
    }
}

extension View {
    /// Подключает выбранную тему и тёмное оформление. Нужно один раз на корень окна и на каждый лист.
    func dsThemed() -> some View { modifier(DSThemed()) }
}

// MARK: - Размеры

/// Радиусы, отступы и шрифты. Числа в одном месте, чтобы экраны выглядели одинаково.
enum DS {
    static let cardRadius: CGFloat = 22
    static let groupRadius: CGFloat = 16
    static let rowRadius: CGFloat = 11
    /// Поле карточки страницы.
    static let pagePadding: CGFloat = 26
    /// Расстояние между блоками страницы.
    static let blockSpacing: CGFloat = 20
    static let sidebarWidth: CGFloat = 232

    static let sectionTitle = Font.system(size: 10.5, weight: .semibold)
    static let rowTitle = Font.system(size: 13.5, weight: .medium)
    static let rowSubtitle = Font.system(size: 12)
    static let pageTitle = Font.system(size: 26, weight: .bold, design: .rounded)
}
