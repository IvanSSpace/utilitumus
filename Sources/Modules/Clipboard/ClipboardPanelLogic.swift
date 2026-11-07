import Foundation

// Логика панели без AppKit и SwiftUI: время и пиксели приходят аргументами, поэтому всё проверяется в Tests/ClipboardPanelCheck.swift.

/// Первый клик выделяет сразу, второй по той же карточке в пределах окна вставляет. Двойной клик системы здесь
/// не годится: с ним выделение ждало бы, не будет ли второго клика.
struct ClipClickTracker {
    /// Единственное место, где задано окно двойного клика.
    static let pasteWindow: TimeInterval = 0.45

    enum Outcome: Equatable { case select, paste }

    private var last: (id: UUID, at: TimeInterval)?

    mutating func click(_ id: UUID, at time: TimeInterval) -> Outcome {
        if let last, last.id == id {
            let elapsed = time - last.at
            if elapsed >= 0, elapsed <= Self.pasteWindow {
                // После вставки отсчёт сброшен: третий быстрый клик вставлять не должен.
                self.last = nil
                return .paste
            }
        }
        last = (id, time)
        return .select
    }

    mutating func reset() { last = nil }
}

/// Выбор нескольких карточек. Пусто или одна — обычный выбор, его держит `selected` модели; номера здесь не годятся, порядок ленты решает она сама.
struct ClipSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    /// От какой карточки считается диапазон.
    private(set) var anchor: UUID?

    var isMultiple: Bool { ids.count > 1 }

    mutating func reset() {
        ids = []
        anchor = nil
    }

    /// Shift+клик и Shift+стрелка: всё от якоря до `target`. Первый раз якорь — текущая карточка.
    mutating func extend(to target: UUID, from current: UUID?, in list: [UUID]) {
        if anchor == nil || !list.contains(anchor!) { anchor = current ?? target }
        guard let from = anchor.flatMap(list.firstIndex), let to = list.firstIndex(of: target) else { return }
        ids = Set(list[min(from, to)...max(from, to)])
    }

    /// ⌘+клик: добавить или убрать одну. Возвращает карточку, на которой остаётся текущий выбор.
    mutating func toggle(_ target: UUID, current: UUID?, in list: [UUID]) -> UUID {
        if ids.isEmpty, let current { ids = [current] }
        if ids.contains(target), ids.count > 1 {
            ids.remove(target)
            if anchor == target { anchor = nil }
            return list.last { ids.contains($0) } ?? target
        }
        ids.insert(target)
        anchor = target
        return target
    }

    /// Слева направо, как в ленте: в таком порядке записи вставляются.
    func ordered(in list: [UUID]) -> [UUID] { list.filter(ids.contains) }
}

/// Подписи карточки. `clipAgo` остаётся короткой для экрана утилиты и лаунчера, здесь полные слова.
enum ClipPanelText {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 1 { return "только что" }
        if s < 60 { return "\(s) \(ClipboardPreview.word(s, "секунду", "секунды", "секунд")) назад" }
        if s < 3600 { return "\(s / 60) \(ClipboardPreview.word(s / 60, "минуту", "минуты", "минут")) назад" }
        if s < 86400 { return "\(s / 3600) \(ClipboardPreview.word(s / 3600, "час", "часа", "часов")) назад" }
        if s < 2 * 86400 { return "вчера" }
        return "\(s / 86400) \(ClipboardPreview.word(s / 86400, "день", "дня", "дней")) назад"
    }

    /// Подсказки, которые раньше были строкой внизу панели, теперь в меню «…».
    static let hints: [(key: String, text: String)] = [
        ("←→", "выбор"),
        ("⏎", "вставить"),
        ("Два клика", "вставить"),
        ("⇧ или ⌘ + клик", "несколько"),
        ("⌘1–9", "быстро"),
        ("⇥", "вкладка"),
        ("Буква", "поиск"),
        ("Esc", "закрыть"),
        ("Правый клик", "в пространство"),
    ]
}

/// Цвет в sRGB, каналы 0…1.
struct ClipRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    /// Относительная яркость по WCAG.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    var contrastWithWhite: Double { 1.05 / (luminance + 0.05) }
    var isGray: Bool { max(abs(r - g), abs(g - b), abs(r - b)) < 0.001 }
}

/// Цвет шапки карточки: преобладающий оттенок значка программы, затемнённый так, чтобы белый текст читался.
enum ClipHeaderTint {
    /// Нет значка или значок без выраженного цвета.
    static let neutral = ClipRGB(r: 0.10, g: 0.10, b: 0.10)
    /// Шапка в теме «Графит».
    static let graphite = ClipRGB(r: 0.13, g: 0.13, b: 0.13)
    /// Контраст белого текста на шапке, мелкая подпись времени тоже должна читаться.
    static let minContrast = 4.5

