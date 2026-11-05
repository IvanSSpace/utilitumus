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
                ThemeSection()
                DockSection()
                UIStyleSection()
                PageModeSection()
                ModulesSettings()
            }
            .padding(DS.pagePadding)
        }
        .environment(\.dsTint, theme.accent(selection))
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
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

/// «Интерфейс»: классический (как до редизайна) или новый. Стиль окна сменить на лету нельзя — после выбора предлагаем перезапуск.
private struct UIStyleSection: View {
    @AppStorage(UIStyle.storageKey) private var raw = UIStyle.classic.rawValue

    private var style: Binding<UIStyle> {
        Binding(get: { UIStyle(rawValue: raw) ?? .classic }, set: { raw = $0.rawValue })
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
