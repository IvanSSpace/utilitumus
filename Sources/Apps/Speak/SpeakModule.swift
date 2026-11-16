import Combine
import SwiftUI

/// «Озвучка» внутри своей утилиты: сочетание, чтение выделения, меню «Службы» и мини-плеер.
/// `init` ничего не запускает: сочетание, провайдер служб и панель появляются только в `start`.
@MainActor
final class SpeakModule: SatelliteModule {
    let module = Module.speak
    private let controller: SpeakController
    let service: SpeakService
    let player: SpeakPlayer

    /// Встроенного модуля у «Озвучки» нет, но порядок тот же, что у соседей: читать можно только после `start`.
    /// `installServices` — для проверок: настоящий провайдер служб ставится в `NSApp`.
    init(controller: SpeakController? = nil, installServices: ((AnyObject?) -> Void)? = nil) {
        let controller = controller ?? .shared
        self.controller = controller
        service = SpeakService(controller: controller, install: installServices)
        player = SpeakPlayer(controller: controller)
        controller.canStart = false
    }

    /// Пока модуль стоял, настройки мог менять центр: контроллер перечитывает их сам.
    func start() {
        controller.canStart = true
        controller.start()
        service.attach()
        player.attach()
    }

    /// Сначала запрет и провайдер служб: система больше не достучится до чтения, пока оно обрывается.
    func stop() {
        controller.canStart = false
        service.detach()
        player.detach()
        controller.stop()
    }

    /// Без текста и без фазы чтения: о смене статуса узнают все на этом Mac.
    func statusLine(passiveReason: String?) -> String {
        controller.statusLine(passiveReason: passiveReason)
    }

    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: "speak.ax", title: "Универсальный доступ",
                       why: "Чтобы взять выделенный текст из программы. Без права работает меню «Службы»",
                       icon: "hand.raised.fill", required: false, done: Kit.accessTrusted())]
    }

    func performSetupStep(_ id: String) -> String? {
        switch id {
        case "speak.ax": controller.requestAccessibility()
        default: return "Такого шага нет"
        }
        return nil
    }

    func state() -> Data { LinkWire.encoded(controller.wireState) }
    func handle(_ action: Data) -> Data { controller.handle(action) }

    /// Только когда меняется то, что видит экран.
    var changes: AnyPublisher<Void, Never> {
        controller.objectWillChange
            // `objectWillChange` приходит до записи значения.
            .receive(on: DispatchQueue.main)
            .map { [weak self] in self?.controller.wireState }
            .removeDuplicates()
            .map { _ in }
            .eraseToAnyPublisher()
    }

    func windowRoot() -> AnyView { AnyView(SpeakView(model: controller)) }
    var windowSize: CGSize { CGSize(width: 620, height: 720) }

    /// Идёт чтение: перезапуск оборвал бы его.
    var mayRestart: Bool { controller.phase == .idle }
}
