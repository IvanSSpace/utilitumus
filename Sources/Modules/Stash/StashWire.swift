import Foundation

/// То, что вкладка центра показывает на экране. Пути, кадры окон и хэши заголовков сюда не входят.
struct StashState: Codable, Equatable {
    struct Program: Codable, Equatable {
        var bundleID: String
        var name: String
        /// Закроет ли его «Спрятать выбранные».
        var closing: Bool
    }

    struct Stashed: Codable, Equatable {
        var bundleID: String
        var name: String
        var windowCount: Int
    }

    var running: [Program]
    var stubborn: [Program]
    var stashed: [Stashed]
    var usage: [String: AppUsage]
    var scenarios: [StashScenario]
    var busy: String?
    var report: RestoreReport?
}

/// Что вкладка центра может попросить. Больше утилита ничего не примет.
/// Программы называются только id из её же списков: ни путей, ни pid.
enum StashAction: Codable, Equatable {
    case setClosing(bundleID: String, closing: Bool)
    case selectOnlyHeavy
    /// Ровно те программы, что были в подтверждении. «Закрыть отмеченные» не годится: за время
    /// ответа в список могла попасть новая программа, а новая по умолчанию отмечена.
    case stash(bundleIDs: [String])
    case restore
    case forceTerminate(bundleIDs: [String])
    case addScenario(name: String)
    case updateScenario(id: UUID)
    case renameScenario(id: UUID, name: String)
    case deleteScenario(id: UUID)
    case selectScenario(id: UUID)
    /// Экран открыт: замерить память и процессор.
    case refreshUsage
}

extension StashStore {
    static let maxScenarioName = 100
    static let maxScenarios = 100

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
            // Замер уже идёт — второй `ps` не нужен. Окна у утилиты нет: раз экран открыт, проверять её окно незачем.
            guard !usagePending else { return nil }
            usagePending = true
            Task {
                await measureUsage()
                usagePending = false
            }
        }
        return nil
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
