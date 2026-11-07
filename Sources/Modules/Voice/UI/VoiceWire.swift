import Foundation

extension VoiceModel: Codable {}
extension VoiceMode: Codable {}

/// Режим проверки (решение Q6). Распознанный текст бывает в состоянии только здесь.
struct VoiceTestState: Codable, Equatable {
    /// Дольше самой длинной записи: начатая в срок фраза успевает вернуться на экран.
    static let lifetime: TimeInterval = 15 * 60
    static let maxPhrase = 4000

    /// Последняя распознанная фраза.
    var phrase: String?
    /// Растёт с каждой фразой: две одинаковые подряд экран отличит.
    var serial: Int
}

struct VoiceModelRow: Codable, Equatable {
    var model: VoiceModel
    var status: VoiceModelStatus
}

/// То, что экран показывает. Уровень звука остаётся в утилите; идёт ли запись, нужно карточке дашборда («идёт запись…»),
/// и это уходит только в ответе на запрос по проверенной связи, не в строке статуса и не в уведомлениях.
struct VoiceState: Codable, Equatable {
    var hotKeyLabel: String
    var hotKeyError: String?
    var mode: VoiceMode
    var micUID: String?
    var excludedApps: [String]
    var axTrusted: Bool
    var models: [VoiceModelRow]
    var selected: VoiceModel
    /// nil — режим проверки выключен.
    var test: VoiceTestState?
    var recording: Bool
}

/// Что экран может попросить. Больше модуль ничего не примет.
enum VoiceAction: Codable, Equatable {
    case setMode(VoiceMode)
    case setMic(String?)
    case addExcluded(String)
    case removeExcluded(String)
    case setHotKey(keyCode: UInt32, modifiers: UInt32)
    case resetHotKey
    case suspendHotKey
    case resumeHotKey
    case refreshPermissions
    case requestAccessibility
    case download(VoiceModel)
    case cancelDownload(VoiceModel)
    case deleteModel(VoiceModel)
    case selectModel(VoiceModel)
    case beginTest
    case endTest
    /// Кнопка «Проверить»: начать запись в поле проверки или закончить её.
    case toggleTestRecording

    /// Строго: ровно одно известное действие и ровно его поля. Кодирование остаётся синтезированным.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setMode": self = .setMode(try wire.value())
        case "setMic":
            // nil кодируется пустым значением: ключа `_0` в нём нет.
            if let uid: String = try? wire.value() { self = .setMic(uid) } else { try wire.none(); self = .setMic(nil) }
        case "addExcluded": self = .addExcluded(try wire.value())
        case "removeExcluded": self = .removeExcluded(try wire.value())
        case "setHotKey":
            try wire.fields("keyCode", "modifiers")
            self = .setHotKey(keyCode: try wire.field("keyCode"), modifiers: try wire.field("modifiers"))
        case "resetHotKey": try wire.none(); self = .resetHotKey
        case "suspendHotKey": try wire.none(); self = .suspendHotKey
        case "resumeHotKey": try wire.none(); self = .resumeHotKey
        case "refreshPermissions": try wire.none(); self = .refreshPermissions
        case "requestAccessibility": try wire.none(); self = .requestAccessibility
        case "download": self = .download(try wire.value())
        case "cancelDownload": self = .cancelDownload(try wire.value())
        case "deleteModel": self = .deleteModel(try wire.value())
        case "selectModel": self = .selectModel(try wire.value())
        case "beginTest": try wire.none(); self = .beginTest
        case "endTest": try wire.none(); self = .endTest
        case "toggleTestRecording": try wire.none(); self = .toggleTestRecording
        default: throw wire.refuse()
        }
    }
}

extension VoiceState {
    /// Что экран покажет до первого ответа утилиты: сохранённые настройки и модели на диске. Контроллер не создаётся.
    static func stored() -> VoiceState {
        let d = Kit.defaults
        let keyCode = d.object(forKey: VoiceKeys.keyCode) as? UInt32 ?? VoiceHotKey.defaultKeyCode
        let modifiers = d.object(forKey: VoiceKeys.modifiers) as? UInt32 ?? VoiceHotKey.defaultModifiers
        return VoiceState(
            hotKeyLabel: VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers), hotKeyError: nil,
            mode: d.string(forKey: VoiceKeys.mode).flatMap(VoiceMode.init(rawValue:)) ?? .toggle, micUID: d.string(forKey: VoiceKeys.mic),
            excludedApps: d.stringArray(forKey: VoiceKeys.excluded) ?? [],
            // Подсказка про «Универсальный доступ» не должна мигнуть до ответа.
            axTrusted: true,
            models: VoiceModel.allCases.map { VoiceModelRow(model: $0, status: VoiceModelFiles.isInstalled($0) ? .installed : .notInstalled) },
            selected: VoiceModelFiles.selected, test: nil,
            recording: false)
    }
}
