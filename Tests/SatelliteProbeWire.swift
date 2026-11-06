import Foundation

// Связь пробы основы: и утилита-проба, и стенд. Запуск: Tests/run-satellite-base-check.sh

struct ProbeState: Codable, Equatable, Sendable {
    var level = 0
    var line = "проба работает"
    var attention = false
    var handled = 0
    var blob = ""
    var running = false
}

enum ProbeAction: Codable, Equatable, Sendable {
    /// Больше 100 — отказ.
    case setLevel(Int)
    case setLine(String)
    case setAttention(Bool)
    /// Столько изменений отдельными витками, раз в 5 мс.
    case burst(Int)
    case setBlob(Int)
    /// Занять главный поток, мс.
    case hang(Int)
    case pair(a: Int, b: String)

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setLevel": self = .setLevel(try wire.value())
        case "setLine": self = .setLine(try wire.value())
        case "setAttention": self = .setAttention(try wire.value())
        case "burst": self = .burst(try wire.value())
        case "setBlob": self = .setBlob(try wire.value())
        case "hang": self = .hang(try wire.value())
        case "pair":
            try wire.fields("a", "b")
            self = .pair(a: try wire.field("a"), b: try wire.field("b"))
        default: throw wire.refuse()
        }
    }
}
