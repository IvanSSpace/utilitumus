import Combine
import Foundation

/// Команды запущенной утилите. Каждая своим соединением: опросы редкие, а `LinkClient` сам рукопожимается.
/// `@Sendable`: замыкание, созданное на главном акторе, иначе на нём бы и выполнялось.
struct SatelliteCommands {
    var status: @Sendable (String) async throws -> LinkStatus
    var setEnabled: @Sendable (String, Bool) async throws -> Void
    var openWindow: @Sendable (String) async throws -> Void

    static let live = SatelliteCommands(
        status: { try await liveStatus($0) },
        setEnabled: { try await liveSetEnabled($0, $1) },
        openWindow: { try await liveOpenWindow($0) })

    @MainActor private static func liveStatus(_ id: String) async throws -> LinkStatus {
        try await LinkClient(id: id).status()
    }

    @MainActor private static func liveSetEnabled(_ id: String, _ enabled: Bool) async throws {
        try await LinkClient(id: id).setEnabled(enabled)
    }

    @MainActor private static func liveOpenWindow(_ id: String) async throws {
        try await LinkClient(id: id).openWindow()
    }
}

/// Всё, что реестр берёт снаружи.
struct SatelliteEnvironment {
    var paths: SatellitePaths
    var defaults: UserDefaults
    var installer: SatelliteInstaller
    var commands: SatelliteCommands
    var loadCatalog: @Sendable () async throws -> Data
    var hubVersion: String
    var modules: ModuleManager
}

/// Что центр знает об отдельных утилитах и кто из них ведёт модуль.
/// Опрос: при запуске, при открытии Стора, по `statusChanged`. Таймера нет: в простое центр молчит.
@MainActor
final class SatelliteRegistry: NSObject, ObservableObject {
    struct Entry: Equatable {
        var catalog: CatalogApp?
        /// nil — бандла нет.
        var installedVersion: String?
        var status: LinkStatus?
        var responding: Bool
    }

    @Published private(set) var entries: [Module: Entry] = [:]
    /// Модули, которые сейчас ставятся или удаляются.
    @Published private(set) var busy: Set<Module> = []

    private let environment: SatelliteEnvironment
    private var modules: ModuleManager { environment.modules }
    private var defaults: UserDefaults { environment.defaults }
    /// Последний удачный каталог: сбой сети его не стирает.
    private var available: [CatalogApp] = []
    /// Хвост очереди установщика. Одна операция за раз: параллельные гонялись бы за удаление пустой папки приложений.
    private var installerQueue: Task<Void, Never>?
    /// Растёт с каждой установкой и удалением: опрос, начатый раньше, своё решение выбрасывает.
    private var generation: [Module: Int] = [:]
    /// `setEnabled` при передаче сорвался: повторить, когда утилита снова ответит.
    private var enableOwed: Set<Module> = []
    private var observing = false

