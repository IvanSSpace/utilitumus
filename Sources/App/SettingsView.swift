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

/// «Тема»: выбор цветовой темы, применяется сразу. Предпросмотр — кружок с фоном и точкой акцента.
private struct ThemeSection: View {
    @AppStorage(DSTheme.storageKey) private var raw = DSTheme.calm.rawValue

    var body: some View {
        DSSection("Оформление") {
            DSRow(icon: "paintpalette", title: "Тема", subtitle: "Цвета окна и боковой панели") {
                HStack(spacing: 14) {
                    ForEach(DSTheme.allCases) { theme in
                        Button { raw = theme.rawValue } label: { swatch(theme) }
                            .buttonStyle(.plain)
                            .help(theme.title)
                    }
                }
            }
        }
    }

    private func swatch(_ theme: DSTheme) -> some View {
        let selected = theme.rawValue == raw
        let colors = theme.preview
        return VStack(spacing: 4) {
            Circle()
                .fill(LinearGradient(colors: [colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 28, height: 28)
                .overlay(Circle().fill(colors[2]).frame(width: 10, height: 10).offset(x: 6, y: 6))
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.7))
                .padding(3)
                .overlay(Circle().stroke(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
            Text(theme.title)
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
        }
        .contentShape(Rectangle())
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
