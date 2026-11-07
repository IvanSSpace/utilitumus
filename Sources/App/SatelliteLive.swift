import Foundation

extension ModuleManager {
    static let shared = ModuleManager()
}

extension SatelliteEnvironment {
    static func live() -> SatelliteEnvironment {
        SatelliteEnvironment(
            paths: .live,
            defaults: Kit.defaults,
            installer: SatelliteInstaller(paths: .live, launchctl: SatelliteInstaller.liveLaunchctl,
                                          download: SatelliteInstaller.liveDownload, verify: SatelliteInstaller.liveVerify,
                                          hooks: ["browser": .browser(.live)]),
            commands: .live,
            loadCatalog: {
                let request = URLRequest(url: SatelliteCatalog.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
                return data
            },
            hubVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            modules: .shared,
            restoreSystemFn: { FnSystemAction.restore() },
            systemFnHeld: { FnSystemAction.keepsOff })
    }
}

extension SatelliteRegistry {
    /// Стенд ставит своё до первого обращения к `shared`, иначе говорил бы с настоящими путями и утилитами.
    static var standEnvironment: SatelliteEnvironment?
    static let shared = SatelliteRegistry(standEnvironment ?? .live())
}
