import SwiftUI

extension RemoteSpeakModel {
    static let shared: RemoteSpeakModel = {
        let model = RemoteSpeakModel(id: LinkIdentity.id(Module.speak.rawValue), canRead: { ModuleManager.shared.isExternal(.speak) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.speak]?.status })
        return model
    }()
}

struct RemoteSpeakPage: View {
    private let model = RemoteSpeakModel.shared

    var body: some View {
        RemoteModulePage(module: .speak, model: model) { SpeakView(model: model) }
    }
}
