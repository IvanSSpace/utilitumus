import Foundation

/// Раскладка, включённая в системе: id и имя для меню.
struct KeyboardLayoutItem: Identifiable, Codable, Equatable {
    let id: String
    let name: String
}

/// Всё, что экран «Клавиатура» берёт у своей модели. Работает ли модуль здесь же
/// или в утилите, экран не знает.
@MainActor
protocol KeyboardModel: ObservableObject {
    var trigger: FnTrigger { get set }
    var mode: LayoutMode { get set }
    var currentName: String { get }
    var tapActive: Bool { get }
    var inputAccess: Bool { get }
    /// Значение системного действия 🌐; nil — ключа нет.
    var systemUsage: Int? { get }
    var secureInputApp: String? { get }
    var logTail: [KeyboardLogEntry] { get }
    var logCount: Int { get }
    var repairResult: String? { get }
    var layouts: [KeyboardLayoutItem] { get }
    var newAppLayout: String? { get set }
    var excludedApps: [String] { get }

    func isOn(_ feature: KeyboardFeature) -> Bool
    func setFeature(_ feature: KeyboardFeature, on: Bool)
    func addExcluded(_ id: String)
    func removeExcluded(_ id: String)
    func repair()
    func copyLog()
    func refreshAccess()
    func refreshSystem()
}

extension KeyboardModel {
    /// Название раскладки по id для экрана; удалённую из системы показываем как есть.
    func layoutName(_ id: String) -> String { layouts.first { $0.id == id }?.name ?? id }
}
