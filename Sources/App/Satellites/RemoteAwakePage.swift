import SwiftUI

extension RemoteAwakeModel {
    static let shared = RemoteAwakeModel(id: AwakeIdentity.id, canRead: { ModuleManager.shared.isExternal(.awake) })
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
            // Реестр снова слышит утилиту (страница «не отвечает», «Открыть окно»): экран модуля возвращается.
            .onChange(of: registry.entries[.awake]?.status) { model.refresh() }
    }

    @ViewBuilder private var content: some View {
        if !model.responding {
            SatellitePage(module: .awake)
        } else if registry.entries[.awake]?.status?.enabled == false {
            ModuleOffView(module: .awake) { registry.setEnabled(.awake, true) } more: { modules.infoModule = .awake }
        } else {
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
