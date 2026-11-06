import SwiftUI

extension RemoteBotsModel {
    static let shared: RemoteBotsModel = {
        let model = RemoteBotsModel(id: LinkIdentity.id(Module.bots.rawValue), canRead: { ModuleManager.shared.isExternal(.bots) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.bots]?.status })
        return model
    }()
}

struct RemoteBotsPage: View {
    private let model = RemoteBotsModel.shared

    var body: some View {
        RemoteModulePage(module: .bots, model: model) { BotsView(model: model) }
    }
}
