import Foundation

extension MixerController {
    /// Ползунок меняет громкость сразу, а списки публикуются позже (`schedulePersist`): значения берём
    /// живые, иначе ответ на шаг ползунка вернул бы прежнюю громкость.
    var wireState: MixerState {
        func rows(_ list: [MixerApp]) -> [MixerAppState] {
            list.map { MixerAppState(id: $0.id, name: $0.name, volume: volume(for: $0.id), muted: isMuted($0.id), eq: equalizer(for: $0.id)) }
        }
        return MixerState(apps: rows(apps), idleApps: rows(idleApps), presetApps: rows(presetApps), otherApps: rows(otherApps),
                          permissionProblem: permissionProblem, lastError: lastError)
    }

    /// Действие из связи: сначала проверка, изменения только после неё. Вернёт текст ошибки или nil.
    /// `id` принимается только из показанных списков: иначе в настройки можно дописать любой мусор.
    func handle(_ action: MixerAction) -> String? {
        let unknown = "Такого приложения нет в списке"
        func issued(_ id: String) -> Bool {
            [apps, idleApps, presetApps, otherApps].contains { $0.contains { $0.id == id } }
        }
        switch action {
        case .setVolume(let id, let value):
            guard value.isFinite else { return "Такой громкости нет" }
            guard issued(id) else { return unknown }
            setVolume(value, for: id) // Диапазон 0...1 держит сам setVolume.
        case .setMuted(let id, let on):
            guard issued(id) else { return unknown }
            setMuted(on, for: id)
        case .reset(let id):
            guard issued(id) else { return unknown }
            reset(id)
        case .commitVolumes:
            commitVolumes()
        case .setEqualizer(let id, let enabled, let preset, let bands):
            let setting = MixerEqSetting(enabled: enabled, preset: preset, bands: bands)
            guard setting.isValid else { return "Таких значений эквалайзера нет" }
            guard issued(id) else { return unknown }
            setEqualizer(setting, for: id)
        }
        return nil
    }

    /// Действие из связи. Самое длинное настоящее — `setEqualizer` с bundle id, короче 512 байт: значения идут с шагом 0,5.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: MixerAction.self, limit: 512, state: { wireState }) { handle($0) }
    }
}

extension MixerView where Model == MixerController {
    /// Встроенный модуль: экран работает с контроллером в этом же процессе.
    init() { self.init(model: .shared) }
}
