import Combine
import SwiftUI

/// «Звук» внутри своей утилиты. Устройство по умолчанию возвращает только `AudioMonitor`, и работает он только в
/// активной утилите: пассивная остановлена (`enterPassive` по умолчанию — `stop`), второго писателя рядом нет.
/// Системных настроек модуль не оставляет: при обновлении и удалении снимать нечего, выбор лежит в общем домене.
@MainActor
final class SoundModule: SatelliteModule {
    let module = Module.sound
    private let controller = SoundController.shared
    private var running = false

    /// Монитор не запускает: `init` зовут и копии из Finder.
    init() {}

    /// Модуль снова у утилиты: монитор сам перечитывает настройки, пока он стоял, их мог менять центр.
    func start() {
        running = true
        AudioMonitor.shared.start()
    }

    func stop() {
        running = false
        AudioMonitor.shared.stop()
    }

    /// Строка дашборда та же, что у встроенного модуля. Имя микрофона меняется только со сменой устройства.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        let name = controller.currentInputName
        return name == "—" ? "слежу за микрофоном" : name
    }

    func state() -> Data { LinkWire.encoded(controller.wireState) }

    /// Остановленный модуль ничего не меняет: выбор записался бы в общий домен, а применить его некому.
    func handle(_ action: Data) -> Data {
        guard running else {
            return LinkWire.encoded(LinkReply(state: controller.wireState, error: "Модуль сейчас не работает"))
        }
        return controller.handle(action)
    }

    var changes: AnyPublisher<Void, Never> { controller.objectWillChange.map { _ in }.eraseToAnyPublisher() }
    func windowRoot() -> AnyView { AnyView(SoundView(model: controller)) }
    var windowSize: CGSize { CGSize(width: 560, height: 700) }
}
