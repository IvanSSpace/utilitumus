import SwiftUI

extension RemoteVoiceModel {
    static let shared: RemoteVoiceModel = {
        let model = RemoteVoiceModel(id: LinkIdentity.id(Module.voice.rawValue), canRead: { ModuleManager.shared.isExternal(.voice) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.voice]?.status })
        return model
    }()
}

struct RemoteVoicePage: View {
    private let model = RemoteVoiceModel.shared

    var body: some View {
        RemoteModulePage(module: .voice, model: model) { VoiceView(voice: model) }
    }
}
