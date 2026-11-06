import Foundation

extension ModuleManager {
    static let shared = ModuleManager(hooks: ModuleHooks.live)
}

extension SatelliteEnvironment {
    static func live() -> SatelliteEnvironment {
        SatelliteEnvironment(
            paths: .live,
            defaults: Kit.defaults,
            installer: SatelliteInstaller(paths: .live, launchctl: SatelliteInstaller.liveLaunchctl,
                                          download: SatelliteInstaller.liveDownload, verify: SatelliteInstaller.liveVerify),
            commands: .live,
            loadCatalog: {
                let request = URLRequest(url: SatelliteCatalog.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
                return data
            },
            hubVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            modules: .shared)
    }
}

extension SatelliteRegistry {
    /// Стенд ставит своё до первого обращения к `shared`, иначе говорил бы с настоящими путями и утилитами.
    static var standEnvironment: SatelliteEnvironment?
    static let shared = SatelliteRegistry(standEnvironment ?? .live())
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
        case .browser:
            // Ссылки ведёт помощник «Utilitumus Links» и от модуля не зависит:
            // выключенный модуль он видит в настройках и отправляет ссылки в основной браузер.
            return ModuleHooks(start: { BrowserCatalog.shared.start() },
                               stop: { BrowserCatalog.shared.stop() })
        case .voice:
            return ModuleHooks(start: { VoiceController.shared.start() },
                               stop: { VoiceController.shared.stop() })
        case .clipboard:
            return ModuleHooks(start: { ClipboardController.shared.start() },
                               stop: { ClipboardController.shared.stop() })
        case .keyboard:
            return ModuleHooks(start: { KeyboardController.shared.start() },
                               // Модуль передан утилите: настройки пользователя (🌐, диктовка) остаются, их держит утилита.
                               stop: {
                                   if ModuleManager.shared.isExternal(.keyboard) {
                                       KeyboardController.shared.quit()
                                   } else {
                                       KeyboardController.shared.stop()
                                   }
                               },
                               quit: { KeyboardController.shared.quit() })
        case .awake:
            return ModuleHooks(start: { AwakeController.shared.start() },
                               stop: { AwakeController.shared.stop() })
        case .stash:
            // Фоном стеш не работает: подписки он ставит сам, когда открыт экран.
            return ModuleHooks(start: {}, stop: { StashStore.shared.stop() })
        }
    }
}
