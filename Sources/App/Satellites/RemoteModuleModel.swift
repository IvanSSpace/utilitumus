import Combine
import Foundation

/// Как модель говорит с утилитой. По умолчанию `LinkClient`; проверкам нужен управляемый порядок ответов.
struct RemoteModuleLink {
    var state: @MainActor () async throws -> Data
    var action: @MainActor (Data) async throws -> Data
    var setWatch: @MainActor (LinkWatch) -> Void
    var onPing: @MainActor (@escaping @MainActor () -> Void) -> Void

    @MainActor static func live(id: String) -> RemoteModuleLink {
        let client = LinkClient(id: id)
        return RemoteModuleLink(
            state: { try await client.moduleState() },
            action: { try await client.moduleAction($0) },
            setWatch: { client.setWatch($0) },
            onPing: { handler in client.onStateChanged = handler })
    }
}

/// Модель вкладки, когда модуль ведёт утилита: показывает последнее известное состояние и работает только через связь.
/// Перечитывает по пингу от утилиты, по `statusChanged`, при смене статуса в реестре и при открытии экрана, без опроса.
///
/// `optimistic` показывает действие сразу, не дожидаясь ответа: на экране подтверждённое утилитой состояние плюс ещё
/// не отвеченные действия. Ответ заменяет подтверждённое, поэтому отказ откатывается сам. Устаревший ответ отбрасывается
/// по номеру. `coalesceKey` для частых действий (ползунок): в пути одно на ключ, ждёт только последнее значение.
@MainActor
class RemoteModuleModel<State: Codable & Equatable & Sendable, Action: Codable & Sendable>: ObservableObject {
    @Published private(set) var state: State
    /// Чтение удалось. Сбой действия этого не меняет: на экране остаётся прежнее состояние и текст.
    @Published private(set) var responding = true
    /// Короткий текст: последнее действие не выполнено.
    @Published private(set) var actionError: String?

    /// Один сбой чтения ещё не «не отвечает»: утилита могла быть занята. Второе чтение идёт сразу.
    private static var toleratedFailedReads: Int { 1 }
    /// Такой ответ разбирается не на главном потоке.
    private static var offMainDecodeBytes: Int { 32 * 1024 }

    private final class Pending {
        let ticket: Int
        let action: Action
        /// Сколько билетов было выдано, когда действие ушло к утилите; nil — ещё не ушло.
        var sentAt: Int?

        init(ticket: Int, action: Action) {
            self.ticket = ticket
            self.action = action
        }
    }

    private let link: RemoteModuleLink
    private let canRead: () -> Bool
    private let optimistic: (inout State, Action) -> Void
    private let coalesceKey: (Action) -> String?
    private let baseWatch: LinkWatch
    private let dashboardWatch: LinkWatch
    private var screenIsOpen = false
    private var dashboardIsVisible = false

    /// Что подтвердила утилита.
    private var confirmed: State
    private var pending: [Pending] = []
    private var waiting: [String: Pending] = [:]
    private var sending: Set<String> = []
    /// Ответы приходят асинхронно: опоздавший не должен затереть более новый.
    private var issued = 0
    private var applied = 0
    private var lastActionAnswered = 0
    private var failedReads = 0
    private var reading = false
    private var readAgain = false
    private var statusSub: AnyCancellable?
    private var statusObserver: LinkStatusObserver?

    /// `canRead`: нет бандла — нет и запроса, иначе launchd пытался бы поднять мёртвого агента.
    /// `baseWatch`: `.changes`, если модель нужна и при закрытом экране (пункт меню).
    /// `dashboardWatch`: `.changes`, если карточке дашборда нужны живые данные; действует, только пока дашборд на экране.
    /// `.screen` — если утилита шлёт и меряет только при аренде экрана (вентиляторы, нагрузка).
    init(id: String, initial: State, baseWatch: LinkWatch = .none, dashboardWatch: LinkWatch = .none, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool,
         optimistic: @escaping (inout State, Action) -> Void = { _, _ in },
         coalesceKey: @escaping (Action) -> String? = { _ in nil }) {
        self.link = link ?? .live(id: id)
        self.canRead = canRead
        self.optimistic = optimistic
        self.coalesceKey = coalesceKey
        self.baseWatch = baseWatch
        self.dashboardWatch = dashboardWatch
        state = initial
        confirmed = initial
        self.link.setWatch(baseWatch)
        self.link.onPing { [weak self] in self?.pinged() }
        statusObserver = LinkStatusObserver(id: id) { [weak self] in self?.refresh() }
    }

    // MARK: Дашборд и меню

