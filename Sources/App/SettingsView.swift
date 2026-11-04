import SwiftUI

/// Окно настроек (Cmd+,): раздел «Модули».
struct SettingsView: View {
    var body: some View {
        TabView {
            ModulesSettings()
                .tabItem { Label("Модули", systemImage: "square.grid.2x2") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ModulesSettings: View {
    @ObservedObject var manager = ModuleManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(Module.allCases) { module in
                    HStack(spacing: 12) {
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
                        Toggle(module.title, isOn: Binding(
                            get: { manager.isEnabled(module) },
                            set: { manager.setEnabled(module, $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            } footer: {
                Text("Выключенный модуль пропадает из боковой панели и перестаёт работать в фоне.")
            }
        }
        .formStyle(.grouped)
    }
}
