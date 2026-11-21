import SwiftUI

extension RemoteStudioModel {
    static let shared: RemoteStudioModel = {
        let model = RemoteStudioModel(id: LinkIdentity.id(Module.studio.rawValue), canRead: { ModuleManager.shared.isExternal(.studio) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.studio]?.status })
        return model
    }()
}

struct RemoteStudioPage: View {
    private let model = RemoteStudioModel.shared

    var body: some View {
        RemoteModulePage(module: .studio, model: model) { StudioView(model: model) }
    }
}
