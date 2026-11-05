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
enum DSTheme: Hashable, Identifiable {
    /// Сумерки: голубой, индиго и золото на тёмно-синем фоне. Тема по умолчанию; считается как «Своя» с палитрой `.dusk`.
    case dusk
    /// Приглушённые оттенки модулей.
    case calm
    /// Почти монохромная: нейтральный серый, один общий акцент системы.
    case graphite
    /// Насыщеннее, ближе к прототипу B.
    case vivid
    /// Глубокий сине-фиолетовый фон для всех; оттенок модуля — только у значка и главной кнопки.
    case midnight
    /// Своя палитра: оттенки трёх категорий, насыщенность и яркость фона задаёт пользователь.
    case custom(CustomPalette)

    var id: String { rawValue }
    static let storageKey = "Design.Theme"
    /// Готовые темы (без «Своей»).
    static let presets: [DSTheme] = [.dusk, .calm, .graphite, .vivid, .midnight]

    var rawValue: String {
        switch self {
        case .dusk: return "dusk"
        case .calm: return "calm"
        case .graphite: return "graphite"
        case .vivid: return "vivid"
        case .midnight: return "midnight"
        case .custom: return "custom"
        }
    }

    /// Только пресеты: у «Своей» есть палитра, её подставляет `DSThemed`.
    init?(rawValue: String) {
        switch rawValue {
        case "dusk": self = .dusk
        case "calm": self = .calm
        case "graphite": self = .graphite
        case "vivid": self = .vivid
        case "midnight": self = .midnight
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .dusk: return "Сумерки"
        case .calm: return "Спокойная"
        case .graphite: return "Графит"
        case .vivid: return "Цветная"
        case .midnight: return "Полночь"
        case .custom: return "Своя"
        }
    }

    // MARK: Параметры

    /// Насыщенность и яркость акцента модуля.
    fileprivate var accentSB: (s: Double, b: Double) {
        switch self {
        case .dusk: return DSTheme.custom(.dusk).accentSB
        case .calm: return (0.50, 0.82)
        case .graphite: return (0.20, 0.72)
        case .vivid: return (0.72, 0.98)
        case .midnight: return (0.52, 0.88)
        case .custom(let p): return (0.10 + 0.80 * p.sat, 0.70 + 0.28 * p.sat)
        }
    }

    /// Градиент фона окна (сверху вниз) для модуля.
    func background(_ m: Module) -> [Color] {
        switch self {
        case .dusk: return DSTheme.custom(.dusk).background(m)
        case .calm: return [hsb(m, 0.46, 0.27), hsb(m, 0.42, 0.10)]
        case .vivid: return [hsb(m, 0.74, 0.43), hsb(m, 0.72, 0.13)]
        case .graphite: return [Color(white: 0.15), Color(white: 0.085)]
        case .midnight: return [Color(hue: 0.69, saturation: 0.55, brightness: 0.25),
                                Color(hue: 0.72, saturation: 0.62, brightness: 0.09)]
        case .custom(let p):
            // Верх не ярче потолка: белый текст остаётся читаемым при любом оттенке.
            let b = p.backgroundBrightness
            let s = 0.05 + 0.85 * p.sat
            let h = hue(m)
            return [Color(hue: h, saturation: s, brightness: b),
                    Color(hue: h, saturation: s * 0.9, brightness: b * 0.37)]
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
        return hsb(m, accentSB.s, accentSB.b)
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
        case .dusk: return DSTheme.custom(.dusk).badge(m)
        case .graphite: return hsb(m, 0.36, 0.64)
        case .midnight, .calm: return hsb(m, 0.50, 0.78)
        case .vivid: return hsb(m, 0.75, 0.95)
        case .custom(let p): return hsb(m, 0.15 + 0.70 * p.sat, 0.78)
        }
    }

    /// Цвет текста и значка на заливке акцентом.
    var onAccent: Color { self == .graphite ? .white : Color.black.opacity(0.78) }

    /// Оттенок модуля (0…1): из таблицы `ModuleCategory.all`, а у «Своей» — из её палитры.
    func hue(_ m: Module) -> Double {
        if self == .dusk { return DSTheme.custom(.dusk).hue(m) }
        if case .custom(let p) = self { return p.hue(of: m) }
        return m.categoryHue
    }

    /// Оттенок категории (метка в панели, заголовки групп).
    func hue(_ c: ModuleCategory) -> Double {
        if self == .dusk { return DSTheme.custom(.dusk).hue(c) }
        if case .custom(let p) = self { return p.hue(of: c) }
        return c.hue
    }

    fileprivate func hsb(_ m: Module, _ s: Double, _ b: Double) -> Color {
        Color(hue: hue(m), saturation: s, brightness: b)
    }

    /// Образец оттенка в редакторе «Своей»: так акцент выглядит в интерфейсе.
    func swatch(hue: Double) -> Color { Color(hue: hue, saturation: accentSB.s, brightness: accentSB.b) }
}

