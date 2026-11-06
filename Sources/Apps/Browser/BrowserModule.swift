import Combine
import SwiftUI

/// «Браузер» внутри своей утилиты. Работу делает вложенный `Utilitumus Links.app`, он принимает ссылки сам и читает
/// общие настройки, поэтому у утилиты нет ни состояния, ни действий: центр рисует экран сам (`RemoteBrowserPage`).
/// Утилита упаковывает помощника, регистрирует его в LaunchServices и отдаёт центру статус и шаг «Браузер по умолчанию».
@MainActor
final class BrowserModule: SatelliteModule {
    let module = Module.browser
    private let handler: BrowserLinkHandler
    private let copies: () -> [URL]

    /// Подставные обработчик и копии нужны проверкам: настоящий LaunchServices они не трогают.
    init(handler: BrowserLinkHandler = .live, copies: @escaping () -> [URL] = { BrowserHelper.knownCopies() }) {
        self.handler = handler
        self.copies = copies
    }

    /// Только регистрация копий, обработчиком их делает человек. Вложенная копия сама в LaunchServices не попадает.
    func start() {
        for copy in copies() { handler.register(copy) }
        handler.noteDefault()
    }

    /// Помощник живёт сам и не зависит от утилиты; выключенный модуль он видит в настройках.
    func stop() {}

    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        return handler.isDefault ? "Ссылки открывает Utilitumus" : "Не браузер по умолчанию"
    }

    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: "browser.default", title: "Браузер по умолчанию",
                       why: "Чтобы ссылки шли через выбор браузера; macOS попросит подтвердить",
                       icon: "globe", kind: .permission, buttonTitle: "Сделать основным", done: handler.isDefault)]
    }

    /// Только по кнопке человека. Подтверждение показывает macOS от имени утилиты.
    func performSetupStep(_ id: String) -> String? {
        guard let copy = copies().first else { return "Помощник ссылок не найден" }
        let handler = handler
        Task {
            handler.register(copy)
            for scheme in BrowserLinkHandler.schemes { try? await handler.services.setDefault(copy, scheme) }
            handler.noteDefault()
        }
        return nil
    }

    func state() -> Data { LinkWire.encoded(BrowserState()) }

    func handle(_ action: Data) -> Data {
        LinkWire.handle(action, as: BrowserAction.self, limit: 64, state: { BrowserState() }) { _ in "Утилита не принимает действий" }
    }

    var changes: AnyPublisher<Void, Never> { Empty(completeImmediately: false).eraseToAnyPublisher() }

    func windowRoot() -> AnyView { AnyView(BrowserView()) }
    var windowSize: CGSize { CGSize(width: 760, height: 640) }
}

/// Экран читает общие настройки сам, по связи ничего не идёт.
struct BrowserState: Codable, Equatable, Sendable {}

/// Утилита действий не принимает: любое отвергается при разборе.
struct BrowserAction: Codable, Equatable, Sendable {
    init(from decoder: Decoder) throws {
        throw try LinkActionFields(from: decoder).refuse()
    }

    func encode(to encoder: Encoder) throws {}
}
