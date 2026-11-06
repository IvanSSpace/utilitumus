import SwiftUI

/// Модель вкладки «Мышь», когда модуль ведёт утилита. Tap и права доступа у неё, у центра их нет.
/// Каждое поле настроек уходит своим действием: утилита проверяет их по одному.
@MainActor
final class RemoteMouseModel: RemoteModuleModel<MouseState, MouseAction>, MouseModel {
    init(id: String, canRead: @escaping () -> Bool) {
        // До первого ответа — сохранённые настройки: домен настроек у центра и утилиты один.
        // Доступ и перехват центру неизвестны; «запускаю» тревожит меньше, чем «нет доступа».
        super.init(id: id,
                   initial: MouseState(settings: MouseSettings.load(), axTrusted: true, tapActive: false),
                   baseWatch: .none, canRead: canRead,
                   optimistic: { state, action in
                       // Показ сразу, ответ утилиты заменит: отказ откатится сам.
                       switch action {
                       case .setMouseDirection(let direction): state.settings.mouseDirection = direction
                       case .setMagicMouseDirection(let direction): state.settings.magicMouseDirection = direction
                       case .setSmoothEnabled(let on): state.settings.smoothEnabled = on
                       case .setSpeed(let value):
                           guard value.isFinite else { return }
                           state.settings.speed = min(max(value, MouseSettings.speedRange.lowerBound), MouseSettings.speedRange.upperBound)
                       case .setSmoothness(let value):
                           guard value.isFinite else { return }
                           state.settings.smoothness = min(max(value, 0), 1)
                       case .refreshAccess, .requestAccess: break
                       }
                   },
                   // Ползунок шлёт много значений: в пути одно на ключ, ждёт последнее.
                   coalesceKey: { action in
                       switch action {
                       case .setSpeed: return "speed"
                       case .setSmoothness: return "smoothness"
                       default: return nil
                       }
                   })
    }

    var axTrusted: Bool { state.axTrusted }
    var tapActive: Bool { state.tapActive }
    func refreshAccess() { send(.refreshAccess) }

    // Карточка та же, что у встроенного: настройки из состояния.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        let s = settings
        guard s.needsTap else { return DashState(text: "всё как в системе") }
        var parts: [String] = []
        if s.mouseDirection == .reversed || s.magicMouseDirection == .reversed { parts.append("прокрутка обратная") }
        if s.smoothEnabled { parts.append("плавность \(Int((s.smoothness * 100).rounded())) %") }
        return DashState(text: parts.joined(separator: " · "))
    }

    var settings: MouseSettings {
        get { state.settings }
        set {
            let old = state.settings
            if newValue.mouseDirection != old.mouseDirection { send(.setMouseDirection(newValue.mouseDirection)) }
            if newValue.magicMouseDirection != old.magicMouseDirection { send(.setMagicMouseDirection(newValue.magicMouseDirection)) }
            if newValue.smoothEnabled != old.smoothEnabled { send(.setSmoothEnabled(newValue.smoothEnabled)) }
            if newValue.speed != old.speed { send(.setSpeed(newValue.speed)) }
            if newValue.smoothness != old.smoothness { send(.setSmoothness(newValue.smoothness)) }
        }
    }
}

extension RemoteMouseModel {
    static let shared: RemoteMouseModel = {
        let model = RemoteMouseModel(id: LinkIdentity.id(Module.mouse.rawValue), canRead: { ModuleManager.shared.isExternal(.mouse) })
        model.follow(SatelliteRegistry.shared.$entries.map { $0[.mouse]?.status })
        return model
    }()
}

struct RemoteMousePage: View {
    private let model = RemoteMouseModel.shared

    var body: some View {
        RemoteModulePage(module: .mouse, model: model) { MouseView(model: model) }
    }
}
