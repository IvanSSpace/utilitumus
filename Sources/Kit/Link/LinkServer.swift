import Foundation

/// Слушатель утилиты. Ссылку на него держит владелец: делегат у NSXPCListener слабый.
final class LinkServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let requirement: String
    private let exported: LinkExportedObject

    init(id: String, handler: LinkHandler, peerIdentifiers: [String] = [Kit.hubBundleID]) {
        listener = NSXPCListener(machServiceName: KitLink.machService(id))
        requirement = KitLink.requirement(identifiers: peerIdentifiers)
        exported = LinkExportedObject(handler: handler)
        super.init()
        // Требование на слушателе не пускает чужого клиента даже до делегата (отчёт о пробе, п. 1).
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
    }

    func resume() {
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: LinkXPC.self)
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}

/// Сообщения XPC приходят на его очереди; обработчик вызывается на главном потоке в том же порядке.
private final class LinkExportedObject: NSObject, LinkXPC, @unchecked Sendable {
    private let handler: LinkHandler

    init(handler: LinkHandler) {
        self.handler = handler
    }

    private func onMain(_ work: @escaping @MainActor @Sendable (LinkHandler) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work(self.handler) }
        }
    }

    /// Закодировать не вышло — пустой ответ: клиент получит ошибку разбора, сервис не упадёт.
    private static func encoded(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    func hello(reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply(Self.encoded($0.linkHello())) }
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply(Self.encoded($0.linkStatus())) }
    }

    func moduleState(reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply($0.linkModuleState()) }
    }

    func moduleAction(_ action: Data, reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply($0.linkModuleAction(action)) }
    }

    func setEnabled(_ enabled: Bool, reply: @escaping @Sendable () -> Void) {
        onMain {
            $0.linkSetEnabled(enabled)
            reply()
        }
    }

    func openWindow(reply: @escaping @Sendable () -> Void) {
        onMain {
            $0.linkOpenWindow()
            reply()
        }
    }

    func quit(reply: @escaping @Sendable () -> Void) {
        onMain {
            reply()
            $0.linkQuit()
        }
    }
}