    /// Модель меняется: карточка дашборда пересчитывается.
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in }.eraseToAnyPublisher() }

    /// Карточка дашборда. `base` собран из статуса утилиты (строка, оранжевое, быстрое действие). Модуль, чья карточка
    /// показывает то, что в строку статуса не помещается (обратный отсчёт, градусы, играющие программы), переопределяет.
    func dashboardState(base: DashState, status: LinkStatus?) -> DashState { base }

    /// Кнопка карточки, которой нужно подтверждение (`ask`). По умолчанию — без него.
    func performDashboardAction(ask: (DashConfirmation) -> Void) -> Bool { performDashboardAction() }

    /// Кнопка карточки, которую ведёт сама модель. false — нажатие идёт быстрым действием из статуса.
    func performDashboardAction() -> Bool { false }

    /// false — пункты меню-бара этого модуля рисует он сам, а не быстрые действия статуса.
    var menuUsesQuickActions: Bool { true }

    /// Реестр снова слышит утилиту или перестал: перечитать. Вкладка, карточка и меню видят одно и то же,
    /// какой бы экран сейчас ни был открыт.
    func follow(_ status: some Publisher<LinkStatus?, Never>) {
        statusSub = status.removeDuplicates().dropFirst().sink { [weak self] _ in self?.refresh() }
    }

    /// Аренда экрана. Сам вызов соединение не поднимает: его поднимет ближайшее чтение.
    func setScreenOpen(_ open: Bool) {
        screenIsOpen = open
        applyWatch()
    }

    /// Дашборд на экране: утилита сообщает о смене состояния, пока он виден, и молчит, когда нет.
    func setDashboardVisible(_ visible: Bool) {
        guard dashboardIsVisible != visible else { return }
        dashboardIsVisible = visible
        applyWatch()
    }

    private func applyWatch() {
        if screenIsOpen { return link.setWatch(.screen) }
        link.setWatch(dashboardIsVisible && dashboardWatch.rawValue > baseWatch.rawValue ? dashboardWatch : baseWatch)
    }

    func refresh() {
        guard canRead() else { return }
        Task { await read() }
    }

    /// Первый сбой повторяется сразу, и `read` возвращается уже с итогом.
    func read() async {
        let ticket = issue()
        reading = true
        defer {
            reading = false
            if readAgain {
                readAgain = false
                refresh()
            }
        }
        do {
            let new = try await decode(State.self, await link.state())
            guard take(ticket) else { return }
            confirmed = new
            // Действия, ушедшие раньше этого чтения, утилита уже выполнила: сообщения одного соединения идут по порядку.
            // Ещё не ушедшие остаются на экране: чтение их не видело.
            pending.removeAll { ($0.sentAt ?? .max) < ticket }
            failedReads = 0
            setResponding(true)
            if ticket > lastActionAnswered { setError(nil) }
            show()
        } catch {
            guard take(ticket) else { return }
            failedReads += 1
            if failedReads > Self.toleratedFailedReads {
                setResponding(false)
            } else {
                await read()
            }
        }
    }

    /// Показать сразу, применить у утилиты, затем показать её ответ. Сбой — прежнее состояние и текст.
    func perform(_ action: Action) async {
        await deliver(enqueue(action))
    }

    /// Показ идёт синхронно: привязка экрана видит новое значение до первой паузы.
    func send(_ action: Action) {
        let item = enqueue(action)
        Task { await deliver(item) }
    }

    private func enqueue(_ action: Action) -> Pending {
        let item = Pending(ticket: issue(), action: action)
        pending.append(item)
        if let key = coalesceKey(action) {
            if let replaced = waiting[key] { pending.removeAll { $0.ticket == replaced.ticket } }
            waiting[key] = item
        }
        show()
        return item
    }

    private func deliver(_ item: Pending) async {
        guard let key = coalesceKey(item.action) else {
            await exchange(item)
            return
        }
        guard sending.insert(key).inserted else { return }
        while let next = waiting.removeValue(forKey: key) {
            await exchange(next)
        }
        sending.remove(key)
    }

    private func exchange(_ item: Pending) async {
        item.sentAt = issued
        do {
            let reply = try await decode(LinkReply<State>.self, await link.action(LinkWire.encoded(item.action)))
            pending.removeAll { $0.ticket == item.ticket }
            if take(item.ticket) {
                confirmed = reply.state
                failedReads = 0
                setResponding(true)
            }
            answerAction(item.ticket, error: reply.error)
        } catch {
            pending.removeAll { $0.ticket == item.ticket }
            answerAction(item.ticket, error: "Модуль не ответил, попробуй ещё раз")
        }
        show()
    }

    /// Текст отказа важен, даже если состояние в этом ответе уже устарело.
    private func answerAction(_ ticket: Int, error: String?) {
        guard ticket > lastActionAnswered else { return }
        lastActionAnswered = ticket
        setError(error)
    }

    private func show() {
        var shown = confirmed
        for item in pending { optimistic(&shown, item.action) }
        if shown != state { state = shown }
    }

    private func setResponding(_ value: Bool) {
        if responding != value { responding = value }
    }

    private func setError(_ value: String?) {
        if actionError != value { actionError = value }
    }

    private func pinged() {
        if reading {
            readAgain = true
        } else {
            refresh()
        }
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, _ data: Data) async throws -> T {
        if data.count < Self.offMainDecodeBytes { return try JSONDecoder().decode(type, from: data) }
        return try await Task.detached { try JSONDecoder().decode(type, from: data) }.value
    }

    private func issue() -> Int {
        issued += 1
        return issued
    }

    private func take(_ ticket: Int) -> Bool {
        guard ticket > applied else { return false }
        applied = ticket
        return true
    }
}

extension RemoteModuleModel: RemoteModuleSurface {}
