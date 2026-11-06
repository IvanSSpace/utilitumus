import Foundation

/// Остальные сбои приходят как есть: `NSError` соединения или ошибка разбора ответа. Код NSError
/// причину не различает: и умерший сервис, и отказ слушателя дают 4097 или 4099, смотря что раньше,
/// ошибка вызова или наше закрытие соединения.
enum LinkError: Error, Equatable {
    case timeout
    /// Сервис не прошёл проверку подписи (4102).
    case rejected
    case incompatible(Int)
}

/// Подключение к утилите. Методы только асинхронные и возвращаются на главный поток.
///
/// Требование подписи на клиенте отсекает лишь ответы: сообщение до подменённого сервиса всё равно
/// доходит (отчёт о пробе, п. 1). Поэтому на каждом соединении первым идёт `hello` без данных,
/// а любой сбой закрывает соединение: следующий вызов начнёт новое, снова с `hello`.
final class LinkClient {
    private final class Session {
        let connection: NSXPCConnection
        var greeted = false
        init(connection: NSXPCConnection) { self.connection = connection }
    }

    private let id: String
    private let timeout: TimeInterval
    private var session: Session?
    private var watchLevel = LinkWatch.none
    /// Утилита сообщила о смене состояния. Только по соединению, прошедшему `hello`.
    @MainActor var onStateChanged: (() -> Void)?

    init(id: String, timeout: TimeInterval = 2) {
        self.id = id
        self.timeout = timeout
    }

    deinit {
        session?.connection.invalidate()
    }

    @MainActor func hello() async throws -> LinkHello {
        try await withSession { session, deadline in
            try await self.greet(session, deadline)
        }
    }

    @MainActor func status() async throws -> LinkStatus {
        let data: Data = try await command { proxy, done in proxy.status(reply: done) }
        return try Self.decodeStatus(data)
    }

    @MainActor func moduleState() async throws -> Data {
        try await command { proxy, done in proxy.moduleState(reply: done) }
    }

    @MainActor func moduleAction(_ action: Data) async throws -> Data {
        try await command { proxy, done in proxy.moduleAction(action, reply: done) }
    }

    @MainActor func setEnabled(_ enabled: Bool) async throws {
        try await command { proxy, done in proxy.setEnabled(enabled) { done(()) } }
    }

    @MainActor func openWindow() async throws {
        try await command { proxy, done in proxy.openWindow { done(()) } }
    }

    @MainActor func quit(_ reason: LinkQuitReason) async throws {
        try await command { proxy, done in proxy.quit(reason: reason.rawValue) { done(()) } }
    }

    @MainActor func performSetupStep(_ id: String) async throws -> LinkReply<LinkStatus> {
        let data: Data = try await command { proxy, done in proxy.performSetupStep(id, reply: done) }
        return try JSONDecoder().decode(LinkReply<LinkStatus>.self, from: data)
    }

    /// Запоминается и повторяется на каждом новом соединении: аренда живёт, пока живо соединение, а центр
    /// хочет её, пока открыт экран. Само по себе соединение не поднимает: иначе launchd будил бы утилиту зря.
    @MainActor func setWatch(_ level: LinkWatch) {
        guard level != watchLevel else { return }
        watchLevel = level
        guard let session, session.greeted else { return }
        Task { @MainActor in
            try? await self.command { proxy, done in proxy.watch(self.watchLevel.rawValue) { done(()) } }
        }
    }

    static func decodeHello(_ data: Data) throws -> LinkHello {
        let hello = try JSONDecoder().decode(LinkHello.self, from: data)
        guard KitLink.isCompatible(hello) else {
            throw LinkError.incompatible(hello.protocolVersion)
        }
        return hello
    }

    static func decodeStatus(_ data: Data) throws -> LinkStatus {
        try JSONDecoder().decode(LinkStatus.self, from: data)
    }

    /// Команда уходит только по соединению, на котором `hello` уже ответил. Срок общий на оба шага.
    @MainActor private func command<T: Sendable>(_ send: (LinkXPC, @escaping @Sendable (T) -> Void) -> Void) async throws -> T {
        try await withSession { session, deadline in
            if !session.greeted {
                _ = try await self.greet(session, deadline)
            }
            return try await self.roundTrip(session, deadline, send)
        }
    }

    @MainActor private func greet(_ session: Session, _ deadline: DispatchTime) async throws -> LinkHello {
        let data: Data = try await roundTrip(session, deadline) { proxy, done in proxy.hello(reply: done) }
        let hello = try Self.decodeHello(data)
        if watchLevel != .none {
            try await roundTrip(session, deadline) { proxy, done in proxy.watch(self.watchLevel.rawValue) { done(()) } }
        }
        session.greeted = true
        return hello
    }

    @MainActor private func withSession<T>(_ body: (Session, DispatchTime) async throws -> T) async throws -> T {
        let session = currentSession()
        do {
            return try await body(session, .now() + timeout)
        } catch {
            close(session)
            throw error
        }
    }

    @MainActor private func currentSession() -> Session {
        if let session { return session }
        let connection = NSXPCConnection(machServiceName: KitLink.machService(id), options: [])
        connection.setCodeSigningRequirement(KitLink.requirement(identifier: KitLink.bundleID(id)))
        connection.remoteObjectInterface = NSXPCInterface(with: LinkXPC.self)
        let session = Session(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: LinkPingXPC.self)
        connection.exportedObject = LinkPingReceiver { [weak self, weak session] in
            MainActor.assumeIsolated {
                if let self, session?.greeted == true { self.onStateChanged?() }
            }
        }
        // Сервис умер: иначе следующее сообщение по этому соединению ушло бы новому процессу без `hello`.
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.invalidationHandler = { [weak self, weak session] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let self, let session { self.close(session) }
                }
            }
        }
        connection.resume()
        self.session = session
        return session
    }

    @MainActor private func close(_ closing: Session) {
        closing.connection.invalidate()
        if session === closing { session = nil }
    }

    /// Ответ, ошибка соединения или срок: что раньше. Ни одного синхронного ожидания.
    @MainActor private func roundTrip<T: Sendable>(
        _ session: Session,
        _ deadline: DispatchTime,
        _ send: (LinkXPC, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        let connection = session.connection
        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation)
            DispatchQueue.main.asyncAfter(deadline: deadline) {
                pending.finish(.failure(LinkError.timeout))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                let nsError = error as NSError
                let rejected = nsError.domain == NSCocoaErrorDomain
                    && nsError.code == NSXPCConnectionCodeSigningRequirementFailure
                // Здесь, а не после перехода на главный поток: пока он занят, новая команда
                // ушла бы по этому же соединению подменённому сервису.
                if rejected { connection.invalidate() }
                pending.finish(.failure(rejected ? LinkError.rejected : error))
            } as! LinkXPC
            send(proxy) { pending.finish(.success($0)) }
        }
    }
}

/// Слушает `statusChanged` утилиты, пока жив.
final class LinkStatusObserver: NSObject {
    private let changed: @MainActor () -> Void

    init(id: String, changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        super.init()
        // `.deliverImmediately`: иначе неактивный центр получит пинок с большой задержкой.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(statusDidChange), name: KitLink.statusChanged(id),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func statusDidChange() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.changed() } }
    }
}

private final class LinkPingReceiver: NSObject, LinkPingXPC, @unchecked Sendable {
    private let received: @Sendable () -> Void

    init(received: @escaping @Sendable () -> Void) {
        self.received = received
    }

    func stateChanged() {
        DispatchQueue.main.async(execute: received)
    }
}

/// Продолжается один раз: ответ, ошибка и срок приходят с разных потоков.
private final class PendingReply<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
