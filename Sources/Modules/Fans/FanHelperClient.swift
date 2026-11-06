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
        case cancelled

        var errorDescription: String? {
            switch self {
            case .timeout: return "Служба вентиляторов не ответила"
            case .rejected: return "Подпись службы вентиляторов не совпала"
            case .connection(let code): return "Нет связи со службой вентиляторов (\(code))"
            case .cancelled: return "Команда отменена: вентиляторы отданы системе"
            }
        }
    }

    static let timeout: TimeInterval = 3
    /// Сколько выход из приложения или уход в сон ждёт все вентиляторы вместе.
    static let quitBudget: TimeInterval = 1.5

    /// Версия службы; nil — служба не ответила или не прошла проверку подписи.
    static func version() -> String? {
        if refusesRealService { return nil }
        let connection = open()
        defer { connection.invalidate() }
        return try? handshake(connection, .now() + timeout)
    }

    /// Текст ошибки; nil — успех.
    static func send(_ command: Command, until deadline: DispatchTime = .now() + timeout) -> String? {
        if refusesRealService { return "Стенд не говорит с настоящей службой вентиляторов" }
        guard DispatchTime.now() < deadline else { return Failure.timeout.localizedDescription }
        if case .set = command, setsStopped.value { return Failure.cancelled.localizedDescription }
        let connection = open()
        defer { connection.invalidate() }
        do {
            _ = try handshake(connection, deadline)
            // Пока шло рукопожатие, выход мог отменить такие команды.
            if case .set = command, setsStopped.value { return Failure.cancelled.localizedDescription }
            return try deliver(command, connection).wait(until: deadline)
        } catch {
            return error.localizedDescription
        }
    }

    /// Для выхода: через `queue`, чтобы идти после уже отправленных. После рукопожатия команды уходят сразу все,
    /// не дожидаясь ответов: служба выполняет их по одной и по секунде на зависший вентилятор, так что по очереди
    /// второй мог бы не успеть уйти. Ушедшие служба доделает, даже если клиента уже нет.
    static func sendAll(
        _ commands: [Command],
        on queue: DispatchQueue,
        within budget: TimeInterval = quitBudget,
        finished: @escaping @Sendable (Command, String?) -> Void
    ) {
        // Пустой список — обычный случай: подключение подняло бы root-службу без дела.
        guard !commands.isEmpty else { return }
        if refusesRealService {
            commands.forEach { finished($0, "Стенд не говорит с настоящей службой вентиляторов") }
            return
        }
        let deadline = DispatchTime.now() + budget
        runBounded(on: queue, within: budget) {
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
    }

    /// Работа через `queue`, но ждём не дольше `budget`. Если очередь занята дольше половины срока, работа идёт
    /// мимо неё, а `set`, стоящие в ней, отменяются: иначе они перебили бы «Авто». Отмена снимается, когда очередь
    /// дойдёт до нашего места: всё, что поставят после, идёт как обычно.
    static func runBounded(on queue: DispatchQueue, within budget: TimeInterval = quitBudget, work: @escaping @Sendable () -> Void) {
        let deadline = DispatchTime.now() + budget
        let done = DispatchSemaphore(value: 0)
        let claimed = Latch()
        let finishing: @Sendable () -> Void = {
            work()
            done.signal()
        }
        queue.async {
            if claimed.take() { finishing() } else { setsStopped.value = false }
        }
        guard done.wait(timeout: .now() + budget / 2) == .timedOut else { return }
        // Флаг раньше захвата: иначе очередь могла бы снять его раньше, чем он поставлен, и set остались бы отменены навсегда.
        setsStopped.value = true
        if claimed.take() {
            DispatchQueue(label: "utilitumus.fans.quit").async(execute: finishing)
        } else {
            // Очередь успела: работа уже идёт оттуда, она просто долгая.
            setsStopped.value = false
        }
        _ = done.wait(timeout: deadline)
    }

    private static let setsStopped = Latch()

    /// Стенд (сборка со швом, но не с поддельной службой `FAN_TEST_FAKE_SMC`) не подключается к настоящей службе:
    /// через неё он выставил бы обороты настоящих вентиляторов.
    private static var refusesRealService: Bool {
        #if KIT_TEST_DEFAULTS && !FAN_TEST_FAKE_SMC
        return Kit.standRefuses("XPC настоящей службы вентиляторов")
        #else
        return false
        #endif
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

    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var state = false

        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return state }
            set { lock.lock(); state = newValue; lock.unlock() }
        }

        /// true только первому.
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            defer { state = true }
            return !state
        }
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
