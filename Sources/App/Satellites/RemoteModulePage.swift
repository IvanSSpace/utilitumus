import SwiftUI

/// Что показать вместо встроенного модуля, пока его ведёт утилита.
enum RemoteModuleScreen { case notResponding, off, module }

extension RemoteModuleModel {
    /// Решение одно на вкладку, карточку дашборда и меню-бар.
    func screen(of module: Module, _ registry: SatelliteRegistry) -> RemoteModuleScreen {
        if !responding { return .notResponding }
        return registry.entries[module]?.status?.enabled == false ? .off : .module
    }
}

/// Вкладка модуля, когда его ведёт утилита: тот же экран, что у встроенного, сразу с последним известным
/// состоянием. Ответа она не ждёт. Запасной экран — только если утилита не отвечает.
struct RemoteModulePage<State: Codable & Equatable & Sendable, Action: Codable & Sendable, Content: View>: View {
    let module: Module
    @ObservedObject var model: RemoteModuleModel<State, Action>
    @ViewBuilder let content: () -> Content
    @ObservedObject private var registry = SatelliteRegistry.shared
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        page
            .onPageActive { open in
                model.setScreenOpen(open)
                if open { model.refresh() }
            }
    }

    @ViewBuilder private var page: some View {
        switch model.screen(of: module, registry) {
        case .notResponding:
            SatellitePage(module: module)
        case .off:
            ModuleOffView(module: module) { registry.setEnabled(module, true) } more: { modules.infoModule = module }
        case .module:
            ModuleScreen(module: module) {
                content()
                    .overlay(alignment: .bottom) {
                        if let error = model.actionError {
                            Text(error).font(DS.rowSubtitle).foregroundStyle(.orange).padding(.bottom, 12)
                        }
                    }
            }
        }
    }
}
