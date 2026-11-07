import Foundation

/// Всё, что переход берёт снаружи: тесты подставляют каталог, установку и состояние модулей.
struct ModuleMigrationEnvironment: @unchecked Sendable {
    var defaults: UserDefaults
    var hubVersion: String
    var loadCatalog: @Sendable () async throws -> Data
    /// Встроенный модуль включён и ещё не передан утилите.
    var isBuiltInOn: @Sendable (Module) async -> Bool
    var hasBundle: @Sendable (Module) -> Bool
    var install: @Sendable (Module, CatalogApp) async throws -> Void
    var now: @Sendable () -> Date = { Date() }
}

/// После обновления центра включённый встроенный модуль сам ставит свою утилиту. Передачу и разрешения ведёт
/// `ModuleHandover`: пока обязательные шаги утилиты не сделаны, встроенный работает. Выключенные не ставятся.
/// Пароль службы вентиляторов и смену браузера по умолчанию здесь не просят: это шаги утилиты, их делает человек.
enum ModuleMigration {
    /// Человек убрал утилиту сам: больше не ставить. Пишут `SatelliteRegistry.uninstall` и возврат при удалении руками;
    /// снимает успешная установка.
    static func removedKey(_ id: String) -> String { "ModuleMigration.Removed.\(id)" }
    /// Версия центра, на которой модуль уже перешёл.
    static func doneKey(_ id: String) -> String { "ModuleMigration.Done.\(id)" }
    static func failuresKey(_ id: String) -> String { "ModuleMigration.Failures.\(id)" }
    static func retryAfterKey(_ id: String) -> String { "ModuleMigration.RetryAfter.\(id)" }

    /// 1 ч, 4 ч, 16 ч, 64 ч, дальше раз в неделю.
    static func backoff(failures: Int) -> TimeInterval {
        min(3600 * pow(4, Double(max(failures, 1) - 1)), 7 * 24 * 3600)
    }

    /// Один проход при запуске: по модулю за раз, по одной попытке на модуль. Сбой ждёт следующего запуска.
    static func run(_ env: ModuleMigrationEnvironment) async {
        guard let data = try? await env.loadCatalog(),
              let catalog = try? SatelliteCatalog.decode(data) else { return }
        let offered = SatelliteCatalog.available(catalog, hubVersion: env.hubVersion)
        for module in Module.allCases {
            let id = module.rawValue
            guard let app = offered.first(where: { $0.id == id }),
                  !env.defaults.bool(forKey: removedKey(id)),
                  env.defaults.string(forKey: doneKey(id)) != env.hubVersion,
                  env.now().timeIntervalSince1970 >= env.defaults.double(forKey: retryAfterKey(id)),
                  !env.hasBundle(module),
                  await env.isBuiltInOn(module) else { continue }
            do {
                try await env.install(module, app)
                // `install` молча выходит, если модуль занят другой операцией: без бандла это не переход.
                guard env.hasBundle(module) else { throw URLError(.cancelled) }
                env.defaults.set(env.hubVersion, forKey: doneKey(id))
                env.defaults.removeObject(forKey: failuresKey(id))
                env.defaults.removeObject(forKey: retryAfterKey(id))
            } catch {
                NSLog("Utilitumus: переход модуля %@ на утилиту не удался: %@", id, String(describing: error))
                let failures = env.defaults.integer(forKey: failuresKey(id)) + 1
                env.defaults.set(failures, forKey: failuresKey(id))
                env.defaults.set(env.now().addingTimeInterval(backoff(failures: failures)).timeIntervalSince1970,
                                 forKey: retryAfterKey(id))
                // Сети нет: остальные модули споткнутся о то же.
                if error is URLError { return }
            }
        }
    }
}

extension SatelliteRegistry {
    /// В пилоте и в дев-сборке (`scripts/dev.sh`) автор ставит сам: и видит Стор, и не отдаёт утилитам то, что проверяется
    /// при нём. Иначе локальный каталог поставил бы дев-сборку в настоящую папку утилит. Этим же решением пользуется `AutoUpdate`.
    nonisolated static var installsOnItsOwn: Bool {
        #if KIT_PILOT_CATALOG
        return false
        #else
        return true
        #endif
    }

    /// Запуск центра, после `start()`. Вне главного потока: каталог и скачивание не должны его занимать.
    func startMigration() {
        guard Self.installsOnItsOwn else { return }
        let env = ModuleMigrationEnvironment.live(self)
        Task.detached(priority: .utility) { await ModuleMigration.run(env) }
    }
}

extension ModuleMigrationEnvironment {
    @MainActor static func live(_ registry: SatelliteRegistry) -> ModuleMigrationEnvironment {
        let source = registry.environment
        let appsDir = source.paths.appsDir
        return ModuleMigrationEnvironment(
            defaults: source.defaults,
            hubVersion: source.hubVersion,
            loadCatalog: source.loadCatalog,
            isBuiltInOn: { module in await MainActor.run { source.modules.runsBuiltIn(module) } },
            hasBundle: { module in
                FileManager.default.fileExists(
                    atPath: appsDir.appendingPathComponent(SatelliteRegistry.bundleName(module) + ".app").path)
            },
            install: { module, app in try await registry.install(module, app: app) })
    }
}
