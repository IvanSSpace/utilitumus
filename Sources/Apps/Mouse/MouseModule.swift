import ApplicationServices
import Combine
import SwiftUI

/// «Мышь» внутри своей утилиты. Перехват прокрутки появляется, только пока он нужен настройкам и есть доступ.
@MainActor
final class MouseModule: SatelliteModule {
    let module = Module.mouse
    private let controller = MouseController.shared

    /// `MouseController` при создании ничего не запускает: опрос и tap начинаются в `start`.
    init() {}

    func start() { controller.start() }

    /// Настройки пользователя остаются: снимается только перехват.
    func stop() { controller.stop() }

    /// Нужен ли доступ, зависит от настроек: при настройках «как в системе» перехвата нет и разрешение не требуется.
    private var needsAccess: Bool { controller.settings.needsTap }

    var attention: Bool { needsAccess && !AXIsProcessTrusted() }

    /// Только то, что задал сам человек: работает ли tap в эту секунду, в статус не идёт.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        if attention { return "нужен Универсальный доступ" }
        return controller.settings.summary
    }

    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: Self.accessStep, title: "Универсальный доступ",
                       why: "Чтобы менять направление и плавность прокрутки", icon: "lock.shield.fill",
                       required: needsAccess, done: AXIsProcessTrusted())]
    }

    func performSetupStep(_ id: String) -> String? {
        controller.requestAccess()
        return nil
    }

    private static let accessStep = "mouse.ax"

    func state() -> Data { LinkWire.encoded(controller.wireState) }
    func handle(_ action: Data) -> Data { controller.handle(action) }
    var changes: AnyPublisher<Void, Never> { controller.objectWillChange.map { _ in }.eraseToAnyPublisher() }

    /// Доступ дают в Системных настройках: на открытом экране читаем его сразу, а не по опросу.
    func screenOpen(_ open: Bool) {
        if open { controller.refreshAccess() }
    }

    func windowRoot() -> AnyView { AnyView(MouseView(model: controller)) }
    var windowSize: CGSize { CGSize(width: 560, height: 620) }
}
