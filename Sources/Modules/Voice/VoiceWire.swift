import Foundation
import Carbon.HIToolbox

extension VoiceModel: Codable {}
extension VoiceController.Mode: Codable {}

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
    var status: VoiceModelStore.Status
}

/// То, что экран показывает. Уровень звука остаётся в утилите; идёт ли запись, нужно карточке дашборда («идёт запись…»),
/// и это уходит только в ответе на запрос по проверенной связи, не в строке статуса и не в уведомлениях.
struct VoiceState: Codable, Equatable {
    var hotKeyLabel: String
    var hotKeyError: String?
    var mode: VoiceController.Mode
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
    case setMode(VoiceController.Mode)
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

extension VoiceController {
    private static let maxExcluded = 200
    private static let maxFailureText = 300
    private static let knownModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    var wireState: VoiceState {
        let store = VoiceModelStore.shared
        return VoiceState(hotKeyLabel: hotKeyLabel, hotKeyError: hotKeyError, mode: mode, micUID: micUID,
                          excludedApps: excludedApps, axTrusted: axTrusted,
                          models: VoiceModel.allCases.map { VoiceModelRow(model: $0, status: Self.wireStatus(store.status($0))) },
                          selected: store.selected, test: liveTest,
                          recording: phase == .recording)
    }

    /// Что экран покажет до первого ответа утилиты: сохранённые настройки и модели на диске. Контроллер не создаётся.
    static func storedState() -> VoiceState {
        let d = Kit.defaults
        let keyCode = d.object(forKey: Key.keyCode) as? UInt32 ?? VoiceHotKey.defaultKeyCode
        let modifiers = d.object(forKey: Key.modifiers) as? UInt32 ?? VoiceHotKey.defaultModifiers
        return VoiceState(
            hotKeyLabel: VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers), hotKeyError: nil,
            mode: d.string(forKey: Key.mode).flatMap(Mode.init(rawValue:)) ?? .toggle, micUID: d.string(forKey: Key.mic),
            excludedApps: d.stringArray(forKey: Key.excluded) ?? [],
            // Подсказка про «Универсальный доступ» не должна мигнуть до ответа.
            axTrusted: true,
            models: VoiceModel.allCases.map { VoiceModelRow(model: $0, status: VoiceModelStore.isInstalled($0) ? .installed : .notInstalled) },
            selected: d.string(forKey: VoiceModelStore.selectedKey).flatMap(VoiceModel.init(rawValue:)) ?? .gigaam, test: nil,
            recording: false)
    }

    /// Прогресс приходит на каждый блок загрузки; на экран хватает целых процентов, тогда и состояние меняется реже.
    static func wireStatus(_ status: VoiceModelStore.Status) -> VoiceModelStore.Status {
        switch status {
        case let .downloading(progress): return .downloading(progress: (progress * 100).rounded(.down) / 100)
        case let .failed(text): return .failed(String(text.prefix(maxFailureText)))
        default: return status
        }
    }

    private static func isBundleID(_ text: String) -> Bool {
        (1...255).contains(text.utf8.count) && text.utf8.allSatisfy {
            switch $0 {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    /// Действие из связи. Самое длинное настоящее (идентификатор программы до 255 байт) короче 512.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: VoiceAction.self, limit: 512, state: { wireState }) { handle($0) }
    }

    /// Действие от экрана: сначала проверка, изменения только после неё. Возвращает текст отказа.
    func handle(_ action: VoiceAction) -> String? {
        let store = VoiceModelStore.shared
        switch action {
        case let .setMode(value):
            mode = value
        case let .setMic(uid):
            // Выбранный, но сейчас отключённый микрофон выбрать заново можно: так он остаётся в меню экрана.
            if let uid, uid != micUID, !VoiceRecorder.inputDevices().contains(where: { $0.uid == uid }) {
                return "Такого микрофона нет"
            }
            micUID = uid
        case let .addExcluded(id):
            guard Self.isBundleID(id) else { return "Это не идентификатор программы" }
            guard !Kit.isOurs(id) else { return "Utilitumus исключить нельзя" }
            guard excludedApps.contains(id) || excludedApps.count < Self.maxExcluded else { return "Список исключений полон" }
            addExcluded(id)
        case let .removeExcluded(id):
            guard excludedApps.contains(id) else { return "Этой программы нет в списке" }
            removeExcluded(id)
        case let .setHotKey(keyCode, modifiers):
            guard modifiers & ~Self.knownModifiers == 0, VoiceHotKey.isAcceptable(keyCode: keyCode, modifiers: modifiers) else {
                return "Такое сочетание не подходит"
            }
            setHotKey(keyCode: keyCode, modifiers: modifiers)
        case .resetHotKey:
            resetHotKey()
        case .suspendHotKey:
            suspendHotKey()
        case .resumeHotKey:
            resumeHotKey()
        case .refreshPermissions:
            refreshPermissions()
        case .requestAccessibility:
            requestAccessibility()
        case let .download(model):
            switch store.status(model) {
            case .notInstalled, .failed: store.download(model)
            case .installed: return "Модель уже скачана"
            case .downloading, .verifying: return "Модель уже качается"
            }
        case let .cancelDownload(model):
            guard case .downloading = store.status(model) else { return "Загрузка не идёт" }
            store.cancel(model)
        case let .deleteModel(model):
            guard store.status(model) == .installed else { return "Модель не установлена" }
            store.delete(model)
        case let .selectModel(model):
            guard store.status(model) == .installed else { return "Модель не установлена" }
            store.selected = model
        case .beginTest:
            beginTest()
        case .endTest:
            endTest()
        case .toggleTestRecording:
            return toggleTestRecording(intoState: true)
        }
        return nil
    }
}
