import AppKit

/// Модель вкладки «Стеш программ», когда модуль ведёт утилита. Закрывает и запускает программы только она:
/// сюда приходят id, имена, замеры и счётчики, а значки центр берёт у системы сам.
/// Долгие `stash` и `restore` утилита принимает сразу, ход виден в `busy` её состояния.
@MainActor
final class RemoteStashModel: RemoteModuleModel<StashState, StashAction>, StashModel {
    /// Значки по id: из `body` в `NSWorkspace` каждый раз ходить нельзя.
    private var runningIcons: [String: NSImage] = [:]
    private var stashedIcons: [String: NSImage] = [:]
    private var missingIcons: Set<String> = []

    init(id: String, canRead: @escaping () -> Bool) {
        // До первого ответа — записанное: домен настроек у центра и утилиты один. Читаем, не пишем.
        let defaults = Kit.defaults
        let scenarios = defaults.data(forKey: "StashScenarios").flatMap { try? JSONDecoder().decode([StashScenario].self, from: $0) } ?? []
        let stashed = defaults.data(forKey: "StashedApps").flatMap { try? JSONDecoder().decode([StashedApp].self, from: $0) } ?? []
        super.init(id: id,
                   initial: StashState(running: [], stubborn: [],
                                       stashed: stashed.map { StashState.Stashed(bundleID: $0.bundleID, name: $0.name, windowCount: $0.windows.count) },
                                       usage: [:], scenarios: scenarios, busy: nil, report: nil),
                   baseWatch: .none, dashboardWatch: .changes, canRead: canRead,
                   optimistic: { state, action in
                       // Закрытие, возврат и замер — забота утилиты: их ход виден по её ответу.
                       switch action {
                       case .setClosing(let id, let closing):
                           state.mark([id], closing: closing)
                       case .selectOnlyHeavy:
                           for entry in state.running { state.mark([entry.bundleID], closing: state.usage[entry.bundleID]?.isHeavy ?? false) }
                       case .selectScenario(let id):
                           guard let scenario = state.scenarios.first(where: { $0.id == id }) else { break }
                           for entry in state.running { state.mark([entry.bundleID], closing: scenario.bundleIDs.contains(entry.bundleID)) }
                       case .renameScenario(let id, let name):
                           let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                           if let i = state.scenarios.firstIndex(where: { $0.id == id }), !trimmed.isEmpty { state.scenarios[i].name = trimmed }
                       case .deleteScenario(let id):
                           state.scenarios.removeAll { $0.id == id }
                       case .stash, .restore, .forceTerminate, .addScenario, .updateScenario, .refreshUsage:
                           break
                       }
                   })
    }

    // MARK: Что видит экран

    private func program(_ item: StashState.Program) -> StashProgram {
        StashProgram(bundleID: item.bundleID, name: item.name, icon: icon(forBundleID: item.bundleID))
    }
    var runningPrograms: [StashProgram] { state.running.map(program) }
    var stubbornPrograms: [StashProgram] { state.stubborn.map(program) }
    var stashedPrograms: [StashProgram] {
        state.stashed.map { StashProgram(bundleID: $0.bundleID, name: $0.name, icon: stashedIcon($0.bundleID), windowCount: $0.windowCount) }
    }
    var usage: [String: AppUsage] { state.usage }
    var scenarios: [StashScenario] { state.scenarios }
    var busy: String? { state.busy }
    var report: RestoreReport? { state.report }
    var selectedBundleIDs: [String] { state.running.filter(\.closing).map(\.bundleID) }
    var selectedNames: [String] { state.running.filter(\.closing).map(\.name) }
    func isClosing(_ bundleID: String) -> Bool { (state.running + state.stubborn).first { $0.bundleID == bundleID }?.closing ?? true }

