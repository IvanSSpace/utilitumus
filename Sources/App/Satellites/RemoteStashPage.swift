import SwiftUI

extension RemoteStashModel {
    static let shared: RemoteStashModel = {
        let model = RemoteStashModel(id: LinkIdentity.id(Module.stash.rawValue), canRead: { ModuleManager.shared.isExternal(.stash) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.stash]?.status })
        return model
    }()

    func screen(_ registry: SatelliteRegistry) -> RemoteModuleScreen { screen(of: .stash, registry) }
}

struct RemoteStashPage: View {
    private let model = RemoteStashModel.shared

    var body: some View {
        RemoteModulePage(module: .stash, model: model) { StashView(store: model) }
    }
}
