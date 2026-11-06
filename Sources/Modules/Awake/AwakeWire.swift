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

extension AwakeController {
    var wireState: AwakeState {
        AwakeState(isActive: isActive, endDate: endDate, keepDisplay: keepDisplay, duration: duration, canStart: canStart)
    }

    /// Действие из связи. Самое длинное настоящее короче 256 байт.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: AwakeAction.self, limit: 256, state: { wireState }) { action in
            switch action {
            case .toggle:
                guard isActive || canStart else { return "Сейчас модуль не может включиться" }
                toggle()
            case .setKeepDisplay(let on):
                keepDisplay = on
            case .setDuration(let seconds):
                guard let value = AwakeDuration(rawValue: seconds) else { return "Такой длительности нет" }
                duration = value
            }
            return nil
        }
    }
}
