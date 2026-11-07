import Foundation

/// То, что вкладка центра показывает на экране.
struct AwakeState: Codable, Equatable, Sendable {
    var isActive: Bool
    var endDate: Date?
    var keepDisplay: Bool
    var duration: AwakeDuration
    var canStart: Bool
}

/// Что вкладка центра может попросить. Больше утилита ничего не примет.
enum AwakeAction: Codable, Equatable, Sendable {
    case toggle
    case setKeepDisplay(Bool)
    case setDuration(Int)

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "toggle":
            try wire.none()
            self = .toggle
        case "setKeepDisplay":
            self = .setKeepDisplay(try wire.value())
        case "setDuration":
            self = .setDuration(try wire.value())
        default:
            throw wire.refuse()
        }
    }
}
