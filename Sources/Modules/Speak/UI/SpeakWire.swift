import Foundation

/// Что сейчас с чтением. Сам текст в состояние не попадает никогда: только фаза.
enum SpeakPhase: String, Codable, Equatable, Sendable {
    case idle, speaking, paused
}

/// Качество голоса по шкале системы: чем выше, тем лучше звучит. `regular` — системное `.default`
/// (имя «standard» с точкой в Sources/Modules ловит Tests/run-module-defaults-guard.sh).
enum SpeakVoiceQuality: Int, Codable, Comparable, Sendable {
    case regular = 1, enhanced = 2, premium = 3

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Голос системы в списке выбора.
struct SpeakVoiceRow: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Язык голоса в BCP 47: «ru-RU», «en-GB».
    var language: String
    var quality: SpeakVoiceQuality

    /// Язык без региона: голос закрепляется на него, «en-GB» и «en-US» — один язык «en».
    var languageKey: String { Self.languageKey(language) }

    static func languageKey(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}

/// То, что экран показывает. Только флаги, числа и готовые строки: выделенного текста здесь нет.
struct SpeakState: Codable, Equatable, Sendable {
    /// Множитель скорости, `SpeakSpeed.range`.
    var speed: Double
    /// Закреплённые голоса: язык (`SpeakVoiceRow.languageKey`) → id голоса. Языка в словаре нет — для него «Авто».
    var pinnedVoices: [String: String]
    var voices: [SpeakVoiceRow]
    var phase: SpeakPhase
    /// Почему не читаем: только строки из `SpeakMessage`.
    var message: String?
    var hotKeyLabel: String
    var hotKeyError: String?
    var keyCode: UInt32
    var modifiers: UInt32
    /// Универсальный доступ у утилиты: без него выделение не прочитать, остаётся меню «Службы».
    var accessibilityTrusted: Bool
    var canStart: Bool
    /// Программа не отдала выделенное — копировать через ⌘C и вернуть буфер (`SpeakKeys.copyFallback`).
    var copyFallback: Bool
}

/// Что экран может попросить. Больше утилита ничего не примет.
enum SpeakAction: Codable, Equatable, Sendable {
    case setSpeed(Double)
    /// +1 или −1: на шаг `SpeakSpeed.step` к соседней отметке.
    case stepSpeed(Int)
    /// Все языки снова на «Авто».
    case setVoiceAuto
    case pinVoice(language: String, id: String)
    case unpin(language: String)
    case pause
    case resume
    /// Оборвать чтение. Модуль при этом работает дальше.
    case stop
    case setHotKey(keyCode: UInt32, modifiers: UInt32)
    case resetHotKey
    /// На время записи нового сочетания на экране: иначе текущее сработает вместо записи.
    case suspendHotKey
    case resumeHotKey
    case refreshPermissions
    case requestAccessibility
    case setCopyFallback(Bool)

    /// Строго: ровно одно известное действие и ровно его поля. Кодирование остаётся синтезированным.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setSpeed": self = .setSpeed(try wire.value())
        case "stepSpeed": self = .stepSpeed(try wire.value())
        case "setVoiceAuto": try wire.none(); self = .setVoiceAuto
        case "pinVoice":
            try wire.fields("language", "id")
            self = .pinVoice(language: try wire.field("language"), id: try wire.field("id"))
        case "unpin":
            try wire.fields("language")
            self = .unpin(language: try wire.field("language"))
        case "pause": try wire.none(); self = .pause
        case "resume": try wire.none(); self = .resume
        case "stop": try wire.none(); self = .stop
        case "setHotKey":
            try wire.fields("keyCode", "modifiers")
            self = .setHotKey(keyCode: try wire.field("keyCode"), modifiers: try wire.field("modifiers"))
        case "resetHotKey": try wire.none(); self = .resetHotKey
        case "suspendHotKey": try wire.none(); self = .suspendHotKey
        case "resumeHotKey": try wire.none(); self = .resumeHotKey
        case "refreshPermissions": try wire.none(); self = .refreshPermissions
        case "requestAccessibility": try wire.none(); self = .requestAccessibility
        case "setCopyFallback": self = .setCopyFallback(try wire.value())
        default: throw wire.refuse()
        }
    }
}

extension SpeakState {
    /// Что экран покажет до первого ответа утилиты: сохранённые настройки. Голоса знает только утилита.
    static func stored() -> SpeakState {
        let d = Kit.defaults
        let keyCode = d.object(forKey: SpeakKeys.keyCode) as? UInt32 ?? SpeakKeys.defaultKeyCode
        let modifiers = d.object(forKey: SpeakKeys.modifiers) as? UInt32 ?? SpeakKeys.defaultModifiers
        return SpeakState(
            speed: SpeakSpeed.stored(d.object(forKey: SpeakKeys.speed)),
            pinnedVoices: d.dictionary(forKey: SpeakKeys.pinnedVoices) as? [String: String] ?? [:],
            voices: [], phase: .idle, message: nil,
            hotKeyLabel: VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers), hotKeyError: nil,
            keyCode: keyCode, modifiers: modifiers,
            // Подсказка про «Универсальный доступ» не должна мигнуть до ответа.
            accessibilityTrusted: true, canStart: true,
            copyFallback: SpeakKeys.storedCopyFallback(d.object(forKey: SpeakKeys.copyFallback)))
    }
}
