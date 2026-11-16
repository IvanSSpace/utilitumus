import Foundation

/// Модель экрана «Озвучка», когда модуль ведёт утилита: сочетание, звук и Универсальный доступ у неё, у центра ничего этого нет.
/// Текста чтения в состоянии нет: экран видит только фазу, скорость, голоса и готовые строки.
@MainActor
final class RemoteSpeakModel: RemoteModuleModel<SpeakState, SpeakAction>, SpeakModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        // До первого ответа — сохранённые настройки: домен настроек у центра и утилиты один.
        super.init(id: id, initial: SpeakState.stored(), link: link, canRead: canRead,
                   optimistic: { state, action in
                       switch action {
                       case .setSpeed(let value): if let value = SpeakSpeed.clamped(value) { state.speed = value }
                       case .stepSpeed(let direction): state.speed = SpeakSpeed.stepped(state.speed, direction)
                       case .setVoiceAuto: state.pinnedVoices = [:]
                       case .pinVoice(let language, let id): state.pinnedVoices[language] = id
                       case .unpin(let language): state.pinnedVoices[language] = nil
                       case .setHotKey(let keyCode, let modifiers):
                           state.hotKeyLabel = VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers)
                       case .setCopyFallback(let on): state.copyFallback = on
                       // Чтение, сочетание и права решает утилита: показываем её ответ.
                       default: break
                       }
                   })
    }

    var speed: Double { state.speed }
    var pinnedVoices: [String: String] { state.pinnedVoices }
    var voices: [SpeakVoiceRow] { state.voices }
    var phase: SpeakPhase { state.phase }
    var message: String? { state.message }
    var hotKeyLabel: String { state.hotKeyLabel }
    var hotKeyError: String? { state.hotKeyError }
    var accessibilityTrusted: Bool { state.accessibilityTrusted }
    var canStart: Bool { state.canStart }
    var copyFallback: Bool { state.copyFallback }

    func setSpeed(_ value: Double) { send(.setSpeed(value)) }
    func stepSpeed(_ direction: Int) { send(.stepSpeed(direction)) }
    func setVoiceAuto() { send(.setVoiceAuto) }
    func pinVoice(language: String, id: String) { send(.pinVoice(language: language, id: id)) }
    func unpin(language: String) { send(.unpin(language: language)) }
    func pause() { send(.pause) }
    func resume() { send(.resume) }
    func stopSpeaking() { send(.stop) }
    func refreshPermissions() { send(.refreshPermissions) }
    func requestAccessibility() { send(.requestAccessibility) }
    func setCopyFallback(_ on: Bool) { send(.setCopyFallback(on)) }

    func setHotKey(keyCode: UInt32, modifiers: UInt32) { send(.setHotKey(keyCode: keyCode, modifiers: modifiers)) }
    func resetHotKey() { send(.resetHotKey) }
    func suspendHotKey() { send(.suspendHotKey) }
    func resumeHotKey() { send(.resumeHotKey) }
}
