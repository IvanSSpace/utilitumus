/// Эквалайзер глазами экрана и связи: полосы, пределы, режимы, проверка значений.
/// Файл входит и в лаунчер, поэтому здесь нет ни формул, ни звука: они в `EqDSP.swift`, только в утилите.
enum MixerEq {
    static let bandCount = 10
    static let minGain = -12.0
    static let maxGain = 12.0
    /// Шаг регулятора. Значения по связи короткие, и ноль легко поймать рукой.
    static let step = 0.5
    /// Подписи в порядке полос, первая строка; вторая у всех «Гц». Сами частоты у фильтров: 32 Гц ... 16 кГц через октаву.
    static let bandTitles = ["32", "64", "125", "250", "500", "1к", "2к", "4к", "8к", "16к"]
    static let flat = [Double](repeating: 0, count: bandCount)
    static let customID = "custom"

    struct Preset {
        let id: String
        let title: String
        /// nil у «Своего»: это текущие значения.
        let bands: [Double]?
    }

    static let presets = [
        Preset(id: "flat", title: "Ровно", bands: flat),
        Preset(id: "bass", title: "Больше баса", bands: [6, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(id: "treble", title: "Больше верхов", bands: [0, 0, 0, 0, 0, 0, 1, 3, 5, 6]),
        Preset(id: "voice", title: "Голос", bands: [-8, -6, -3, -1, 1, 3, 4, 3, 1, 0]),
        Preset(id: "podcast", title: "Подкасты", bands: [-6, -4, -1, 1, 2, 3, 3, 2, 0, -2]),
        Preset(id: "music", title: "Музыка", bands: [4, 3, 1, 0, -1, -1, 0, 1, 3, 3.5]),
        Preset(id: "night", title: "Поздно ночью", bands: [-8, -6, -4, -1, 0, 1, 1, 0, -3, -6]),
        Preset(id: customID, title: "Свой", bands: nil),
    ]

    /// Единственная проверка значений: связь, настройки с диска и контроллер смотрят сюда.
    static func isValid(_ bands: [Double]) -> Bool {
        bands.count == bandCount && bands.allSatisfy { $0.isFinite && $0 >= minGain && $0 <= maxGain }
    }

    static func isKnownPreset(_ id: String) -> Bool { presets.contains { $0.id == id } }

    static func isFlat(_ bands: [Double]) -> Bool { bands.allSatisfy { $0 == 0 } }
}

/// Эквалайзер одного приложения: на связи и на диске. Выключатель не трогает значения.
struct MixerEqSetting: Codable, Equatable, Sendable {
    var enabled: Bool
    var preset: String
    var bands: [Double]

    /// Приложение, которое никто не настраивал.
    static let off = MixerEqSetting(enabled: false, preset: "flat", bands: MixerEq.flat)

    var isValid: Bool { MixerEq.isValid(bands) && MixerEq.isKnownPreset(preset) }
    /// Меняет ли он звук. Только такому нужен тап и подсветка кнопки.
    var isActive: Bool { enabled && !MixerEq.isFlat(bands) }
    /// Что идёт в фильтры: выключенный и ровный одно и то же, обход.
    var soundingBands: [Double] { enabled ? bands : MixerEq.flat }

    /// Ручная правка регулятора: режим становится «Свой».
    func editing(band: Int, to value: Double) -> MixerEqSetting {
        var next = self
        next.bands[band] = value
        next.preset = MixerEq.customID
        return next
    }

    /// Выбор в списке. «Свой» значения не меняет.
    func choosing(_ preset: MixerEq.Preset) -> MixerEqSetting {
        var next = self
        next.preset = preset.id
        if let bands = preset.bands { next.bands = bands }
        return next
    }
}
