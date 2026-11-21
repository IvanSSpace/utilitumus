import AppKit
import Combine

/// Модель экрана в окне самой утилиты (центра нет): те же действия, что с провода, но напрямую в контроллер.
@MainActor
final class StudioWindowModel: StudioModel {
    private let controller: StudioController
    private var handoff: StudioBrowserHandoff!
    private var sub: AnyCancellable?

    init(controller: StudioController) {
        self.controller = controller
        handoff = StudioBrowserHandoff(open: { StudioOpen.inBrowser($0) })
        sub = controller.runner.$state.sink { [weak self] state in self?.handoff.observe(state) }
    }

    var objectWillChange: ObservableObjectPublisher { controller.runner.objectWillChange }
    var state: StudioState { controller.state }
    var browserLogin: Int { handoff.claimed }

    func setFolder(_ path: String) { _ = controller.handle(LinkWire.encoded(StudioAction.setFolder(path))) }
    func newLogin() { _ = controller.handle(LinkWire.encoded(StudioAction.newLogin)) }

    func openInBrowser() {
        handoff.request(after: controller.state.login)
        newLogin()
    }
}
