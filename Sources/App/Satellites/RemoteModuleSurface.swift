import Combine
import Foundation

/// Что центр знает о модели модуля, которого ведёт утилита, не зная самого модуля: дашборд, меню-бар и запуск.
/// Реализует `RemoteModuleModel`; модуль переопределяет только то, что строка статуса не вмещает.
@MainActor
protocol RemoteModuleSurface: AnyObject {
    var responding: Bool { get }
    var changes: AnyPublisher<Void, Never> { get }
    func refresh()
    func dashboardState(base: DashState, status: LinkStatus?) -> DashState
    func performDashboardAction() -> Bool
    func performDashboardAction(ask: (DashConfirmation) -> Void) -> Bool
    func setDashboardVisible(_ visible: Bool)
    var menuUsesQuickActions: Bool { get }
}
