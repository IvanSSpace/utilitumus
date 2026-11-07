import Foundation

/// Модель вкладки «Не спать», когда модуль ведёт утилита. Своего assertion у центра нет.
/// Отсчёт времени экран считает сам по `endDate`. `.changes`: пункт меню живёт и при закрытом окне.
@MainActor
final class RemoteAwakeModel: RemoteModuleModel<AwakeState, AwakeAction>, AwakeModel {
    init(id: String, canRead: @escaping () -> Bool) {
        // До первого ответа — сохранённые настройки: домен настроек у центра и утилиты один.
        super.init(id: id,
                   initial: AwakeState(isActive: false, endDate: nil,
                                       keepDisplay: Kit.defaults.bool(forKey: AwakeKeys.display),
                                       duration: AwakeDuration(rawValue: Kit.defaults.integer(forKey: AwakeKeys.duration)) ?? .forever,
                                       canStart: true),
                   baseWatch: .changes, canRead: canRead,
                   optimistic: { state, action in
                       // Срок и блокировка — забота утилиты: `toggle` показывается по её ответу.
                       switch action {
                       case .toggle: break
                       case .setKeepDisplay(let on): state.keepDisplay = on
                       case .setDuration(let seconds):
                           if let duration = AwakeDuration(rawValue: seconds) { state.duration = duration }
                       }
                   })
    }

    var isActive: Bool { state.isActive }
    var endDate: Date? { state.endDate }
    var canStart: Bool { state.canStart }
    var keepDisplay: Bool {
        get { state.keepDisplay }
        set { send(.setKeepDisplay(newValue)) }
    }
    var duration: AwakeDuration {
        get { state.duration }
        set { send(.setDuration(newValue.rawValue)) }
    }
    func toggle() { send(.toggle) }

    // Карточка и меню «Не спать» — те же, что у встроенного: остаток времени в строку статуса не входит.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        var state = DashboardLive.awake(self)
        if let error = actionError {
            state.text = error
            state.attention = true
        }
        return state
    }

    override func performDashboardAction() -> Bool {
        toggle()
        return true
    }

    override var menuUsesQuickActions: Bool { false }
}
