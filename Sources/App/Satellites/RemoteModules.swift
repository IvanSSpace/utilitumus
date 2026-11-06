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
    var menuUsesQuickActions: Bool { get }
}

/// Модели модулей, которых ведут утилиты. Одна строка на модуль, и это единственное место в центре, где модуль назван.
/// Модель берётся по образцу `RemoteAwakeModel.shared`: `canRead` — «ведёт утилита», `follow` — статус реестра.
/// Строки разделены комментариями, чтобы одновременные правки разных модулей сливались без конфликтов.
@MainActor
enum RemoteModules {
    static func model(_ module: Module) -> (any RemoteModuleSurface)? {
        switch module {
        case .awake: return RemoteAwakeModel.shared
        // sound
        case .sound: return nil
        // mouse
        case .mouse: return nil
        // mixer
        case .mixer: return nil
        // stash
        case .stash: return nil
        // keyboard
        case .keyboard: return nil
        // browser
        case .browser: return nil
        // load
        case .load: return nil
        // voice
        case .voice: return nil
        // clipboard
        case .clipboard: return nil
        // fans
        case .fans: return nil
        }
    }

    /// Только модели ведомых утилитой модулей: остальным нечего читать.
    static func external(_ modules: ModuleManager) -> [(Module, any RemoteModuleSurface)] {
        Module.allCases.compactMap { module in
            guard modules.isExternal(module), let model = model(module) else { return nil }
            return (module, model)
        }
    }
}
