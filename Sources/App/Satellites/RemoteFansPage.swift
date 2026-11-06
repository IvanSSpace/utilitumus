import SwiftUI

extension RemoteFansModel {
    static let shared: RemoteFansModel = {
        let model = RemoteFansModel(id: LinkIdentity.id(Module.fans.rawValue), canRead: { ModuleManager.shared.isExternal(.fans) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.fans]?.status })
        return model
    }()
}

struct RemoteFansPage: View {
    private let model = RemoteFansModel.shared

    var body: some View {
        RemoteModulePage(module: .fans, model: model) { FansView(model: model) }
    }
}
