import Foundation

/// Слушатели утилиты: две службы, два требования. Центр приходит на `machService`, копия самой утилиты из Finder —
/// на `selfService`; кто пришёл, определяет служба и подпись на ней, а не pid. Ссылку на сервер держит владелец:
/// делегат у NSXPCListener слабый. Запуск и вызовы — на главном потоке, кроме делегата, которого зовёт сама система.
final class LinkServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    enum Role: Equatable { case hub, selfCopy }

    /// Что слушает одна служба. Чистое описание: проверяется без запуска.
    struct Spec: Equatable {
        let role: Role
        let service: String
        let requirement: String
    }

    static func specs(id: String, hubIdentifier: String = Kit.hubBundleID) -> [Spec] {
        [Spec(role: .hub, service: KitLink.machService(id), requirement: KitLink.requirement(identifier: hubIdentifier)),
         Spec(role: .selfCopy, service: KitLink.selfService(id), requirement: KitLink.requirement(identifier: KitLink.bundleID(id)))]
    }

    private var listeners: [(spec: Spec, listener: NSXPCListener)] = []
    private let handler: LinkHandler
    /// Соединения с `watch`, только на главном потоке.
    private var watching: [LinkSession] = []
    private var screenOpen = false

    init(id: String, handler: LinkHandler, hubIdentifier: String = Kit.hubBundleID) {
        self.handler = handler
        super.init()
        for spec in Self.specs(id: id, hubIdentifier: hubIdentifier) {
            let listener = NSXPCListener(machServiceName: spec.service)
            // Требование на слушателе не пускает чужого клиента даже до делегата (отчёт о пробе, п. 1).
            listener.setConnectionCodeSigningRequirement(spec.requirement)
            listener.delegate = self
            listeners.append((spec, listener))
        }
    }

    func resume() {
        for entry in listeners { entry.listener.resume() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let spec = listeners.first(where: { $0.listener === listener })?.spec else { return false }
        connection.setCodeSigningRequirement(spec.requirement)
        switch spec.role {
        case .selfCopy:
            // Копия из Finder: интерфейс из одного вызова, подписок и действий в нём нет.
            connection.exportedInterface = NSXPCInterface(with: LinkSelfXPC.self)
            connection.exportedObject = LinkSelfSession(handler: handler)
            connection.resume()
            return true
        case .hub:
            break
        }
        connection.exportedInterface = NSXPCInterface(with: LinkXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: LinkPingXPC.self)
        let session = LinkSession(handler: handler, server: self, connection: connection)
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

/// Копия утилиты из Finder: может попросить показать окно, больше ничего.
private final class LinkSelfSession: NSObject, LinkSelfXPC, @unchecked Sendable {
    private let handler: LinkHandler

    init(handler: LinkHandler) { self.handler = handler }

    func openWindow(reply: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handler.linkOpenWindow() }
            reply()
        }
    }
}

/// Одно соединение центра. Сообщения XPC приходят на его очереди; обработчик вызывается на главном потоке в том же порядке.
private final class LinkSession: NSObject, LinkXPC, @unchecked Sendable {
    private let handler: LinkHandler
    private weak var server: LinkServer?
    weak var connection: NSXPCConnection?
    /// Только на главном потоке.
    var level = LinkWatch.none

    init(handler: LinkHandler, server: LinkServer, connection: NSXPCConnection) {
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
        onMain { handler in
            // Сюда доходит только соединение со службы центра.
            reply(LinkCaller.run(fromHub: true) { handler.linkModuleAction(action) })
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

    func setMenuIcon(_ on: Bool, reply: @escaping @Sendable () -> Void) {
        onMain {
            $0.linkSetMenuIcon(on)
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
