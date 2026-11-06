import Foundation

/// То, что вкладка центра показывает на экране. Пути, кадры окон и хэши заголовков сюда не входят.
struct StashState: Codable, Equatable, Sendable {
    struct Program: Codable, Equatable, Sendable {
        var bundleID: String
        var name: String
        /// Закроет ли его «Спрятать выбранные».
        var closing: Bool
    }

    struct Stashed: Codable, Equatable, Sendable {
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
enum StashAction: Codable, Equatable, Sendable {
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

    /// Разбор строгий: ровно одно известное действие и ровно его поля, всё лишнее — ошибка.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setClosing":
            try wire.fields("bundleID", "closing")
            self = .setClosing(bundleID: try wire.field("bundleID"), closing: try wire.field("closing"))
        case "selectOnlyHeavy":
            try wire.none()
            self = .selectOnlyHeavy
        case "stash":
            try wire.fields("bundleIDs")
            self = .stash(bundleIDs: try wire.field("bundleIDs"))
        case "restore":
            try wire.none()
            self = .restore
        case "forceTerminate":
            try wire.fields("bundleIDs")
            self = .forceTerminate(bundleIDs: try wire.field("bundleIDs"))
        case "addScenario":
            try wire.fields("name")
            self = .addScenario(name: try wire.field("name"))
        case "updateScenario":
            try wire.fields("id")
            self = .updateScenario(id: try wire.field("id"))
        case "renameScenario":
            try wire.fields("id", "name")
            self = .renameScenario(id: try wire.field("id"), name: try wire.field("name"))
        case "deleteScenario":
            try wire.fields("id")
            self = .deleteScenario(id: try wire.field("id"))
        case "selectScenario":
            try wire.fields("id")
            self = .selectScenario(id: try wire.field("id"))
        case "refreshUsage":
            try wire.none()
            self = .refreshUsage
        default:
            throw wire.refuse()
        }
    }
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
