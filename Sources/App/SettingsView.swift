import SwiftUI

/// Окно настроек (Cmd+,): раздел «Модули».
struct SettingsView: View {
    var body: some View {
        TabView {
            ModulesSettings()
                .tabItem { Label("Модули", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ModulesSettings: View {
    @ObservedObject var manager = ModuleManager.shared

    /// Высота строки задаём сами: List внутри окна с fixedSize не знает своей высоты.
    private let rowHeight: CGFloat = 54

    var body: some View {
        // Не Form: `.onMove` внутри Form `.grouped` на macOS не срабатывает, а в List — штатный путь.
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(manager.order) { module in
                    HStack(spacing: 12) {
                        ModuleIconBadge(module: module, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.title)
                            Text(module.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            manager.setHidden(module, !manager.isHidden(module))
                        } label: {
                            Image(systemName: manager.isHidden(module) ? "eye.slash" : "eye")
                                .frame(width: 20)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(manager.isHidden(module) ? .secondary : .primary)
                        .help(manager.isHidden(module) ? "Скрыт из боковой панели — показать" : "В боковой панели — скрыть")
                        Toggle(module.title, isOn: Binding(
                            get: { manager.isOn(module) },
                            set: { manager.setOn(module, $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(manager.isOn(module) ? "Включён — выключить" : "Выключен — включить")
                    }
                    .frame(height: rowHeight)
                }
                .onMove { manager.move(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .scrollDisabled(true)
            .frame(height: CGFloat(manager.order.count) * (rowHeight + 8) + 8)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            Text("Переключатель включает модуль, глаз — показывает в боковой панели (скрытый работает в фоне). Порядок — перетаскиванием.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Сбросить порядок и показать всё") { manager.resetAll() }
        }
        .padding(20)
    }
}
