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

extension MouseController {
    var wireState: MouseState {
        MouseState(settings: settings, axTrusted: axTrusted, tapActive: tapActive)
    }

    /// Действие из связи. Самое длинное настоящее короче 128 байт.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: MouseAction.self, limit: 256, state: { wireState }) { handle($0) }
    }

    /// Действие после разбора: сначала проверка, изменения только после неё. Возвращает текст отказа или nil.
    /// Ползунки и загрузка настроек ограничивают значения сами, а здесь число приходит извне.
    func handle(_ action: MouseAction) -> String? {
        switch action {
        case .setMouseDirection(let direction):
            settings.mouseDirection = direction
        case .setMagicMouseDirection(let direction):
            settings.magicMouseDirection = direction
        case .setSmoothEnabled(let on):
            settings.smoothEnabled = on
        case .setSpeed(let value):
            // NaN прошёл бы сквозь min и max.
            guard value.isFinite else { return "Скорость должна быть числом" }
            settings.speed = min(max(value, MouseSettings.speedRange.lowerBound), MouseSettings.speedRange.upperBound)
        case .setSmoothness(let value):
            guard value.isFinite else { return "Плавность должна быть числом" }
            settings.smoothness = min(max(value, 0), 1)
        case .refreshAccess:
            refreshAccess()
        case .requestAccess:
            requestAccess()
        }
        return nil
    }
}
