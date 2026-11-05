import SwiftUI

/// Настройки приложения (Cmd+, и «Настройки» в боковой панели): лист поверх главного окна.
/// Установка и удаление модулей — в Сторе, порядок — перетаскиванием в боковой панели.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dsTheme) private var theme
    @AppStorage("SelectedModule") private var selection: Module = .sound

    var body: some View {
        ZStack {
            DSBackground(module: selection)
            VStack(alignment: .leading, spacing: DS.blockSpacing) {
                HStack(spacing: 14) {
                    Text("Настройки").font(DS.pageTitle)
                    Spacer(minLength: 12)
                    DSButton("Готово", style: .primary) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                // Шапка с «Готово» стоит на месте, остальное прокручивается внутри листа,
                // если окно меньше содержимого.
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.blockSpacing) {
                        ThemeSection()
                        DockSection()
                        PageModeSection()
                    }
                }
                .scrollIndicators(.automatic)
            }
            .padding(DS.pagePadding)
        }
        .environment(\.dsTint, theme.accent(selection))
        // Высота по трём разделам с запасом; меньше минимальной высоты окна (540), поэтому лист всегда помещается,
        // а при нехватке места прокручивается ScrollView внутри.
        .frame(width: 600, height: 440)
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
