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

    var body: some View {
        Form {
            Section {
                ForEach(manager.order) { module in
                    HStack(spacing: 12) {
                        // Ручка: строку можно перетащить, порядок общий с боковой панелью.
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                        Image(systemName: module.icon)
                            .font(.title3)
                            .frame(width: 28)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.title)
                            Text(module.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(module.title, selection: Binding(
                            get: { manager.state(of: module) },
                            set: { manager.setState(module, $0) }
                        )) {
                            ForEach(ModuleState.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .onMove { manager.move(from: $0, to: $1) }
            } footer: {
                Text("Порядок можно менять перетаскиванием, здесь и в боковой панели. Скрытый модуль пропадает из панели, но работает в фоне. Выключенный остановлен полностью.")
            }

            Section {
                Button("Сбросить порядок и показать всё") { manager.resetAll() }
            }
        }
        .formStyle(.grouped)
    }
}
