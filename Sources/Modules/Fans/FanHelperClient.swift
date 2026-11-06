import Foundation

/// Связь с root-службой вентиляторов. Каждый вызов блокирует поток до ответа, но не дольше `timeout`,
/// поэтому вызывать только вне главного потока (очередь `FanController.helperQueue`). Единственное
/// исключение — `restoreAutoBlocking` при выходе: ответы приходят на частной очереди XPC, не на главной.
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

    /// Версия службы; nil — служба не ответила или не прошла проверку подписи.
    static func version() -> String? {
        let connection = open()
        defer { connection.invalidate() }
        return try? handshake(connection, .now() + timeout)
    }

    /// Текст ошибки; nil — успех.
    static func send(_ command: Command) -> String? {
        let deadline = DispatchTime.now() + timeout
        let connection = open()
        defer { connection.invalidate() }
        do {
            _ = try handshake(connection, deadline)
            return try call(connection, deadline) { proxy, reply in
                switch command {
                case .auto(let fan): proxy.setAuto(fan, reply: reply)
                case .set(let fan, let rpm): proxy.setRPM(fan, rpm, reply: reply)
                }
            }
        } catch {
            return error.localizedDescription
        }
    }

    private static func open() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: FanLink.service, options: FanLink.connectionOptions)
        connection.setCodeSigningRequirement(FanLink.serviceRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperXPC.self)
        connection.resume()
        return connection
    }

    private static func handshake(_ connection: NSXPCConnection, _ deadline: DispatchTime) throws -> String {
        try call(connection, deadline) { proxy, reply in proxy.version(reply: reply) }
    }

    private static func call<T>(
        _ connection: NSXPCConnection,
        _ deadline: DispatchTime,
        _ send: (FanHelperXPC, @escaping (T) -> Void) -> Void
    ) throws -> T {
        let waiter = Waiter<T>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let nsError = error as NSError
            let rejected = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSXPCConnectionCodeSigningRequirementFailure
            if rejected { connection.invalidate() }
            waiter.finish(.failure(rejected ? .rejected : .connection(nsError.code)))
        } as! FanHelperXPC
        send(proxy) { waiter.finish(.success($0)) }
        return try waiter.wait(until: deadline)
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
