import Foundation
import SwiftUI

/// Готовый список для экрана: сторонние агенты launchd и боты из bots.toml.
struct BackgroundData: Sendable {
    var agents: [AgentItem] = []
    var bots: [BotItem] = []

    var isEmpty: Bool { agents.isEmpty && bots.isEmpty }
}

/// Сборка списка по снимку замера. Вне главного потока: читает plist и раз в минуту зовёт `launchctl print-disabled`
/// (результаты кэшируются в `LaunchState`).
enum BackgroundCollector {
    static func collect(_ s: LoadSnapshot) -> BackgroundData {
        let bots = BotRegistry.load()
        // В снимке защита ботов уже есть; добавляем её и здесь, чтобы список не зависел от того, кто собрал снимок.
        let fenced = s.fence.merging(BotRegistry.fence(bots, procs: s.procs, tree: s.tree, launchd: s.launchd)) { cur, _ in cur }
        return BackgroundData(
            agents: LaunchAgents.collect(procs: s.procs, tree: s.tree, launchd: s.launchd, bots: bots, fenced: fenced),
            bots: bots.map { BotRegistry.status($0, procs: s.procs, tree: s.tree, launchd: s.launchd) })
    }
}

/// Состояние вкладки «Фоновое»: список, ожидающее подтверждения действие, журнал.
/// Список обновляется вместе с замером (раз в 3 с, пока экран открыт); пустой список прячет вкладку.
@MainActor
final class BackgroundStore: ObservableObject {
    @Published private(set) var data = BackgroundData()
    /// Действие, ждущее подтверждения.
    @Published var pending: BackgroundPlan?
    @Published private(set) var running = false
    @Published private(set) var journal: [ActionLog.Entry] = []

    /// Результат действия — наверх, в баннер экрана «Нагрузка».
    var onFinish: ((StopResult) -> Void)?

    private let executor = BackgroundExecutor()
    private var collecting = false
    private var queued: LoadSnapshot?
    private var lastSnapshot: LoadSnapshot?
    private var lastCollect = Date.distantPast
    /// Открыта вкладка «Фоновое»: список обновляется с каждым замером. Иначе — раз в `idleInterval`
    /// (нужно лишь знать, есть ли что показать: от этого зависит вкладка и сводка на «Обзоре»).
    private var tabOpen = false

    static let idleInterval: TimeInterval = 15

    var hasContent: Bool { !data.isEmpty }

    /// Экран сообщает, открыта ли вкладка «Фоновое». При открытии список собирается сразу.
    func setTabOpen(_ open: Bool) {
        guard open != tabOpen else { return }
        tabOpen = open
        if open, let s = lastSnapshot { update(from: s, force: true) }
    }

    /// Новый замер: пересобрать список. Если прошлая сборка ещё идёт, берём самый свежий снимок после неё.
    /// `force` — после действия или «Обновить»: не ждать очередного срока.
    func update(from s: LoadSnapshot, force: Bool = false) {
        lastSnapshot = s
        guard force || tabOpen || Date().timeIntervalSince(lastCollect) >= Self.idleInterval else { return }
        guard !collecting else { queued = s; return }
        collecting = true
        lastCollect = Date()
        Task {
            let d = await Task.detached(priority: .utility) { BackgroundCollector.collect(s) }.value
            data = d
            collecting = false
            if let q = queued {
                queued = nil
                update(from: q)
            }
        }
    }

    /// «Обновить»: флаги автозапуска перечитаются, не дожидаясь минуты.
    func forget() { LaunchState.shared.forget() }

    func reloadJournal() {
        Task { journal = await Task.detached(priority: .utility) { ActionLog.recent() }.value }
    }

    // MARK: Действия

    func request(_ agent: AgentItem, _ verb: AgentVerb) {
        guard !running else { return }
        pending = BackgroundPlan.agent(agent, verb)
    }

    func request(_ bot: BotItem, _ verb: BotVerb) {
        guard !running else { return }
        pending = BackgroundPlan.bot(bot, verb)
    }

    func cancel() {
        guard !running else { return }
        pending = nil
    }

    func confirm() {
        guard let plan = pending, !running else { return }
        running = true
        let executor = executor
        Task {
            let result = await Task.detached(priority: .userInitiated) { executor.execute(plan) }.value
            running = false
            pending = nil
            LaunchState.shared.forget()
            journal = ActionLog.recent()
            onFinish?(result)
        }
    }
}
