import AppKit
import Combine

/// Модель экрана в окне самой утилиты (центра нет): те же действия, что с провода, но напрямую в контроллер.
@MainActor
final class StudioWindowModel: StudioModel {
    private let controller: StudioController
    private var runnerSub: AnyCancellable?
    @Published private(set) var actionError: String?
    /// Состояние раннера лежит в контроллере: его смена перерисовывает и этот экран.
    @Published private var revision = 0

    init(controller: StudioController) {
        self.controller = controller
        runnerSub = controller.runner.objectWillChange.sink { [weak self] in self?.revision &+= 1 }
    }

    var state: StudioState { controller.state }

    func setFolder(_ path: String) { send(.setFolder(path)) }

    func send(_ action: StudioAction) {
        let reply = controller.handle(LinkWire.encoded(action))
        actionError = (try? JSONDecoder().decode(LinkReply<StudioState>.self, from: reply))?.error
    }

    func openInBrowser() { send(.openInBrowser) }
}
