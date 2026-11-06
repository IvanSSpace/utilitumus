import Foundation

/// Слушатель утилиты. Ссылку на него держит владелец: делегат у NSXPCListener слабый.
/// Запуск и вызовы — на главном потоке, кроме делегата, которого зовёт сама система.
final class LinkServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let requirement: String
    private let handler: LinkHandler
    /// Соединения с `watch`, только на главном потоке.
    private var watching: [LinkSession] = []
    private var screenOpen = false

    init(id: String, handler: LinkHandler, peerIdentifiers: [String] = [Kit.hubBundleID]) {
        listener = NSXPCListener(machServiceName: KitLink.machService(id))
        requirement = KitLink.requirement(identifiers: peerIdentifiers)
        self.handler = handler
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
        connection.remoteObjectInterface = NSXPCInterface(with: LinkPingXPC.self)
        let session = LinkSession(handler: handler, server: self, connection: connection,
                                  fromHub: LinkCaller.peerIsHub(pid: connection.processIdentifier))
        connection.exportedObject = session
        // Клиент умер или закрыл соединение: аренда и подписка кончаются здесь, а не по его просьбе.
        // Сообщения этого соединения к этому моменту уже ушли на главный поток, порядок сохраняется.
        connection.invalidationHandler = { [weak self, session] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lost(session) } }
        }
        connection.resume()
        return true
    }

    /// Сообщить подписчикам, что состояние изменилось. Без данных: прочитают сами.
    @MainActor func pingState() {
        for session in watching {
            (session.connection?.remoteObjectProxy as? LinkPingXPC)?.stateChanged()
        }
    }

    @MainActor fileprivate func watch(_ session: LinkSession, _ level: LinkWatch) {
        watching.removeAll { $0 === session }
        session.level = level
        if level != .none { watching.append(session) }
        syncScreen()
    }

    @MainActor private func lost(_ session: LinkSession) {
        let wasWatching = watching.contains { $0 === session }
        watching.removeAll { $0 === session }
        session.level = .none
        syncScreen()
        if wasWatching { handler.linkWatcherLost() }
    }

    @MainActor private func syncScreen() {
        let open = watching.contains { $0.level == .screen }
        guard open != screenOpen else { return }
        screenOpen = open
        handler.linkScreenOpen(open)
    }
}

/// Одно соединение. Сообщения XPC приходят на его очереди; обработчик вызывается на главном потоке в том же порядке.
private final class LinkSession: NSObject, LinkXPC, @unchecked Sendable {
    private let handler: LinkHandler
    private weak var server: LinkServer?
    weak var connection: NSXPCConnection?
    /// Только на главном потоке.
    var level = LinkWatch.none

    /// Подписан как центр, а не как копия самой утилиты.
    private let fromHub: Bool

    init(handler: LinkHandler, server: LinkServer, connection: NSXPCConnection, fromHub: Bool) {
        self.fromHub = fromHub
        self.handler = handler
        self.server = server
        self.connection = connection
    }

    private func onMain(_ work: @escaping @MainActor @Sendable (LinkHandler) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work(self.handler) }
        }
    }

    func hello(reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply(LinkWire.encoded($0.linkHello())) }
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply(LinkWire.encoded($0.linkStatus())) }
    }

    func moduleState(reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply($0.linkModuleState()) }
    }

    func moduleAction(_ action: Data, reply: @escaping @Sendable (Data) -> Void) {
        onMain { [fromHub] handler in
            reply(LinkCaller.run(fromHub: fromHub) { handler.linkModuleAction(action) })
        }
    }

    func performSetupStep(_ id: String, reply: @escaping @Sendable (Data) -> Void) {
        onMain { reply($0.linkPerformSetupStep(id)) }
    }

    /// Неизвестный уровень — как отказ от подписки.
    func watch(_ level: Int, reply: @escaping @Sendable () -> Void) {
        onMain { [weak self] _ in
            if let self { self.server?.watch(self, LinkWatch(rawValue: level) ?? .none) }
            reply()
        }
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

    /// Неизвестная причина — как обновление: лучше оставить настройку пользователя, чем снять её без просьбы.
    func quit(reason: Int, reply: @escaping @Sendable () -> Void) {
        onMain {
            reply()
            $0.linkQuit(LinkQuitReason(rawValue: reason) ?? .update)
        }
    }
}
