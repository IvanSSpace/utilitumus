import SwiftUI

extension RemoteKeyboardModel {
    static let shared: RemoteKeyboardModel = {
        let model = RemoteKeyboardModel(id: LinkIdentity.id(Module.keyboard.rawValue), canRead: { ModuleManager.shared.isExternal(.keyboard) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.keyboard]?.status })
        return model
    }()
}

struct RemoteKeyboardPage: View {
    private let model = RemoteKeyboardModel.shared

    var body: some View {
        RemoteModulePage(module: .keyboard, model: model) { KeyboardView(model: model) }
    }
}
