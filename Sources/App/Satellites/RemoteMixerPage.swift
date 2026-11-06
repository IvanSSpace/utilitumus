import SwiftUI

extension RemoteMixerModel {
    static let shared: RemoteMixerModel = {
        let model = RemoteMixerModel(id: LinkIdentity.id(Module.mixer.rawValue), canRead: { ModuleManager.shared.isExternal(.mixer) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.mixer]?.status })
        return model
    }()
}

struct RemoteMixerPage: View {
    private let model = RemoteMixerModel.shared

    var body: some View {
        RemoteModulePage(module: .mixer, model: model) { MixerView(model: model) }
    }
}