    init(_ environment: SatelliteEnvironment) {
        self.environment = environment
        super.init()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Запуск центра. `.deliverImmediately`: иначе неактивный центр получит пинок с большой задержкой.
    func start() {
        if !observing {
            observing = true
            for module in Module.allCases {
                DistributedNotificationCenter.default().addObserver(
                    self, selector: #selector(statusDidChange(_:)), name: KitLink.statusChanged(module.rawValue),
                    object: nil, suspensionBehavior: .deliverImmediately)
            }
        }
        refresh()
    }

    func refresh() {
        Task { await update() }
    }

    /// Каталог и опрос независимы: зависшая сеть не должна задерживать статусы, и наоборот.
    func update() async {
        async let catalog: Void = reloadCatalog()
        async let polled: Void = pollAll()
        _ = await (catalog, polled)
    }

    // MARK: Что известно

    func catalogApp(_ module: Module) -> CatalogApp? {
        entries[module]?.catalog
    }

    func hasBundle(_ module: Module) -> Bool {
        entries[module]?.installedVersion != nil
    }

    func hasUpdate(_ module: Module) -> Bool {
        guard let entry = entries[module], let installed = entry.installedVersion, let app = entry.catalog else { return false }
        return Kit.isNewer(app.version, than: installed)
    }

    func isEnabled(_ module: Module) -> Bool {
        entries[module]?.status?.enabled ?? false
    }

    // MARK: Команды

    func setEnabled(_ module: Module, _ enabled: Bool) {
        Task {
            try? await environment.commands.setEnabled(module.rawValue, enabled)
            await poll(module)
        }
    }

    func openWindow(_ module: Module) {
        Task {
            try? await environment.commands.openWindow(module.rawValue)
            await poll(module)
        }
    }

    // MARK: Установка и удаление

    /// Включённость утилита при первом запуске берёт из `ModuleOn`, а там «выключен»: «＋» значит «включить».
    func install(_ module: Module, app: CatalogApp) async throws {
        guard busy.insert(module).inserted else { return }
        let enabledKey = ModuleHandover.enabledKey(module.rawValue)
        let firstInstall = defaults.object(forKey: enabledKey) == nil
        if firstInstall { defaults.set(true, forKey: enabledKey) }
        let installer = environment.installer
        let name = Self.bundleName(module)
        do {
            try await serialized { try await installer.install(app, name: name) }
        } catch {
            if firstInstall { defaults.removeObject(forKey: enabledKey) }
            finish(module)
            throw error
        }
        finish(module)
        await poll(module)
    }

    /// Настройки остаются. Встроенный вариант не стартует: сначала `setOn(false)`, потом снятие внешнего.
    func uninstall(_ module: Module) async throws {
        guard busy.insert(module).inserted else { return }
        defer { finish(module) }
        let installer = environment.installer
        let id = module.rawValue, name = Self.bundleName(module)
        try await serialized { try await installer.remove(id: id, name: name) }
        defaults.removeObject(forKey: ModuleHandover.handedOverKey(id))
        enableOwed.remove(module)
        modules.setOn(module, false)
        modules.setExternal(module, false)
        entries[module] = entry(module, version: nil, reply: nil)
    }

    private func finish(_ module: Module) {
        busy.remove(module)
        generation[module, default: 0] += 1
    }

    /// Не на главном потоке: `removeStaleAgent` и launchctl внутри установщика синхронные. `@Sendable` держит
    /// замыкание вне главного актора, иначе оно вернулось бы туда и отдельная задача не помогла бы.
    private func serialized(_ work: @escaping @Sendable () async throws -> Void) async throws {
        let previous = installerQueue
        let task = Task.detached {
            await previous?.value
            try Task.checkCancellation()
            try await work()
        }
        installerQueue = Task.detached { _ = await task.result }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Каталог

    private func reloadCatalog() async {
        do {
            let data = try await environment.loadCatalog()
            available = SatelliteCatalog.available(try SatelliteCatalog.decode(data), hubVersion: environment.hubVersion)
        } catch {
            return
        }
        for module in Module.allCases {
            let current = entries[module]
            entries[module] = entry(module, version: current?.installedVersion, reply: current?.status)
        }
    }

    private func entry(_ module: Module, version: String?, reply: LinkStatus?) -> Entry? {
        let app = available.first { $0.id == module.rawValue }
        guard app != nil || version != nil else { return nil }
        return Entry(catalog: app, installedVersion: version, status: reply, responding: reply != nil)
    }

    // MARK: Опрос

    @objc private func statusDidChange(_ note: Notification) {
        guard let module = Module.allCases.first(where: { KitLink.statusChanged($0.rawValue) == note.name }) else { return }
        Task { await poll(module) }
    }

    private func pollAll() async {
        await withTaskGroup(of: Void.self) { group in
            for module in Module.allCases {
                group.addTask { await self.poll(module) }
            }
        }
    }

    /// Нет бандла — нет и запроса: иначе launchd пытался бы поднять мёртвого агента.
    private func poll(_ module: Module) async {
        guard !busy.contains(module) else { return }
        let started = generation[module, default: 0]
        let id = module.rawValue
        let info = environment.paths.appsDir.appendingPathComponent(Self.bundleName(module) + ".app")
        let version = await Task.detached { Self.installedVersion(ofBundle: info) }.value

        var reply: LinkStatus?
        if version != nil { reply = try? await environment.commands.status(id) }
        guard !busy.contains(module), generation[module, default: 0] == started else { return }

        let handedOver = defaults.bool(forKey: ModuleHandover.handedOverKey(id))
        switch ModuleHandover.decide(bundlePresent: version != nil, handedOver: handedOver, reply: reply) {
        case .keepBuiltIn:
            // Встроенный выключен, а утилита стоит: кроме неё показывать нечего. Передачи при этом ещё не было.
            modules.setExternal(module, version != nil && !modules.enabled.contains(module))
        case .returnToBuiltIn:
            await returnToBuiltIn(module)
        case .handOver:
            modules.setExternal(module, true)
            defaults.set(true, forKey: ModuleHandover.handedOverKey(id))
            // Утилита читает ключ из другого процесса, как только получит setEnabled.
            defaults.synchronize()
            await enable(module)
            reply = try? await environment.commands.status(id)
        case .satelliteOwns:
            modules.setExternal(module, true)
            if reply != nil, enableOwed.contains(module) { await enable(module) }
        }
        entries[module] = entry(module, version: version, reply: reply)
    }

    private func enable(_ module: Module) async {
        do {
            try await environment.commands.setEnabled(module.rawValue, true)
            enableOwed.remove(module)
        } catch {
            enableOwed.insert(module)
        }
    }

    /// Бандл удалили руками. Встроенный возвращается сразу; если агента снять не вышло, ключ остаётся
    /// и следующий опрос попробует снова.
    private func returnToBuiltIn(_ module: Module) async {
        modules.setExternal(module, false)
        enableOwed.remove(module)
        let installer = environment.installer
        let id = module.rawValue
        do {
            try await serialized { try installer.removeStaleAgent(id: id) }
            defaults.removeObject(forKey: ModuleHandover.handedOverKey(id))
        } catch {
            return
        }
    }

    /// Как у `scripts/build-app.sh`: `Sources/Apps/<Имя>` и имя бандла совпадают с папкой модуля.
    static func bundleName(_ module: Module) -> String {
        module.rawValue.capitalized
    }

    /// nil — бандла нет. Info.plist не читается — версия неизвестна и считается самой старой, обновление придёт.
    private nonisolated static func installedVersion(ofBundle bundle: URL) -> String? {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return nil }
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
