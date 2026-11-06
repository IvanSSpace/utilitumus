import Combine
import SwiftUI

/// «Стеш программ» внутри своей утилиты. Список программ, наблюдатели и запись стеша появляются только в `start`.
/// Настоящий `StashStore` читает `StashedApps` из `Kit.defaults` — того же домена, что и встроенный стеш центра,
/// поэтому записанное одним видно другому. Пишет всегда один: либо утилита между `start` и остановкой, либо центр.
@MainActor
final class StashModule: SatelliteModule {
    let module = Module.stash
    /// Нет до `start`: `init` стеша читает запись и может её переписать, а у стоящего модуля этого быть не должно.
    private(set) var store: StashStore?
    private let subject = PassthroughSubject<Void, Never>()
    private var subscription: AnyCancellable?

    init() {}

    /// Запись и сценарии читаются заново: пока модуль стоял, их менял стеш центра.
    func start() {
        guard store == nil else { return }
        let store = StashStore()
        #if KIT_TEST_DEFAULTS
        // Стенд не видит настоящих программ и не может закрыть или запустить ни одну.
        store.system = StashSystem(runningApps: { [] }, open: { _, _ in throw CocoaError(.fileNoSuchFile) })
        #endif
        // Замер идёт только пока экран открыт: `screenOpen` включит.
        store.screenLease = false
        subscription = store.objectWillChange.sink { [subject] _ in subject.send() }
        self.store = store
        store.start()
    }

    func stop() {
        store?.stop()
        subscription = nil
        store = nil
    }

    /// Закрытие программ нельзя прерывать на полуслове: запись уже сделана, а возврат ещё нет.
    var mayRestart: Bool { store.map { $0.busy == nil && $0.pendingBusy == nil } ?? true }

    func screenOpen(_ open: Bool) {
        store?.screenLease = open
        // Экран просит замер только раз в 10 с, а открылся он сейчас.
        if open { store?.requestUsage() }
    }

    /// Только количество: имена программ в строку статуса не идут, её видят все на этом Mac.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        if let count = store?.stashed.count, count > 0 { return "Спрятано \(count) · можно вернуть" }
        return "Готов спрятать программы"
    }

    var quickActions: [LinkQuickAction] {
        guard let store, !store.stashed.isEmpty, store.busy == nil, store.pendingBusy == nil else { return [] }
        return [LinkQuickAction(title: "Вернуть", icon: "arrow.uturn.backward", action: LinkWire.encoded(StashAction.restore))]
    }

    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: Self.accessStep, title: "Универсальный доступ", why: "Чтобы вернуть окна на места",
                       icon: "lock.shield.fill", buttonTitle: "Дать доступ…", done: AXIsProcessTrusted())]
    }

    static let accessStep = "stash.ax"

    func performSetupStep(_ id: String) -> String? {
        store?.requestAccess()
        return nil
    }

    func state() -> Data { LinkWire.encoded(store?.wireState ?? Self.emptyState) }

    /// Действия принимает только запущенный модуль: пока он стоит, запись стеша может менять центр.
    func handle(_ action: Data) -> Data {
        guard let store else {
            return LinkWire.encoded(LinkReply(state: Self.emptyState, error: "Стеш сейчас ведёт центр"))
        }
        return store.handle(action)
    }

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    func windowRoot() -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(StashView(store: store))
    }

    private static let emptyState = StashState(running: [], stubborn: [], stashed: [], usage: [:], scenarios: [], busy: nil, report: nil)
}
