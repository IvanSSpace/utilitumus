import Foundation
import AppKit

enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto, constant, sensor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Авто"
        case .constant: return "Константа"
        case .sensor: return "По датчику"
        }
    }
}

enum SensorSource: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu
    var id: String { rawValue }
    var title: String { self == .cpu ? "Процессор" : "Видеокарта" }
}

/// Настройка одного вентилятора — как в Macs Fan Control: система сама,
/// фиксированные обороты, или линейно от температуры датчика.
struct FanConfig: Codable, Equatable {
    // По умолчанию — «По датчику» 50–80 °C: выбор пользователя как оптимальный для новых установок.
    // Пока помощник не установлен, вентиляторами всё равно управляет macOS.
    var mode: FanMode = .sensor
    /// Для `.constant`. 0 — ещё не выбирали, UI подставит минимум вентилятора.
    var rpm: Double = 0
    var sensor: SensorSource = .cpu
    /// Для `.sensor`: до `fromTemp` — минимум оборотов, от `toTemp` — максимум,
    /// между ними линейно.
    // 50/80 — выбор пользователя (2026-11-05): тише в простое не нужно, к 80 °C — максимум.
    var fromTemp: Double = 50
    var toTemp: Double = 80
}

struct FanReading: Identifiable, Equatable, Codable {
    let index: Int
    let actual: Double
    let min: Double
    let max: Double
    let isManual: Bool
    /// Цель в ручном режиме (F<n>Tg); в «Авто» система держит тут своё.
    let target: Double
    var id: Int { index }
    /// Ручной режим, а до цели ещё далеко: с нуля вентилятор выходит на
    /// максимум за 8–15 с — показываем, что он раскручивается, а не «не работает».
    var isSpinningUp: Bool { isManual && actual < target - 300 }
}

struct SensorReading: Identifiable, Equatable, Codable {
    let key: String
    let value: Double
    var id: String { key }
}

struct RunningCandidate: Identifiable, Equatable {
    let key: String
    let name: String
    let icon: NSImage?
    var id: String { key }
    // Иконка для сравнения не нужна: ключ и имя определяют строку меню.
    static func == (a: RunningCandidate, b: RunningCandidate) -> Bool { a.key == b.key && a.name == b.name }
}

enum FansText {
    /// Текст плашки. О ручном режиме только когда так и есть: иначе это лишняя тревога.
    static func outdatedDetail(fanStuckManual: Bool) -> String {
        let base = "Помощник устарел. macOS один раз спросит пароль администратора."
        return fanStuckManual ? base + " Вентилятор может оставаться в ручном режиме, пока доступ не обновлён." : base
    }

    /// Копия: иконка из `NSRunningApplication` общая, менять её размер нельзя.
    static func smallIcon(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}
