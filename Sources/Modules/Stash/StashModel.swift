import AppKit

/// Программа на экране Стеша. Значок здесь только для рисования: по связи он не ходит.
struct StashProgram: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    /// Сколько окон вернётся; нужно только плашкам «Вернуть».
    var windowCount = 0
    var id: String { bundleID }
}

/// Всё, что экран Стеша берёт у своей модели. Работает ли модуль здесь же (`StashStore`)
/// или в утилите, экран не знает.
@MainActor
protocol StashModel: ObservableObject {
    /// Порядок как в списке программ: по имени.
    var runningPrograms: [StashProgram] { get }
    var stubbornPrograms: [StashProgram] { get }
    var stashedPrograms: [StashProgram] { get }
    var usage: [String: AppUsage] { get }
    var scenarios: [StashScenario] { get }
    var busy: String? { get }
    var report: RestoreReport? { get }
    /// Отмеченные запущенные программы — то, что закроет «Спрятать выбранные».
    var selectedBundleIDs: [String] { get }
    /// Что перечислит подтверждение перед закрытием.
    var selectedNames: [String] { get }
    func isClosing(_ bundleID: String) -> Bool
    func icon(forBundleID id: String) -> NSImage?

    func start()
    func refreshAccess()
    func refreshUsage() async
    func setClosing(_ bundleID: String, _ closing: Bool)
    func selectOnlyHeavy()
    func stashSelected() async
    func stash(_ scenario: StashScenario) async
    func restore() async
    func forceTerminate(_ bundleID: String)
    func forceTerminateAll()
    @discardableResult func addScenario(name: String) -> Bool
    func updateScenario(_ id: UUID)
    func renameScenario(_ id: UUID, to name: String)
    func deleteScenario(_ id: UUID)
    func select(_ scenario: StashScenario)
}

extension StashModel {
    /// Самые тяжёлые сверху; пока замеров нет — по имени.
    var programsByWeight: [StashProgram] {
        runningPrograms.sorted { (usage[$0.bundleID]?.memoryMB ?? 0) > (usage[$1.bundleID]?.memoryMB ?? 0) }
    }

    /// Запущенные сейчас программы сценария.
    func runningPrograms(of scenario: StashScenario) -> [StashProgram] {
        runningPrograms.filter { scenario.bundleIDs.contains($0.bundleID) }
    }
}

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
