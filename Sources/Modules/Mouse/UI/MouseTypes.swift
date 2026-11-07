import Foundation

/// Направление прокрутки для устройства. `system` — как настроено в macOS (то,
/// что сейчас у трекпада); `reversed` — наоборот.
enum ScrollDirection: String, CaseIterable, Identifiable, Codable {
    case system, reversed

    var id: String { rawValue }
    var title: String { self == .system ? "Как трекпад" : "Обратное" }
    var sign: Double { self == .reversed ? -1 : 1 }
}

/// Настройки модуля. Всё по умолчанию — «как есть»: тогда перехват не нужен вовсе.
struct MouseSettings: Equatable, Codable, Sendable {
    var mouseDirection: ScrollDirection = .system
    var magicMouseDirection: ScrollDirection = .system
    var smoothEnabled = false
    /// Множитель пути за один щелчок колеса.
    var speed = 1.0
    /// 0 — отзывчиво, 1 — долго и мягко доезжает.
    var smoothness = 0.5

    static let speedRange = 0.5...3.0

    /// Tap нужен, только если хоть что-то отличается от системного поведения.
    var needsTap: Bool {
        mouseDirection == .reversed || magicMouseDirection == .reversed || smoothEnabled
    }

    /// Одна строка для статуса и карточки: что сейчас включено.
    var summary: String {
        guard needsTap else { return "всё как в системе" }
        var parts: [String] = []
        if mouseDirection == .reversed || magicMouseDirection == .reversed { parts.append("прокрутка обратная") }
        if smoothEnabled { parts.append("плавность \(Int((smoothness * 100).rounded())) %") }
        return parts.joined(separator: " · ")
    }

    private enum Key {
        static let mouse = "Mouse.Direction"
        static let magic = "Mouse.MagicDirection"
        static let smooth = "Mouse.Smooth"
        static let speed = "Mouse.Speed"
        static let smoothness = "Mouse.Smoothness"
    }

    static func load(from d: UserDefaults = Kit.defaults) -> MouseSettings {
        var s = MouseSettings()
        s.mouseDirection = d.string(forKey: Key.mouse).flatMap(ScrollDirection.init) ?? .system
        s.magicMouseDirection = d.string(forKey: Key.magic).flatMap(ScrollDirection.init) ?? .system
        s.smoothEnabled = d.bool(forKey: Key.smooth)
        // NaN прошёл бы сквозь min и max, а JSONEncoder на нём падает с ошибкой: состояние ушло бы пустым.
        if let v = d.object(forKey: Key.speed) as? Double, v.isFinite { s.speed = min(max(v, speedRange.lowerBound), speedRange.upperBound) }
        if let v = d.object(forKey: Key.smoothness) as? Double, v.isFinite { s.smoothness = min(max(v, 0), 1) }
        return s
    }

    func save(to d: UserDefaults = Kit.defaults) {
        d.set(mouseDirection.rawValue, forKey: Key.mouse)
        d.set(magicMouseDirection.rawValue, forKey: Key.magic)
        d.set(smoothEnabled, forKey: Key.smooth)
        d.set(speed, forKey: Key.speed)
        d.set(smoothness, forKey: Key.smoothness)
    }
}
