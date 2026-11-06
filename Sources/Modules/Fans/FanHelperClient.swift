import Foundation

/// Связь с root-службой вентиляторов. Каждый вызов блокирует поток до ответа, но не дольше `timeout`,
/// поэтому вызывать только вне главного потока (очередь `FanController.helperQueue`). С главного
/// можно только `sendAll`: она ждёт общий срок, а ответы приходят на частной очереди XPC.
///
/// Требование подписи на клиенте отсекает лишь ответы: сообщение до подменённой службы всё равно доходит
/// (отчёт о пробе, п. 1). Поэтому на каждое соединение первым идёт `version` без данных, команда —
/// только после его ответа, а соединение живёт один вызов: служба может выйти, когда клиентов нет.
enum FanHelperClient {
    enum Command: CustomStringConvertible {
        case auto(Int)
        case set(Int, Double)

        var description: String {
            switch self {
            case .auto(let fan): return "auto \(fan)"
            case .set(let fan, let rpm): return "set \(fan) \(rpm)"
            }
        }
    }

    enum Failure: LocalizedError {
        case timeout
        case rejected
        case connection(Int)

        var errorDescription: String? {
            switch self {
            case .timeout: return "Служба вентиляторов не ответила"
            case .rejected: return "Подпись службы вентиляторов не совпала"
            case .connection(let code): return "Нет связи со службой вентиляторов (\(code))"
            }
        }
    }

    static let timeout: TimeInterval = 3
    /// Сколько выход из приложения или уход в сон ждёт все вентиляторы вместе.
    static let quitBudget: TimeInterval = 1.5

    /// Версия службы; nil — служба не ответила или не прошла проверку подписи.
    static func version() -> String? {
        let connection = open()
        defer { connection.invalidate() }
        return try? handshake(connection, .now() + timeout)
    }

    /// Текст ошибки; nil — успех.
    static func send(_ command: Command, until deadline: DispatchTime = .now() + timeout) -> String? {
        guard DispatchTime.now() < deadline else { return Failure.timeout.localizedDescription }
        let connection = open()
        defer { connection.invalidate() }
        do {
            _ = try handshake(connection, deadline)
            return try deliver(command, connection).wait(until: deadline)
        } catch {
            return error.localizedDescription
        }
    }

    /// Для выхода: через `queue`, чтобы идти после уже отправленных, и не дольше `budget` на всё, включая
    /// ожидание очереди. После рукопожатия команды уходят сразу все, не дожидаясь ответов: служба выполняет
    /// их по одной и по секунде на зависший вентилятор, так что по очереди второй мог бы не успеть уйти.
    /// Ушедшие служба доделает, даже если клиента уже нет. После срока новые не уходят.
    static func sendAll(
        _ commands: [Command],
        on queue: DispatchQueue,
        within budget: TimeInterval = quitBudget,
        finished: @escaping @Sendable (Command, String?) -> Void
    ) {
        // Пустой список — обычный случай: подключение подняло бы root-службу без дела.
        guard !commands.isEmpty else { return }
        let deadline = DispatchTime.now() + budget
        let done = DispatchSemaphore(value: 0)
        queue.async {
            defer { done.signal() }
            guard DispatchTime.now() < deadline else {
                commands.forEach { finished($0, Failure.timeout.localizedDescription) }
                return
            }
            let connection = open()
            defer { connection.invalidate() }
            do {
                _ = try handshake(connection, deadline)
            } catch {
                commands.forEach { finished($0, error.localizedDescription) }
                return
            }
            for (command, waiter) in commands.map({ ($0, deliver($0, connection)) }) {
                do {
                    finished(command, try waiter.wait(until: deadline))
                } catch {
                    finished(command, error.localizedDescription)
                }
            }
        }
        _ = done.wait(timeout: deadline)
    }

    private static func open() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: FanLink.service, options: FanLink.connectionOptions)
        connection.setCodeSigningRequirement(FanLink.serviceRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperXPC.self)
        connection.resume()
        return connection
    }

    private static func handshake(_ connection: NSXPCConnection, _ deadline: DispatchTime) throws -> String {
        try start(connection) { proxy, reply in proxy.version(reply: reply) }.wait(until: deadline)
    }

    private static func deliver(_ command: Command, _ connection: NSXPCConnection) -> Waiter<String?> {
        start(connection) { proxy, reply in
            switch command {
            case .auto(let fan): proxy.setAuto(fan, reply: reply)
            case .set(let fan, let rpm): proxy.setRPM(fan, rpm, reply: reply)
            }
        }
    }

    private static func start<T>(_ connection: NSXPCConnection, _ send: (FanHelperXPC, @escaping (T) -> Void) -> Void) -> Waiter<T> {
        let waiter = Waiter<T>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let nsError = error as NSError
            let rejected = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSXPCConnectionCodeSigningRequirementFailure
            if rejected { connection.invalidate() }
            waiter.finish(.failure(rejected ? .rejected : .connection(nsError.code)))
        } as! FanHelperXPC
        send(proxy) { waiter.finish(.success($0)) }
        return waiter
    }

    /// Засчитывается первое: ответ и ошибка приходят с разных потоков.
    private final class Waiter<T>: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var result: Result<T, Failure>?

        func finish(_ outcome: Result<T, Failure>) {
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else { return }
            result = outcome
            done.signal()
        }

        func wait(until deadline: DispatchTime) throws -> T {
            guard done.wait(timeout: deadline) == .success else { throw Failure.timeout }
            lock.lock()
            defer { lock.unlock() }
            return try result!.get()
        }
    }
}
