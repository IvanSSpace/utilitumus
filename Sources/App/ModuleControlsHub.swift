import SwiftUI

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

extension DSModuleControls {
    /// Значение для `\.moduleControls`: одно на корень окна и на страницы живого кэша.
    static let forEnvironment: (Module) -> AnyView = { AnyView(DSModuleControls(module: $0)) }
}
