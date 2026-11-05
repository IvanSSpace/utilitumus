import SwiftUI

/// Настройки модулей (Cmd+, и «Настроить модули»): лист поверх главного окна.
struct ClassicSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ClassicModulesSettings()
            Divider()
            ClassicUIStyleSection()
            Divider()
            ClassicDockSection()
            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// «Интерфейс»: классический или новый. Стиль окна на лету не меняется — после выбора предлагаем перезапуск.
private struct ClassicUIStyleSection: View {
    @AppStorage(UIStyle.storageKey) private var raw = UIStyle.classic.rawValue

    private var style: Binding<UIStyle> {
        Binding(get: { UIStyle(rawValue: raw) ?? .classic }, set: { raw = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Интерфейс").fontWeight(.medium)
                    Text("Новый — в разработке").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SegmentedControl(UIStyle.allCases, selection: style) { $0.title }
                    .frame(width: 220)
            }
            UIStyleRestartNote(style: style.wrappedValue)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

private struct ClassicModulesSettings: View {
    @ObservedObject var manager = ModuleManager.shared

    /// Высоту строки задаём сами: List внутри окна с fixedSize не знает своей высоты.
    private let rowHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Модули").font(.title2.weight(.semibold))
                Text("Включай только нужные — выключенный ничего не делает и не ест ресурсы.")
                    .foregroundStyle(.secondary)
            }

            // Не Form: `.onMove` внутри Form `.grouped` на macOS не срабатывает, а в List — штатный путь.
            List {
                ForEach(manager.order) { module in
                    row(module)
                        .frame(height: rowHeight)
                }
                .onMove { manager.move(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollDisabled(true)
            .frame(height: CGFloat(manager.order.count) * (rowHeight + 9) + 10)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                legend("switch.2", "работает")
                legend("eye", "в боковой панели")
                legend("line.3.horizontal", "перетащи — порядок")
                Spacer()
                Button("Сбросить") { manager.resetAll() }
                    .buttonStyle(.link)
                    .help("Порядок по умолчанию, все модули снова в боковой панели. Включённость не меняется")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
    }

    private func row(_ module: Module) -> some View {
        let on = manager.isOn(module)
        let hidden = manager.isHidden(module)
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ClassicModuleIconBadge(module: module, size: 30)
                .saturation(on ? 1 : 0.3)
                .opacity(on ? 1 : 0.7)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).fontWeight(.medium)
                Text(module.info.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .foregroundStyle(hidden ? .tertiary : .secondary)
            .help(hidden ? "Скрыт из боковой панели — показать" : "В боковой панели — скрыть")
            Toggle(module.title, isOn: Binding(get: { on }, set: { manager.setOn(module, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
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
