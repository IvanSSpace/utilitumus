import SwiftUI

// Компоненты дизайн-системы. Экран модуля собирается так:
//
//   DSPage(module: .stash, primary: DSAction("Закрыть всё", icon: "bolt.fill") { stash() }) {
//       DSSection("Программы", trailing: "3 выбрано") {
//           DSRow(icon: "gamecontroller.fill", title: "Steam", subtitle: "Закрывается перед игрой") {
//               DSChip("Тяжёлая", color: .orange)
//               DSToggle(isOn: $steam)
//           }
//           DSRow(title: "Горячая клавиша") { DSKeyCaps("⌃⌥Space") }
//       }
//       DSSection("Режим") { DSRow(title: "Вид") { DSSegmented(modes, selection: $mode) { $0.title } } }
//   }
//
// Страницу в карточку, фон окна и переход между модулями делает окно — в экране об этом заботиться не нужно.

// MARK: - Наведение

private struct HoverFill<S: Shape>: ViewModifier {
    let shape: S
    let normal: Color
    let hovered: Color
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .contentShape(shape)
            .background(shape.fill(hover ? hovered : normal))
            .onHover { hover = $0 }
    }
}

extension View {
    /// Фон формы, который мгновенно (без анимации) меняется при наведении. Состояние наведения живёт
    /// в самом модификаторе: родитель и содержимое при этом не пересобираются.
    func hoverFill<S: Shape>(_ shape: S, normal: Color, hovered: Color) -> some View {
        modifier(HoverFill(shape: shape, normal: normal, hovered: hovered))
    }
}

// MARK: - Кнопки

/// Главное действие страницы: подпись, значок, замыкание. Показывается капсулой в шапке.
struct DSAction {
    let title: String
    var icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }
}

enum DSButtonStyleKind {
    /// Заливка акцентом модуля — одна на страницу.
    case primary
    /// Серая капсула.
    case secondary
    /// Без фона, с подсветкой при наведении.
    case plain
}

/// Кнопка-капсула. `small: true` — компактная (в строках и шапке).
struct DSButton: View {
    let title: String
    var icon: String?
    var style: DSButtonStyleKind
    var small: Bool
    let action: () -> Void

    init(_ title: String, icon: String? = nil, style: DSButtonStyleKind = .secondary, small: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.small = small
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: small ? 11 : 12.5, weight: .bold)) }
                if !title.isEmpty { Text(title).font(.system(size: small ? 12 : 13.5, weight: .semibold)) }
            }
        }
        .buttonStyle(DSCapsuleStyle(kind: style, small: small))
        .focusEffectDisabled()
    }
}

private struct DSCapsuleStyle: ButtonStyle {
    let kind: DSButtonStyleKind
    let small: Bool
    @Environment(\.dsTint) private var tint
    @Environment(\.dsTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 11 : 17)
            .padding(.vertical, small ? 5 : 9)
            .background(Capsule().fill(fill(pressed: pressed)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hover = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return theme.onAccent
        case .secondary: return .white.opacity(0.92)
        case .plain: return .white.opacity(hover ? 0.95 : 0.7)
        }
    }

    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary: return tint.opacity(pressed ? 0.75 : (hover ? 0.92 : 1))
        case .secondary: return .white.opacity(pressed ? 0.2 : (hover ? 0.15 : 0.1))
        case .plain: return .white.opacity(pressed ? 0.12 : (hover ? 0.08 : 0))
        }
    }
}

// MARK: - Мелкие контролы

/// Переключатель с акцентом модуля.
struct DSToggle: View {
    @Binding var isOn: Bool
    var label: String

    /// `label` не виден, но нужен VoiceOver.
    init(_ label: String = "", isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    @Environment(\.dsTint) private var tint
    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(tint)
    }
}

/// Сегменты. Обёртка над `SegmentedControl` (NSSegmentedControl): `Picker(.segmented)` не использовать —
/// он течёт памятью на macOS 26.
struct DSSegmented<Value: Hashable>: View {
    let items: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    init(_ items: [Value], selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.items = items
        self._selection = selection
        self.title = title
    }

    var body: some View {
        SegmentedControl(items, selection: $selection, title: title)
            .controlSize(.small)
    }
}

/// Маленькая плашка: «Тяжёлая», «Активна».
struct DSChip: View {
    let text: String
    var color: Color
    var icon: String?

    init(_ text: String, color: Color = .secondary, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// Горячая клавиша клавишами: `DSKeyCaps("⌃⌥Space")` → [⌃] [⌥] [Space].
struct DSKeyCaps: View {
    let keys: [String]

    init(_ combo: String) {
        let symbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "⎋", "⏎", "⇥", "⌫"]
        var result: [String] = []
        var word = ""
        for ch in combo {
            if symbols.contains(ch) {
                if !word.isEmpty { result.append(word); word = "" }
                result.append(String(ch))
            } else if ch == " " {
                if !word.isEmpty { result.append(word); word = "" }
            } else {
                word.append(ch)
            }
        }
        if !word.isEmpty { result.append(word) }
        keys = result
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.7))
            }
        }
    }
}

// MARK: - Секция и строка

