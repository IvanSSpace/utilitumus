import SwiftUI

extension RemoteSoundModel {
    static let shared: RemoteSoundModel = {
        let model = RemoteSoundModel(id: LinkIdentity.id(Module.sound.rawValue), canRead: { ModuleManager.shared.isExternal(.sound) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.sound]?.status })
        // Вкладка с первого показа с настоящим списком устройств, а не пустым.
        model.refresh()
        return model
    }()

    func screen(_ registry: SatelliteRegistry) -> RemoteModuleScreen { screen(of: .sound, registry) }
}

struct RemoteSoundPage: View {
    private let model = RemoteSoundModel.shared

    var body: some View {
        RemoteModulePage(module: .sound, model: model) { SoundView(model: model) }
    }
}
