import Foundation

extension ModuleManager {
    static let shared = ModuleManager(hooks: ModuleHooks.live)
}

extension ModuleHooks {
    static func live(_ module: Module) -> ModuleHooks {
        switch module {
        case .sound:
            return ModuleHooks(start: { AudioMonitor.shared.start() },
                               stop: { AudioMonitor.shared.stop() })
        case .fans:
            return ModuleHooks(start: { FanController.shared.start() },
                               stop: { FanController.shared.stop() })
        case .load:
            return ModuleHooks(start: { LoadStore.shared.start() },
                               stop: { LoadStore.shared.stop() })
        case .mixer:
            return ModuleHooks(start: { MixerController.shared.start() },
                               stop: { MixerController.shared.stop() })
        case .mouse:
            return ModuleHooks(start: { MouseController.shared.start() },
                               stop: { MouseController.shared.stop() })
        case .stash:
            // Фоном стеш не работает: подписки он ставит сам, когда открыт экран.
            return ModuleHooks(start: {}, stop: { StashStore.shared.stop() })
        }
    }
}
