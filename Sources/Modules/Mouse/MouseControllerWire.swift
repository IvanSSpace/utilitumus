import Foundation

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

extension MouseView where Model == MouseController {
    /// Встроенный модуль.
    @MainActor init() { self.init(model: .shared) }
}
