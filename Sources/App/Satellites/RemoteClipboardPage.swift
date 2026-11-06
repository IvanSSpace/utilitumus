import SwiftUI

extension RemoteClipboardModel {
    static let shared: RemoteClipboardModel = {
        let model = RemoteClipboardModel(id: LinkIdentity.id(Module.clipboard.rawValue),
                                         canRead: { ModuleManager.shared.isExternal(.clipboard) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.clipboard]?.status })
        return model
    }()
}

struct RemoteClipboardPage: View {
    private let model = RemoteClipboardModel.shared

    var body: some View {
        RemoteModulePage(module: .clipboard, model: model) { ClipboardView(model: model) }
    }
}