/// Блок страницы: заголовок капсом мелко (+ подпись справа) и карточка со строками `DSRow`.
/// Между `DSRow` тонкие разделители рисуют сами строки.
struct DSSection<Content: View>: View {
    let title: String
    var trailing: String?
    /// Цвет категории: метка перед названием (страница «О проекте»).
    var mark: Color?
    @ViewBuilder var content: Content
    @Environment(\.dsTheme) private var theme

    init(_ title: String, trailing: String? = nil, mark: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.mark = mark
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let mark {
                    Capsule().fill(mark).frame(width: 3, height: 12)
                }
                Text(title.uppercased()).font(DS.sectionTitle).tracking(0.8)
                    .foregroundStyle(mark == nil ? .white.opacity(0.42) : .white.opacity(0.7))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 6)
            // Верхний разделитель первой строки уезжает на 1 pt выше и обрезается скруглением.
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, -1)
                .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
                .clipShape(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.7))
        }
    }
}

/// Строка в `DSSection`: значок в квадрате, заголовок, подзаголовок, справа любой контрол.
struct DSRow<Trailing: View>: View {
    var icon: String?
    let title: String
    var subtitle: String?
    /// Свой цвет значка (гамма категории); без него — акцент текущего модуля.
    var iconTint: Color?
    @ViewBuilder var trailing: Trailing
    @Environment(\.dsTint) private var envTint

    init(icon: String? = nil, title: String, subtitle: String? = nil, iconTint: Color? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.iconTint = iconTint
        self.trailing = trailing()
    }

    private var tint: Color { iconTint ?? envTint }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.18))
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                if let subtitle {
                    Text(subtitle).font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 50)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, icon == nil ? 14 : 56)
        }
    }
}

extension DSRow where Trailing == EmptyView {
    init(icon: String? = nil, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Страница

/// Есть ли внутри экрана модуля `DSPage`. Пока нет, `ModuleScreen` рисует компактную полоску с кнопками.
struct DSPageKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Страница модуля: скролл, шапка (значок, название, строка, главная кнопка, «Как это работает», «Включён»)
/// и содержимое. Саму карточку со скруглением рисует окно.
struct DSPage<Content: View>: View {
    let module: Module
    var subtitle: String?
    var primary: DSAction?
    var controls: Bool
    @ViewBuilder var content: Content
    @Environment(\.dsTheme) private var theme

    /// - Parameters:
    ///   - subtitle: одна строка под названием; по умолчанию — короткое описание модуля.
    ///   - primary: главная кнопка страницы (одна).
    ///   - controls: показывать «Как это работает» и переключатель «Включён».
    init(module: Module, subtitle: String? = nil, primary: DSAction? = nil, controls: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.module = module
        self.subtitle = subtitle
        self.primary = primary
        self.controls = controls
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.blockSpacing) {
                DSPageHeader(module: module, subtitle: subtitle, primary: primary, controls: controls)
                content
            }
            .padding(DS.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.dsTint, theme.accent(module))
        .preference(key: DSPageKey.self, value: true)
    }
}

/// Страница не из модуля («О проекте», настройки): та же шапка со своим значком.
struct DSPlainPage<Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var primary: DSAction?
    @ViewBuilder var content: Content

    init(icon: String, title: String, subtitle: String? = nil, primary: DSAction? = nil,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.primary = primary
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.blockSpacing) {
                DSHeaderLayout(title: title, subtitle: subtitle, primary: primary,
                               badge: { DSBadge(icon: icon) }, controls: { EmptyView() })
                content
            }
            .padding(DS.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Шапка страницы модуля. Отдельно от `DSPage`, если нужна вне скролла.
struct DSPageHeader: View {
    let module: Module
    var subtitle: String?
    var primary: DSAction?
    var controls = true

    var body: some View {
        DSHeaderLayout(title: module.title, subtitle: subtitle ?? module.info.tagline, primary: primary,
                       badge: { ModuleIconBadge(module: module, size: 50) },
                       controls: { if controls { DSModuleControls(module: module) } })
    }
}

/// «Как это работает» и переключатель «Включён» модуля.
struct DSModuleControls: View {
    let module: Module
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        let on = modules.isOn(module)
        HStack(spacing: 10) {
            DSButton("Как это работает", icon: "info.circle", style: .plain, small: true) { modules.infoModule = module }
                .help("Что умеет модуль и как им пользоваться")
            HStack(spacing: 7) {
                Text(on ? "Включён" : "Выключен")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.85 : 0.5))
                DSToggle("Модуль включён", isOn: Binding(get: { on }, set: { modules.setOn(module, $0) }))
            }
            .help(on ? "Выключить: модуль остановится полностью" : "Включить модуль")
        }
    }
}

private struct DSBadge: View {
    let icon: String
    @Environment(\.dsTint) private var tint
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.85))
            .frame(width: 50, height: 50)
            .overlay(Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct DSHeaderLayout<Badge: View, Controls: View>: View {
    let title: String
    var subtitle: String?
    var primary: DSAction?
    @ViewBuilder var badge: Badge
    @ViewBuilder var controls: Controls

    init(title: String, subtitle: String?, primary: DSAction?,
         @ViewBuilder badge: () -> Badge, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.primary = primary
        self.badge = badge()
        self.controls = controls()
    }

    var body: some View {
        HStack(spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.pageTitle).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                controls
                if let primary { DSButton(primary.title, icon: primary.icon, style: .primary, action: primary.action) }
            }
            .fixedSize()
        }
    }
}
