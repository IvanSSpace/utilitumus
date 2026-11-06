import SwiftUI

extension RemoteAwakeModel {
    static let shared: RemoteAwakeModel = {
        let model = RemoteAwakeModel(id: LinkIdentity.id(Module.awake.rawValue), canRead: { ModuleManager.shared.isExternal(.awake) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.awake]?.status })
        return model
    }()

    func screen(_ registry: SatelliteRegistry) -> RemoteModuleScreen { screen(of: .awake, registry) }
}

struct RemoteAwakePage: View {
    private let model = RemoteAwakeModel.shared

    var body: some View {
        RemoteModulePage(module: .awake, model: model) { AwakeView(model: model) }
    }
}
