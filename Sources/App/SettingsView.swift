import SwiftUI

/// Настройки модулей (Cmd+, и «Настроить модули»): лист поверх главного окна.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dsTheme) private var theme
    @AppStorage("SelectedModule") private var selection: Module = .sound

    var body: some View {
        ZStack {
            DSBackground(module: selection)
            VStack(alignment: .leading, spacing: DS.blockSpacing) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Модули").font(DS.pageTitle)
                        Text("Включай только нужные — выключенный ничего не делает и не ест ресурсы.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 12)
                    DSButton("Готово", style: .primary) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                // Разделов и модулей стало много: лист по высоте содержимого вылезал за окно.
                // Шапка с «Готово» стоит на месте, остальное прокручивается внутри листа.
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.blockSpacing) {
                        ThemeSection()
                        DockSection()
                        UIStyleSection()
                        PageModeSection()
                        ModulesSettings()
                    }
                }
                .scrollIndicators(.automatic)
            }
            .padding(DS.pagePadding)
        }
        .environment(\.dsTint, theme.accent(selection))
        // Меньше стандартного окна (693), чтобы лист целиком помещался поверх него.
        .frame(width: 600, height: 600)
    }
}

/// «Тема»: пять мини-окошек (четыре пресета и «Своя»), применяется сразу.
/// У «Своей» ниже раскрывается редактор палитры.
private struct ThemeSection: View {
    @AppStorage(DSTheme.storageKey) private var raw = DSTheme.calm.rawValue
    @ObservedObject private var store = CustomPaletteStore.shared
    @Environment(\.dsTint) private var tint
    /// Черновик: ползунки двигают его, в хранилище он уходит по отпусканию (и по тапу на образец).
    @State private var draft = CustomPaletteStore.shared.palette

    private static let hueChoices: [Double] = [0.00, 0.06, 0.11, 0.20, 0.33, 0.44, 0.55, 0.66, 0.80, 0.92]

    var body: some View {
        DSSection("Оформление") {
            HStack(alignment: .top, spacing: 0) {
                ForEach(DSTheme.presets) { theme in
                    Button { pick(theme) } label: { ThemePreview(theme: theme, selected: raw == theme.rawValue) }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                }
                Button { pickCustom() } label: { ThemePreview(theme: .custom(draft), selected: raw == "custom") }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12).padding(.horizontal, 4)
            if raw == "custom" { editor }
        }
        .onChange(of: store.palette) { _, new in if new != draft { draft = new } }
    }

    private func pick(_ theme: DSTheme) {
        raw = theme.rawValue
        UserDefaults.standard.set(theme.rawValue, forKey: CustomPaletteStore.lastPresetKey)
    }

    /// Первый раз «Своя» стартует с цветов выбранного пресета.
    private func pickCustom() {
        if !store.isSaved {
            draft = CustomPalette.from(CustomPaletteStore.lastPreset)
            store.set(draft)
        }
        raw = "custom"
    }

    private func commit() { store.set(draft) }

    // MARK: Редактор

    private var editor: some View {
        let probe = DSTheme.custom(draft)
        return VStack(spacing: 0) {
            ForEach(ModuleCategory.all) { category in
                DSRow(icon: category.icon, title: category.title, iconTint: probe.categoryColor(category)) {
                    HStack(spacing: 6) {
                        ForEach(Self.hueChoices, id: \.self) { hue in
                            hueDot(hue, probe: probe, category: category)
                        }
                    }
                }
            }
            DSRow(icon: "drop.fill", title: "Насыщенность", subtitle: "Общая для фона и акцентов") {
                Slider(value: $draft.sat, in: 0...1) { if !$0 { commit() } }
                    .tint(tint).frame(width: 200)
            }
            DSRow(icon: "sun.max.fill", title: "Яркость фона", subtitle: "От почти чёрного до приглушённого") {
                Slider(value: $draft.bright, in: 0...1) { if !$0 { commit() } }
                    .tint(tint).frame(width: 200)
            }
            DSRow(icon: "arrow.counterclockwise", title: "Как в пресете",
                  subtitle: "Вернуть цвета «\(CustomPaletteStore.lastPreset.title)»") {
                DSButton("Сбросить", style: .plain, small: true) {
                    draft = CustomPalette.from(CustomPaletteStore.lastPreset)
                    commit()
                }
            }
        }
    }

