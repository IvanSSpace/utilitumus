import Combine
import SwiftUI

/// «Не спать» внутри своей утилиты. Блокировка появляется только по кнопке.
@MainActor
final class AwakeModule: SatelliteModule {
    let module = Module.awake
    private let controller = AwakeController.shared

    /// Встроенному модулю можно всегда, утилите — только после `start`.
    init() { controller.canStart = false }

    /// Модуль снова у утилиты: пока он был у центра, настройки менялись там.
    func start() {
        controller.canStart = true
        controller.start()
    }

    func stop() {
        controller.canStart = false
        controller.stop()
    }

    /// Блокировку включил сам человек, поэтому запуск центра её не снимает: встроенный модуль без нажатия кнопки
    /// блокировку не держит, двойной работы нет. Новую включить нельзя.
    func enterPassive() {
        controller.canStart = false
    }

    /// Без остатка времени: центр перечитывает строку редко, и «ещё 2 ч» застывало бы у него на экране.
    func statusLine(passiveReason: String?) -> String {
        if controller.isActive { return "Mac не уснёт" }
        return passiveReason ?? "Mac засыпает как обычно"
    }

    var quickActions: [LinkQuickAction] {
        guard controller.isActive || controller.canStart else { return [] }
        return [LinkQuickAction(title: controller.isActive ? "Можно спать" : "Не спать",
                                icon: controller.isActive ? "moon.zzz" : "cup.and.saucer",
                                action: LinkWire.encoded(AwakeAction.toggle))]
    }

    func state() -> Data { LinkWire.encoded(controller.wireState) }
    func handle(_ action: Data) -> Data { controller.handle(action) }
    var changes: AnyPublisher<Void, Never> { controller.objectWillChange.map { _ in }.eraseToAnyPublisher() }
    func windowRoot() -> AnyView { AnyView(AwakeView(model: controller)) }
    /// Перезапуск снял бы блокировку, которую пользователь сам включил.
    var mayRestart: Bool { !controller.isActive }

    #if KIT_TEST_DEFAULTS
    func standCommand() { controller.toggle() }
    #endif
}
