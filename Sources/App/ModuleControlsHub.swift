import SwiftUI

/// «Как это работает» и переключатель «Включён» модуля.
struct DSModuleControls: View {
    let module: Module
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var satellites = SatelliteRegistry.shared
    @ObservedObject private var icons = ModuleMenuIcons.shared

    /// Утилита ещё не ответила — не «выключен»: через миг ответ заменил бы надпись на глазах.
    private var on: Bool {
        modules.isExternal(module) ? satellites.entries[module]?.status?.enabled ?? true : modules.isOn(module)
    }

    private func set(_ value: Bool) {
        if modules.isExternal(module) { satellites.setEnabled(module, value) } else { modules.setOn(module, value) }
    }

    var body: some View {
        let on = on
        HStack(spacing: 10) {
            DSButton("Как это работает", icon: "info.circle", style: .plain, small: true) { modules.infoModule = module }
                .help("Что умеет модуль и как им пользоваться")
            DSMenuIconSwitch(isOn: Binding(get: { icons.isOn(module) }, set: { icons.set(module, $0) }))
            HStack(spacing: 7) {
                Text(on ? "Включён" : "Выключен")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.85 : 0.5))
                DSToggle("Модуль включён", isOn: Binding(get: { on }, set: { set($0) }))
            }
            .help(on ? "Выключить: модуль остановится полностью" : "Включить модуль")
        }
    }
}

extension DSModuleControls {
    /// Значение для `\.moduleControls`: одно на корень окна и на страницы живого кэша.
    static let forEnvironment: (Module) -> AnyView = { AnyView(DSModuleControls(module: $0)) }
}
