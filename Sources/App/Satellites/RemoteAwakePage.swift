import SwiftUI

/// Что показать вместо встроенного модуля, пока его ведёт утилита.
enum RemoteAwakeScreen { case notResponding, off, module }

extension RemoteAwakeModel {
    static let shared: RemoteAwakeModel = {
        let model = RemoteAwakeModel(id: AwakeIdentity.id, canRead: { ModuleManager.shared.isExternal(.awake) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.awake]?.status })
        return model
    }()

    /// Решение одно на вкладку, карточку дашборда и меню-бар.
    func screen(_ registry: SatelliteRegistry) -> RemoteAwakeScreen {
        if !responding { return .notResponding }
        return registry.entries[.awake]?.status?.enabled == false ? .off : .module
    }
}

/// Вкладка «Не спать», когда модуль ведёт утилита: тот же экран, что у встроенного, сразу с последним известным
/// состоянием. Ответа она не ждёт. Запасной экран — только если утилита не отвечает.
struct RemoteAwakePage: View {
    @ObservedObject private var model = RemoteAwakeModel.shared
    @ObservedObject private var registry = SatelliteRegistry.shared
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        content
            .onPageActive { if $0 { model.refresh() } }
    }

    @ViewBuilder private var content: some View {
        switch model.screen(registry) {
        case .notResponding:
            SatellitePage(module: .awake)
        case .off:
            ModuleOffView(module: .awake) { registry.setEnabled(.awake, true) } more: { modules.infoModule = .awake }
        case .module:
            ModuleScreen(module: .awake) {
                AwakeView(model: model)
                    .overlay(alignment: .bottom) {
                        if let error = model.actionError {
                            Text(error).font(DS.rowSubtitle).foregroundStyle(.orange).padding(.bottom, 12)
                        }
                    }
            }
        }
    }
}
