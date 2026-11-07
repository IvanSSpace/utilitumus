import Foundation

/// То, что вкладка центра показывает на экране.
struct MouseState: Codable, Equatable, Sendable {
    var settings: MouseSettings
    var axTrusted: Bool
    var tapActive: Bool
}

/// Что вкладка центра может попросить. Больше утилита ничего не примет.
enum MouseAction: Codable, Equatable, Sendable {
    case setMouseDirection(ScrollDirection)
    case setMagicMouseDirection(ScrollDirection)
    case setSmoothEnabled(Bool)
    case setSpeed(Double)
    case setSmoothness(Double)
    case refreshAccess
    case requestAccess

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setMouseDirection": self = .setMouseDirection(try wire.value())
        case "setMagicMouseDirection": self = .setMagicMouseDirection(try wire.value())
        case "setSmoothEnabled": self = .setSmoothEnabled(try wire.value())
        case "setSpeed": self = .setSpeed(try wire.value())
        case "setSmoothness": self = .setSmoothness(try wire.value())
        case "refreshAccess":
            try wire.none()
            self = .refreshAccess
        case "requestAccess":
            try wire.none()
            self = .requestAccess
        default:
            throw wire.refuse()
        }
    }
}
