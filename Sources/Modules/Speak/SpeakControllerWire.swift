import Foundation

extension SpeakController {
    /// Состояние для центра. Текста чтения здесь нет: только фаза, числа и готовые строки.
    var wireState: SpeakState {
        SpeakState(speed: speed, pinnedVoices: pinnedVoices, voices: voices, phase: phase, message: message,
                   hotKeyLabel: hotKeyLabel, hotKeyError: hotKeyError, keyCode: keyCode, modifiers: modifiers,
                   accessibilityTrusted: accessibilityTrusted, canStart: canStart)
    }

    /// Действие из связи. Самое длинное настоящее — `pinVoice` с id голоса, короче 512 байт.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: SpeakAction.self, limit: 512, state: { wireState }) { action in
            switch action {
            case .setSpeed(let value):
                guard value.isFinite else { return "Такой скорости нет" }
                setSpeed(value)
            case .stepSpeed(let direction):
                guard direction == 1 || direction == -1 else { return "Шаг скорости только +1 или −1" }
                stepSpeed(direction)
            case .setVoiceAuto:
                setVoiceAuto()
            case .pinVoice(let language, let id):
                if let error = pinError(language: language, id: id) { return error }
                pinVoice(language: language, id: id)
            case .unpin(let language):
                unpin(language: language)
            case .pause:
                guard phase == .speaking else { return "Сейчас ничего не читается" }
                pause()
            case .resume:
                guard phase == .paused else { return "Чтение не на паузе" }
                resume()
            case .stop:
                stopSpeaking()
            case .setHotKey(let keyCode, let modifiers):
                guard VoiceHotKey.isAcceptable(keyCode: keyCode, modifiers: modifiers) else { return "Такое сочетание не подойдёт" }
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
            }
            return nil
        }
    }
}
