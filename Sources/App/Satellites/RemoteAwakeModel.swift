import Combine
import Foundation

/// Модель вкладки «Не спать», когда модуль ведёт утилита. Показывает последнее известное состояние и работает
/// только через связь: своего assertion у центра нет. Перечитывает по `statusChanged`, при смене статуса в реестре
/// и при открытии экрана, без опроса: отсчёт времени экран считает сам по `endDate`.
@MainActor
final class RemoteAwakeModel: NSObject, AwakeModel {
    @Published private(set) var state: AwakeState
    /// Последнее чтение удалось. Сбой действия этого не меняет: на экране остаётся прежнее состояние и текст.
    @Published private(set) var responding = true
    /// Короткий текст: последнее действие не выполнено.
    @Published private(set) var actionError: String?

    private let client: LinkClient
    private let canRead: () -> Bool
    /// Ответы приходят асинхронно: опоздавший не должен затереть более новый.
    private var issued = 0
    private var applied = 0
    private var statusSub: AnyCancellable?

    /// `canRead`: нет бандла — нет и запроса, иначе launchd пытался бы поднять мёртвого агента.
    init(id: String, canRead: @escaping () -> Bool) {
        client = LinkClient(id: id)
        self.canRead = canRead
        // До первого ответа — сохранённые настройки: домен настроек у центра и утилиты один.
        state = AwakeState(isActive: false, endDate: nil,
                           keepDisplay: Kit.defaults.bool(forKey: AwakeController.displayKey),
                           duration: AwakeDuration(rawValue: Kit.defaults.integer(forKey: AwakeController.durationKey)) ?? .forever,
                           canStart: true)
        super.init()
        // `.deliverImmediately`: иначе неактивный центр получит пинок с большой задержкой.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(statusDidChange), name: KitLink.statusChanged(id),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: AwakeModel

    var isActive: Bool { state.isActive }
    var endDate: Date? { state.endDate }
    var canStart: Bool { state.canStart }
    var keepDisplay: Bool {
        get { state.keepDisplay }
        set { send(.setKeepDisplay(newValue)) }
    }
    var duration: AwakeDuration {
        get { state.duration }
        set { send(.setDuration(newValue.rawValue)) }
    }
    func toggle() { send(.toggle) }

    // MARK: Связь

    /// Реестр снова слышит утилиту или перестал: перечитать. Вкладка, карточка и меню видят одно и то же,
    /// какой бы экран сейчас ни был открыт.
    func follow(_ status: some Publisher<LinkStatus?, Never>) {
        statusSub = status.removeDuplicates().dropFirst().sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard canRead() else { return }
        Task { await read() }
    }

    func read() async {
        let ticket = issue()
        do {
            let new = try JSONDecoder().decode(AwakeState.self, from: await client.moduleState())
            guard take(ticket) else { return }
            state = new
            responding = true
            actionError = nil
        } catch {
            guard take(ticket) else { return }
            responding = false
        }
    }

    /// Применить у утилиты, затем показать её ответ. Сбой — прежнее состояние и текст.
    func perform(_ action: AwakeAction) async {
        let ticket = issue()
        do {
            let reply = try JSONDecoder().decode(AwakeReply.self, from: await client.moduleAction(JSONEncoder().encode(action)))
            guard take(ticket) else { return }
            state = reply.state
            responding = true
            actionError = reply.error
        } catch {
            actionError = "Модуль не ответил, попробуй ещё раз"
        }
    }

    private func send(_ action: AwakeAction) {
        Task { await perform(action) }
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

    @objc private func statusDidChange() {
        refresh()
    }
}
