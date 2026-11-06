import Foundation

/// Всё, что вкладка «Фоновое» берёт у своей модели.
@MainActor
protocol LoadBackgroundModel: ObservableObject {
    var data: BackgroundData { get }
    /// Действие, ждущее подтверждения.
    var prompt: LoadBackgroundPrompt? { get }
    var running: Bool { get }
    var journal: [ActionLog.Entry] { get }
    func setTabOpen(_ open: Bool)
    func reloadJournal()
    func request(_ agent: AgentItem, _ verb: AgentVerb)
    func request(_ bot: BotItem, _ verb: BotVerb)
    func cancel()
    func confirm(_ planID: UUID)
}

extension LoadBackgroundModel {
    var hasContent: Bool { !data.isEmpty }
}

/// Всё, что экран «Нагрузка» берёт у своей модели. Работает ли модуль здесь же (`LoadStore`)
/// или в утилите, экран не знает.
@MainActor
protocol LoadModel: ObservableObject {
    associatedtype Background: LoadBackgroundModel
    var background: Background { get }
    /// Данные замера; nil — первого ещё не было.
    var measure: LoadMeasure? { get }
    /// Меняется каждый замер: наблюдает только подвал экрана.
    var live: LiveStats { get }
    var history: HistoryWindow? { get }
    var palette: LoadPalette { get }
    /// Остановка, ждущая подтверждения.
    var stopPrompt: LoadStopPrompt? { get }
    var stopRunning: Bool { get }
    var notice: LoadNotice? { get }
    func refreshNow()
    func screenAppeared()
    func screenDisappeared()
    func requestStop(_ target: LoadStopTarget)
    func cancelStop()
    func confirmStop(_ planID: UUID)
    func dismissNotice()
}

/// Подписи экрана, общие для шапки и карточки памяти.
enum LoadText {
    static func pressureWord(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: return "норма"
        case .warn: return "высокое"
        case .critical: return "критическое"
        }
    }

    static func swapIsHot(_ m: MemoryTotals) -> Bool {
        m.swapTotalMB > 0 && Double(m.swapUsedMB) / Double(m.swapTotalMB) > 0.7
    }
}
