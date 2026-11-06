import Foundation

extension FnTrigger: Codable {}
extension LayoutMode: Codable {}
extension KeyboardFeature: Codable {}

/// То, что экран показывает. Новые поля добавляются только необязательными.
struct KeyboardState: Codable, Equatable {
    /// Включённые фишки в порядке экрана. Строки: фишка новее центра не должна ломать разбор.
    var features: [String]
    var trigger: FnTrigger
    var mode: LayoutMode
    var currentName: String
    var tapActive: Bool
    var inputAccess: Bool
    var systemUsage: Int?
    var secureInputApp: String?
    var logTail: [KeyboardLog.Entry]
    var logCount: Int
    var repairResult: String?
    var layouts: [KeyboardLayoutItem]
    var newAppLayout: String?
    var excludedApps: [String]
}

/// Что экран и чек-лист настройки могут попросить. Больше утилита ничего не примет.
enum KeyboardAction: Codable, Equatable {
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
}

extension KeyboardController {
    static let maxExcludedApps = 200
    static let maxBundleIDLength = 255
    private static let fnOffText = "Фишка «Язык по Fn» выключена"

    var wireState: KeyboardState {
        KeyboardState(features: KeyboardFeature.allCases.filter(isOn).map(\.rawValue),
                      trigger: trigger, mode: mode, currentName: currentName, tapActive: tapActive,
                      inputAccess: inputAccess, systemUsage: systemUsage, secureInputApp: secureInputApp,
                      logTail: logTail, logCount: logCount, repairResult: repairResult, layouts: layouts,
                      newAppLayout: newAppLayout, excludedApps: excludedApps)
    }

    /// Действие из связи: сначала проверка, изменения только после неё. Текст — почему не выполнено.
    func handle(_ action: KeyboardAction) -> String? {
        switch action {
        case .setFeature(let feature, let on):
            guard feature.isAvailable else { return "Эта фишка пока не работает" }
            setFeature(feature, on: on)
        case .setTrigger(let value):
            trigger = value
        case .setMode(let value):
            mode = value
        case .setNewAppLayout(let id):
            if let id, !layouts.contains(where: { $0.id == id }) { return "Такой раскладки нет среди включённых" }
            newAppLayout = id
        case .addExcluded(let id):
            guard Self.isBundleID(id) else { return "Это не идентификатор приложения" }
            guard excludedApps.contains(id) || excludedApps.count < Self.maxExcludedApps else { return "Список приложений полон" }
            addExcluded(id)
        case .removeExcluded(let id):
            guard excludedApps.contains(id) else { return "Такого приложения нет в списке" }
            removeExcluded(id)
        case .repair:
            repair()
        case .copyLog:
            copyLog()
        case .refreshAccess:
            refreshAccess()
        case .refreshSystem:
            refreshSystem()
        // Шаги чек-листа есть только у включённого «Языка по Fn»: без него некому держать и возвращать настройку.
        case .requestAccess:
            guard isOn(.fnLanguage) else { return Self.fnOffText }
            requestAccess()
        case .disableSystemAction:
            guard isOn(.fnLanguage) else { return Self.fnOffText }
            disableSystemAction()
        case .disableDictationDoubleFn:
            guard isOn(.fnLanguage) else { return Self.fnOffText }
            disableDictationDoubleFn()
        case .disableAllSystemActions:
            guard isOn(.fnLanguage) else { return Self.fnOffText }
            disableAllSystemActions()
        }
        return nil
    }

    static func isBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxBundleIDLength && id.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: return true  // цифры, буквы, - . _
            default: return false
            }
        }
    }
}