    /// Запущенная программа даёт свой значок, не запущенная (из сценария) — значок её .app.
    func icon(forBundleID id: String) -> NSImage? {
        if let cached = runningIcons[id] { return cached }
        if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon {
            runningIcons[id] = icon
            return icon
        }
        guard !missingIcons.contains(id) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            missingIcons.insert(id)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        runningIcons[id] = icon
        return icon
    }

    private func stashedIcon(_ id: String) -> NSImage? {
        if let cached = stashedIcons[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        stashedIcons[id] = icon
        return icon
    }

    // MARK: Дашборд

    // Карточка и меню те же, что у встроенного: число отмеченных программ и «Вернуть (N)» не помещаются в строку статуса.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        if !state.stashed.isEmpty {
            return DashState(text: "спрятано \(state.stashed.count) · можно вернуть",
                             actionTitle: "Вернуть", actionIcon: "arrow.uturn.backward")
        }
        if let busy { return DashState(text: busy) }
        let selected = selectedBundleIDs
        guard !selected.isEmpty else { return DashState(text: "нет программ для закрытия") }
        let freed = selected.reduce(0.0) { $0 + (usage[$1]?.memoryMB ?? 0) }
        let tail = freed > 0 ? " · ≈ \(memoryText(freed))" : ""
        return DashState(text: "выбрано \(selected.count)\(tail)", actionTitle: "Спрятать", actionIcon: "archivebox")
    }

    override func performDashboardAction(ask: (DashConfirmation) -> Void) -> Bool {
        if !state.stashed.isEmpty {
            Task { await restore() }
        } else {
            // Закрытие программ — только через подтверждение, как на экране Стеша.
            ask(DashConfirmation(
                title: "Закрыть \(programs(selectedBundleIDs.count))?",
                message: selectedNames.joined(separator: ", ") + "\n\nНесохранённое программы спросят сами.",
                button: "Закрыть и спрятать",
                run: { [weak self] in Task { await self?.stashSelected() } }))
        }
        return true
    }

    override var menuUsesQuickActions: Bool { false }

    // MARK: Действия

    func start() {}
    func refreshAccess() {}
    func refreshUsage() async { await perform(.refreshUsage) }
    func setClosing(_ bundleID: String, _ closing: Bool) { send(.setClosing(bundleID: bundleID, closing: closing)) }
    func selectOnlyHeavy() { send(.selectOnlyHeavy) }

    /// Ровно те программы, что были отмечены при нажатии, а не «отмеченные» к моменту ответа.
    func stashSelected() async {
        let ids = selectedBundleIDs
        guard !ids.isEmpty else { return }
        await perform(.stash(bundleIDs: ids))
    }

    func stash(_ scenario: StashScenario) async {
        let ids = runningPrograms(of: scenario).map(\.bundleID)
        guard !ids.isEmpty else { return }
        await perform(.stash(bundleIDs: ids))
    }

    func restore() async { await perform(.restore) }

    func forceTerminate(_ bundleID: String) { send(.forceTerminate(bundleIDs: [bundleID])) }

    func forceTerminateAll() {
        let ids = state.stubborn.map(\.bundleID)
        guard !ids.isEmpty else { return }
        send(.forceTerminate(bundleIDs: ids))
    }

    @discardableResult
    func addScenario(name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !selectedBundleIDs.isEmpty else { return false }
        send(.addScenario(name: name))
        return true
    }

    func updateScenario(_ id: UUID) { send(.updateScenario(id: id)) }
    func renameScenario(_ id: UUID, to name: String) { send(.renameScenario(id: id, name: name)) }
    func deleteScenario(_ id: UUID) { send(.deleteScenario(id: id)) }
    func select(_ scenario: StashScenario) { send(.selectScenario(id: scenario.id)) }
}

private extension StashState {
    mutating func mark(_ ids: [String], closing: Bool) {
        for i in running.indices where ids.contains(running[i].bundleID) { running[i].closing = closing }
        for i in stubborn.indices where ids.contains(stubborn[i].bundleID) { stubborn[i].closing = closing }
    }
}