// MARK: - Своя палитра

/// Настройки «Своей» темы: оттенок на категорию (ключ — `ModuleCategory.id`) и два общих числа 0…1.
struct CustomPalette: Hashable {
    var hues: [String: Double]
    /// Насыщенность акцентов и фона.
    var sat: Double
    /// Яркость фона: 0 — почти чёрный, 1 — приглушённый (потолок читаемости).
    var bright: Double

    /// Потолок яркости верха фона: даже серый 0,42 даёт белому тексту контраст больше 5, цветной ещё темнее.
    static let maxBackground = 0.42

    var backgroundBrightness: Double { min(Self.maxBackground, 0.12 + 0.30 * bright.clamped01) }

    func hue(of c: ModuleCategory) -> Double { hues[c.id] ?? c.hue }
    func hue(of m: Module) -> Double { m.category.hue(of: m, base: hue(of: m.category)) }

    /// «Сумерки»: палитра, на которой сидит пользователь (насыщенность и яркость фона — как были на ползунках).
    static let dusk = CustomPalette(hues: ["background": 0.55, "handy": 0.66, "ai": 0.11],
                                    sat: 0.5653, bright: 0.3487)

    /// Значения, при которых «Своя» выглядит как пресет (оттенки — штатные).
    static func from(_ preset: DSTheme) -> CustomPalette {
        let (sat, bright): (Double, Double)
        switch preset {
        case .graphite: (sat, bright) = (0.0, 0.1)
        case .vivid: (sat, bright) = (0.8, 1.0)
        case .midnight: (sat, bright) = (0.55, 0.43)
        case .custom(let p): return p
        case .dusk: return .dusk
        case .calm: (sat, bright) = (0.5, 0.5)
        }
        return CustomPalette(hues: [:], sat: sat, bright: bright)
    }
}

private extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

/// Хранит палитру в UserDefaults (по ключу на категорию + насыщенность и яркость) и рассылает изменения.
/// Пишут сюда только по отпусканию ползунка, поэтому интерфейс пересобирается редко.
@MainActor
final class CustomPaletteStore: ObservableObject {
    static let shared = CustomPaletteStore()
    private static let satKey = "Design.Custom.Sat"
    private static let brightKey = "Design.Custom.Bright"
    private static func hueKey(_ c: ModuleCategory) -> String { "Design.Custom.Hue." + c.id }
    /// Пресет, выбранный до «Своей»: к нему возвращает «Сбросить».
    static let lastPresetKey = "Design.LastPreset"

    @Published private(set) var palette: CustomPalette

    /// Настраивали ли «Свою» раньше.
    var isSaved: Bool { UserDefaults.standard.object(forKey: Self.satKey) != nil }

    private init() {
        let d = UserDefaults.standard
        var hues: [String: Double] = [:]
        for c in ModuleCategory.all { if let h = d.object(forKey: Self.hueKey(c)) as? Double { hues[c.id] = h } }
        let base = CustomPalette.from(.calm)
        palette = CustomPalette(hues: hues,
                                sat: d.object(forKey: Self.satKey) as? Double ?? base.sat,
                                bright: d.object(forKey: Self.brightKey) as? Double ?? base.bright)
    }

    func set(_ new: CustomPalette) {
        guard new != palette else { return }
        let d = UserDefaults.standard
        for c in ModuleCategory.all { d.set(new.hue(of: c), forKey: Self.hueKey(c)) }
        d.set(new.sat, forKey: Self.satKey)
        d.set(new.bright, forKey: Self.brightKey)
        palette = new
    }

    /// Последний выбранный пресет (по умолчанию «Сумерки»).
    static var lastPreset: DSTheme {
        DSTheme(rawValue: UserDefaults.standard.string(forKey: lastPresetKey) ?? "") ?? .dusk
    }
}

extension DSTheme {
    /// Цвет категории: метка у заголовка в панели и в «О проекте». У «Графита» приглушён, но отличим.
    func categoryColor(_ c: ModuleCategory) -> Color {
        let p: (s: Double, b: Double) = self == .graphite ? (0.42, 0.80) : accentSB
        return Color(hue: hue(c), saturation: p.s, brightness: p.b)
    }

    /// Цвет модуля там, где «Графит» всё равно должен выдать категорию (точка «включён» в панели).
    func tone(_ m: Module) -> Color {
        self == .graphite ? hsb(m, 0.40, 0.80) : accent(m)
    }
}

// MARK: - Окружение

private struct DSThemeKey: EnvironmentKey { static let defaultValue = DSTheme.dusk }
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
    @AppStorage(DSTheme.storageKey) private var raw = DSTheme.dusk.rawValue
    @ObservedObject private var custom = CustomPaletteStore.shared
    private var theme: DSTheme {
        raw == "custom" ? .custom(custom.palette) : DSTheme(rawValue: raw) ?? .dusk
    }
    func body(content: Content) -> some View {
        content
            .environment(\.dsTheme, theme)
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
