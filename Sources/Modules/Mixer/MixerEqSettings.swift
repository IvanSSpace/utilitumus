import Foundation

/// Настройки эквалайзера на диске: `{id приложения: {enabled, preset, bands}}`. Ключ свой, рядом с громкостями: старая версия
/// его не читает. Запись с диска проверяется так же, как значение из связи: битая строка теряется одна, остальные живут.
enum MixerEqSettings {
    static let key = "MixerEqualizer"

    static func read(from defaults: UserDefaults) -> [String: MixerEqSetting] {
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        var result: [String: MixerEqSetting] = [:]
        for (id, value) in stored {
            guard let fields = value as? [String: Any], let enabled = fields["enabled"] as? Bool,
                  let preset = fields["preset"] as? String, let bands = fields["bands"] as? [Double] else { continue }
            let setting = MixerEqSetting(enabled: enabled, preset: preset, bands: bands)
            if setting.isValid, setting != .off { result[id] = setting }
        }
        return result
    }

    static func write(_ settings: [String: MixerEqSetting], to defaults: UserDefaults) {
        defaults.set(settings.mapValues { ["enabled": $0.enabled, "preset": $0.preset, "bands": $0.bands] as [String: Any] }, forKey: key)
    }
}
