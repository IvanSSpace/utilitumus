import Foundation

extension FnTrigger: Codable {}
extension LayoutMode: Codable {}
extension KeyboardFeature: Codable {}

/// То, что экран показывает. Новые поля добавляются только необязательными.
struct KeyboardState: Codable, Equatable, Sendable {
    /// Включённые фишки в порядке экрана. Строки: фишка новее центра не должна ломать разбор.
    var features: [String]
    var trigger: FnTrigger
    var mode: LayoutMode
    var currentName: String
    var tapActive: Bool
    var inputAccess: Bool
    var systemUsage: Int?
    var secureInputApp: String?
    var logTail: [KeyboardLogEntry]
    var logCount: Int
    var repairResult: String?
    var layouts: [KeyboardLayoutItem]
    var newAppLayout: String?
    var excludedApps: [String]
}

/// Что экран и чек-лист настройки могут попросить. Больше утилита ничего не примет.
/// Шаги чек-листа, которые снимают системные настройки. Центр знает их id, чтобы выполнить оба одним действием.
enum KeyboardSetupID {
    static let globe = "keyboard.globe"
    static let dictation = "keyboard.dictation"
}

enum KeyboardAction: Codable, Equatable, Sendable {
    case setFeature(feature: KeyboardFeature, on: Bool)
    case setTrigger(FnTrigger)
    case setMode(LayoutMode)
    case setNewAppLayout(String?)
    case addExcluded(String)
    case removeExcluded(String)
    case repair
    case copyLog
    case refreshAccess
    case refreshSystem
    case requestAccess
    case disableSystemAction
    case disableDictationDoubleFn
    case disableAllSystemActions

    /// Ровно одно известное действие и ровно его поля: см. `LinkActionFields`.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setFeature":
            try wire.fields("feature", "on")
            self = .setFeature(feature: try wire.field("feature"), on: try wire.field("on"))
        case "setTrigger": self = .setTrigger(try wire.value())
        case "setMode": self = .setMode(try wire.value())
        case "setNewAppLayout":
            // Без значения — «как было» (nil): синтезированное кодирование не пишет ключ для nil.
            if let id = try? wire.value(String.self) { self = .setNewAppLayout(id) } else {
                try wire.none()
                self = .setNewAppLayout(nil)
            }
        case "addExcluded": self = .addExcluded(try wire.value())
        case "removeExcluded": self = .removeExcluded(try wire.value())
        case "repair": try wire.none(); self = .repair
        case "copyLog": try wire.none(); self = .copyLog
        case "refreshAccess": try wire.none(); self = .refreshAccess
        case "refreshSystem": try wire.none(); self = .refreshSystem
        case "requestAccess": try wire.none(); self = .requestAccess
        case "disableSystemAction": try wire.none(); self = .disableSystemAction
        case "disableDictationDoubleFn": try wire.none(); self = .disableDictationDoubleFn
        case "disableAllSystemActions": try wire.none(); self = .disableAllSystemActions
        default: throw wire.refuse()
        }
    }
}