    /// Значок, в котором цветных точек меньше этой доли, считается бесцветным.
    private static let minColorShare = 0.15
    private static let hueBuckets = 12

    /// Пиксели — RGBA по 4 байта, альфа уже снята. Прозрачные поля значка не считаются.
    static func dominant(rgba: [UInt8]) -> ClipRGB {
        var counts = [Double](repeating: 0, count: hueBuckets)
        var sums = [ClipRGB](repeating: ClipRGB(r: 0, g: 0, b: 0), count: hueBuckets)
        var opaque = 0.0
        var i = 0
        while i + 3 < rgba.count {
            defer { i += 4 }
            guard rgba[i + 3] >= 128 else { continue }
            opaque += 1
            let c = ClipRGB(r: Double(rgba[i]) / 255, g: Double(rgba[i + 1]) / 255, b: Double(rgba[i + 2]) / 255)
            let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b)
            // Белое, серое и почти чёрное о цвете значка не говорит.
            guard high >= 0.2, high - low >= 0.2 * high else { continue }
            let bucket = hueBucket(c, high: high, low: low)
            counts[bucket] += 1
            sums[bucket].r += c.r
            sums[bucket].g += c.g
            sums[bucket].b += c.b
        }
        func average(_ i: Int) -> ClipRGB {
            let n = max(counts[i], 1)
            return ClipRGB(r: sums[i].r / n, g: sums[i].g / n, b: sums[i].b / n)
        }
        // Светлый оттенок при затемнении мутнеет (жёлтый станет болотным), поэтому при равных долях выигрывает тот,
        // которому темнеть меньше. Значок почти целиком одного цвета это не меняет.
        func score(_ i: Int) -> Double { counts[i] * min(1, average(i).contrastWithWhite / minContrast) }
        // Доля считается по всем цветным точкам: многоцветный значок на белом не должен стать бесцветным.
        guard opaque > 0, counts.reduce(0, +) / opaque >= minColorShare,
              let top = counts.indices.max(by: { score($0) < score($1) }) else { return neutral }
        return readable(average(top))
    }

    private static func hueBucket(_ c: ClipRGB, high: Double, low: Double) -> Int {
        let delta = high - low
        var hue: Double
        if high == c.r { hue = (c.g - c.b) / delta } else if high == c.g { hue = 2 + (c.b - c.r) / delta } else { hue = 4 + (c.r - c.g) / delta }
        hue /= 6
        if hue < 0 { hue += 1 }
        return min(Int(hue * Double(hueBuckets)), hueBuckets - 1)
    }

    /// Слишком светлый цвет равномерно темнеет, оттенок остаётся. Бисекция: яркость растёт с множителем монотонно.
    static func readable(_ c: ClipRGB) -> ClipRGB {
        guard c.contrastWithWhite < minContrast else { return c }
        func scaled(_ k: Double) -> ClipRGB { ClipRGB(r: c.r * k, g: c.g * k, b: c.b * k) }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if scaled(middle).contrastWithWhite >= minContrast { low = middle } else { high = middle }
        }
        return scaled(low)
    }
}

/// Что случится при удалении пространства. Считает так же, как `ClipboardStore.deleteSpace` с `trim`:
/// записи возвращаются в историю, а всё, что не влезло в лимит, удаляется, начиная с конца списка.
enum ClipSpaceDeletion {
    static func droppedCount(items: [ClipItem], space: UUID, limit: Int) -> Int {
        let history = items.filter { $0.spaceID == nil || $0.spaceID == space }.count
        return max(0, history - limit)
    }

    static func summary(items: [ClipItem], space: UUID, limit: Int) -> String {
        let count = items.filter { $0.spaceID == space }.count
        guard count > 0 else { return "Записей в нём нет." }
        let records = "\(count) \(ClipboardPreview.word(count, "запись", "записи", "записей"))"
        let back = count == 1 ? "вернётся" : "вернутся"
        let dropped = droppedCount(items: items, space: space, limit: limit)
        guard dropped > 0 else { return "\(records) \(back) в историю." }
        let old = "\(dropped) \(ClipboardPreview.word(dropped, "самая старая запись", "самые старые записи", "самых старых записей"))"
        let gone = ClipboardPreview.word(dropped, "удалится", "удалятся", "удалятся")
        return "\(records) \(back) в историю. Лимит истории \(limit): \(old) \(gone) навсегда."
    }
}