    private func hueDot(_ hue: Double, probe: DSTheme, category: ModuleCategory) -> some View {
        let current = draft.hue(of: category)
        let distance = abs(current - hue)
        let selected = min(distance, 1 - distance) < 0.045
        return Button {
            draft.hues[category.id] = hue
            commit()
        } label: {
            Circle().fill(probe.swatch(hue: hue))
                .frame(width: 16, height: 16)
                .padding(2)
                .overlay(Circle().stroke(.white.opacity(selected ? 0.95 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// «Интерфейс»: классический (как до редизайна) или новый. Стиль окна сменить на лету нельзя — после выбора предлагаем перезапуск.
private struct UIStyleSection: View {
    @AppStorage(UIStyle.storageKey) private var raw = UIStyle.new.rawValue

    private var style: Binding<UIStyle> {
        Binding(get: { UIStyle(rawValue: raw) ?? .new }, set: { raw = $0.rawValue })
    }

    var body: some View {
        DSSection("Интерфейс") {
            DSRow(icon: "macwindow", title: "Интерфейс", subtitle: "Новый — в разработке") {
                DSSegmented(UIStyle.allCases, selection: style) { $0.title }
                    .frame(width: 220)
            }
            if style.wrappedValue != UIStyle.launched {
                DSRow(icon: "arrow.triangle.2.circlepath", title: "Нужен перезапуск",
                      subtitle: "Интерфейс «\(style.wrappedValue.title)» включится после перезапуска") {
                    DSButton("Перезапустить сейчас", style: .primary, small: true) {
                        Updater.relaunch(Bundle.main.bundleURL)
                    }
                }
            }
        }
    }
}

/// «Страницы»: быстрый режим держит открытые экраны в памяти, экономный собирает экран при каждом открытии.
/// Применяется сразу: окно само переключается между двумя способами показа страницы.
private struct PageModeSection: View {
    @AppStorage(PageMode.storageKey) private var raw = PageMode.fast.rawValue

    private var mode: Binding<PageMode> {
        Binding(get: { PageMode(rawValue: raw) ?? .fast }, set: { raw = $0.rawValue })
    }

    var body: some View {
        DSSection("Страницы") {
            DSRow(icon: "bolt", title: "Режим страниц",
                  subtitle: mode.wrappedValue == .fast
                    ? "Открытые экраны остаются в памяти, переключение мгновенное, с плавным переходом"
                    : "Экран собирается при открытии, без перехода: меньше памяти") {
                DSSegmented(PageMode.allCases, selection: mode) { $0.title }
                    .frame(width: 220)
            }
        }
    }
}

private struct ModulesSettings: View {
    @ObservedObject var manager = ModuleManager.shared

    /// Высоту строки задаём сами: List внутри окна с fixedSize не знает своей высоты.
    private let rowHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DSSection("Модули", trailing: "перетащи — порядок") {
                // Не Form: `.onMove` внутри Form `.grouped` на macOS не срабатывает, а в List — штатный путь.
                List {
                    ForEach(manager.order) { module in
                        row(module)
                            .frame(height: rowHeight)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { manager.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(manager.order.count) * (rowHeight + 9) + 10)
            }

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                legend("switch.2", "работает")
                legend("eye", "в боковой панели")
                Spacer()
                DSButton("Сбросить", style: .plain, small: true) { manager.resetAll() }
                    .help("Порядок по умолчанию, все модули снова в боковой панели. Включённость не меняется")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func row(_ module: Module) -> some View {
        let on = manager.isOn(module)
        let hidden = manager.isHidden(module)
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
            ModuleIconBadge(module: module, size: 30)
                .saturation(on ? 1 : 0.3)
                .opacity(on ? 1 : 0.7)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(DS.rowTitle)
                Text(module.info.tagline)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .help(module.info.tagline)
            }
            Spacer(minLength: 8)
            Button {
                manager.setHidden(module, !hidden)
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(hidden ? 0.3 : 0.65))
            .help(hidden ? "Скрыт из боковой панели — показать" : "В боковой панели — скрыть")
            DSToggle(module.title, isOn: Binding(get: { on }, set: { manager.setOn(module, $0) }))
                .help(on ? "Включён — выключить" : "Выключен — включить")
        }
    }

    private func legend(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
    }
}
