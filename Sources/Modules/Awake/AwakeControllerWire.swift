import Foundation

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
