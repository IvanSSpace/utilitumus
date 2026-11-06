import SwiftUI

extension RemoteLoadModel {
    static let shared: RemoteLoadModel = {
        let model = RemoteLoadModel(id: LinkIdentity.id(Module.load.rawValue), canRead: { ModuleManager.shared.isExternal(.load) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.load]?.status })
        return model
    }()
}

struct RemoteLoadPage: View {
    private let model = RemoteLoadModel.shared

    var body: some View {
        RemoteModulePage(module: .load, model: model) { LoadScreen(model: model) }
    }
}
