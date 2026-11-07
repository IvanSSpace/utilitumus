import AppKit

extension StashStore: StashModel {
    var runningPrograms: [StashProgram] { running.map(StashProgram.init) }
    var stubbornPrograms: [StashProgram] { stubborn.map(StashProgram.init) }
    var stashedPrograms: [StashProgram] {
        stashed.map { StashProgram(bundleID: $0.bundleID, name: $0.name, icon: icon(forPath: $0.path), windowCount: $0.windows.count) }
    }
    var selectedNames: [String] { selected.compactMap(\.localizedName) }
}

private extension StashProgram {
    init(_ entry: RunningEntry) { self.init(bundleID: entry.bundleID, name: entry.name, icon: entry.icon) }
}

extension StashView where Model == StashStore {
    /// Встроенный экран: модуль работает здесь же.
    init() { self.init(store: StashStore.shared) }
}

extension StashStore {
    static let maxScenarioName = 100
    static let maxScenarios = 100
    static let elsewhereText = "Стеш занят в другой программе"

    var wireState: StashState {
        func program(_ entry: RunningEntry) -> StashState.Program {
            StashState.Program(bundleID: entry.bundleID, name: entry.name, closing: isClosing(entry.bundleID))
        }
        return StashState(
            running: running.map(program),
            stubborn: stubborn.map(program),
            stashed: stashed.map { StashState.Stashed(bundleID: $0.bundleID, name: $0.name, windowCount: $0.windows.count) },
            usage: usage,
            scenarios: scenarios,
            busy: busy ?? pendingBusy,
            report: report
        )
    }

    /// Действие из связи в байтах. Самое длинное настоящее — `stash` со списком id программ, он короче 64 КБ.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: StashAction.self, limit: 64 * 1024, state: { wireState }) { handle($0) }
    }

    /// Действие из связи: сначала проверка, изменения только после неё. Возвращает текст отказа или nil.
    /// Долгие `stash` и `restore` отвечают сразу, дальше ход виден в `busy`.
    func handle(_ action: StashAction) -> String? {
        switch action {
        case .setClosing(let id, let closing):
            guard running.contains(where: { $0.bundleID == id }) else { return "Такой программы нет в списке" }
            setClosing(id, closing)
        case .selectOnlyHeavy:
            selectOnlyHeavy()
        case .stash(let ids):
            guard busy == nil, pendingBusy == nil else { return "Стеш занят" }
            guard !operationElsewhere else { return Self.elsewhereText }
            guard Self.isListed(ids, in: running) else { return "Список программ изменился" }
            let targets = running.filter { ids.contains($0.bundleID) }.map(\.app)
            guard targets.allSatisfy(Self.isEligible) else { return "Эту программу закрыть нельзя" }
            pendingBusy = Self.closingText
            Task {
                await stash(targets)
                pendingBusy = nil
            }
        case .restore:
            guard busy == nil, pendingBusy == nil else { return "Стеш занят" }
            guard !operationElsewhere else { return Self.elsewhereText }
            guard !stashed.isEmpty else { return "Возвращать нечего" }
            pendingBusy = Self.restoringText
            Task {
                await restore()
                pendingBusy = nil
            }
        case .forceTerminate(let ids):
            guard Self.isListed(ids, in: stubborn) else { return "Этой программы нет среди незакрывшихся" }
            for entry in stubborn where ids.contains(entry.bundleID) { forceTerminate(entry) }
        case .addScenario(let name):
            if let error = Self.nameError(name) { return error }
            guard !selectedBundleIDs.isEmpty else { return "Ни одна программа не отмечена" }
            guard scenarios.count < Self.maxScenarios else { return "Слишком много сценариев" }
            addScenario(name: name)
        case .updateScenario(let id):
            guard scenarios.contains(where: { $0.id == id }) else { return "Такого сценария нет" }
            guard !selectedBundleIDs.isEmpty else { return "Ни одна программа не отмечена" }
            updateScenario(id)
        case .renameScenario(let id, let name):
            guard scenarios.contains(where: { $0.id == id }) else { return "Такого сценария нет" }
            if let error = Self.nameError(name) { return error }
            renameScenario(id, to: name)
        case .deleteScenario(let id):
            guard scenarios.contains(where: { $0.id == id }) else { return "Такого сценария нет" }
            deleteScenario(id)
        case .selectScenario(let id):
            guard let scenario = scenarios.first(where: { $0.id == id }) else { return "Такого сценария нет" }
            select(scenario)
        case .refreshUsage:
            // Без аренды экрана замерять нечего; это не отказ: экран мог открыться чуть позже запроса.
            requestUsage()
        }
        return nil
    }

    /// Замер памяти по просьбе экрана. Окна у утилиты нет: вместо него аренда экрана. Идущий замер второй не запускает.
    func requestUsage() {
        guard screenLease, !usagePending else { return }
        usagePending = true
        Task {
            await measureUsage()
            usagePending = false
        }
    }

    /// Непустой список без повторов, и каждый id — из списка самого модуля.
    private static func isListed(_ ids: [String], in entries: [RunningEntry]) -> Bool {
        let listed = Set(entries.map(\.bundleID))
        return !ids.isEmpty && Set(ids).count == ids.count && ids.allSatisfy(listed.contains)
    }

    private static func nameError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Пустое название" }
        guard trimmed.count <= maxScenarioName else { return "Слишком длинное название" }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return "Недопустимые символы в названии" }
        return nil
    }
}
