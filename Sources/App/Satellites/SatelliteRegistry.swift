import AppKit
import Combine

/// Команды запущенной утилите. Каждая своим соединением: опросы редкие, а `LinkClient` сам рукопожимается.
/// `@Sendable`: замыкание, созданное на главном акторе, иначе на нём бы и выполнялось.
struct SatelliteCommands {
    var status: @Sendable (String) async throws -> LinkStatus
    var setEnabled: @Sendable (String, Bool) async throws -> Void
    var openWindow: @Sendable (String) async throws -> Void
    /// Значок утилиты в строке меню: центр сообщает по проверенной связи, утилита применяет сразу.
    var setMenuIcon: @Sendable (String, Bool) async throws -> Void = { _, _ in }
    /// Быстрое действие из статуса: байты уходят в `moduleAction` как есть. Ответ — тело `LinkReply`.
    var action: @Sendable (String, Data) async throws -> Data = { _, _ in throw LinkError.timeout }
    /// Шаг настройки по id из статуса: просит разрешение сама утилита, потому что macOS показывает имя того, кто спросил.
    var performStep: @Sendable (String, String) async throws -> LinkReply<LinkStatus> = { _, _ in throw LinkError.timeout }
    /// Состояние модуля: по нему центр видит, занята ли утилита (`UpdateBusy`).
    var moduleState: @Sendable (String) async throws -> Data = { _ in throw LinkError.timeout }
    /// Утилиту только что перезапустили: открытый экран перечитывает сам, не ждёт её уведомления,
    /// оно могло уйти, пока он ещё не слушал. Стендам настоящие модели не нужны.
    var refreshScreen: @MainActor (Module) -> Void = { _ in }

    static let live = SatelliteCommands(
        status: { try await liveStatus($0) },
        setEnabled: { try await liveSetEnabled($0, $1) },
        openWindow: { try await liveOpenWindow($0) },
        setMenuIcon: { try await LinkClient(id: $0).setMenuIcon($1) },
        action: { try await liveAction($0, $1) },
        performStep: { try await livePerformStep($0, $1) },
        moduleState: { try await liveModuleState($0) },
        refreshScreen: { RemoteModules.model($0)?.refresh() })

    @MainActor private static func liveModuleState(_ id: String) async throws -> Data {
        try await LinkClient(id: id).moduleState()
    }

    @MainActor private static func liveAction(_ id: String, _ action: Data) async throws -> Data {
        try await LinkClient(id: id).moduleAction(action)
    }

    @MainActor private static func livePerformStep(_ id: String, _ step: String) async throws -> LinkReply<LinkStatus> {
        try await LinkClient(id: id).performSetupStep(step)
    }

    @MainActor private static func liveStatus(_ id: String) async throws -> LinkStatus {
        try await LinkClient(id: id).status()
    }

    @MainActor private static func liveSetEnabled(_ id: String, _ enabled: Bool) async throws {
        try await LinkClient(id: id).setEnabled(enabled)
    }

    @MainActor private static func liveOpenWindow(_ id: String) async throws {
        // Иначе macOS 14+ не отдаст фокус фоновому процессу и окно откроется позади центра.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: KitLink.bundleID(id))
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
    /// Вернуть системе 🌐 и диктовку, когда их больше некому держать. Настоящий `FnSystemAction` даёт только `live()`.
    var restoreSystemFn: @MainActor () -> Void = {}
    /// Держим ли 🌐 отключённой (`FnSystemAction.keepsOff`). Настоящее чтение тоже даёт только `live()`.
    var systemFnHeld: @MainActor () -> Bool = { false }
}

/// Что центр знает об отдельных утилитах и кто из них ведёт модуль.
/// Опрос: при запуске, при открытии Стора, по `statusChanged`. Своего таймера нет; редкий таймер только у `AutoUpdate`.
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
    /// Утилита сообщила о смене. Опрос публикует только разницу в статусе, а о настройке значка статус не говорит.
    let statusPinged = PassthroughSubject<Module, Never>()

    let environment: SatelliteEnvironment
    private var modules: ModuleManager { environment.modules }
    private var defaults: UserDefaults { environment.defaults }
    /// Последний удачный каталог: сбой сети его не стирает.
    private var available: [CatalogApp] = []
    /// Записи каталога, которым нужен центр новее этого.
    @Published private(set) var heldByHub: [Module: CatalogApp] = [:]
    /// Последнее чтение каталога сорвалось: прежние сведения остаются.
    @Published private(set) var catalogFailed = false
    /// Когда каталог читали в последний раз, удачно или нет.
    private(set) var catalogReadAt: Date?
    /// Хвост очереди установщика. Одна операция за раз: параллельные гонялись бы за удаление пустой папки приложений.
    private var installerQueue: Task<Void, Never>?
    /// Растёт с каждой установкой и удалением: опрос, начатый раньше, своё решение выбрасывает.
    private var generation: [Module: Int] = [:]
    /// `setEnabled` при передаче сорвался: повторить, когда утилита снова ответит.
    private var enableOwed: Set<Module> = []
    private var observing = false
    /// Первый опрос и чтение каталога при запуске: автообновление дожидается их, а не читает каталог второй раз.
    private var firstRefresh: Task<Void, Never>?
    /// Опрос одного модуля уже идёт: чек-лист просит обновить раз в секунду и не должен копить запросы.
    private var polling: Set<Module> = []
    /// Текст последней неудачи действия или шага: «Модуль не ответил» и отказ самой утилиты.
    @Published private(set) var actionErrors: [Module: String] = [:]
    @Published private(set) var stepErrors: [String: String] = [:]
    /// Почему не вышла последняя установка: её показывает страница модуля без утилиты.
    @Published private(set) var installFailures: [Module: any Error] = [:]
    /// Модули, которые опросили хотя бы раз. До этого неизвестно, есть ли утилита: страница «утилиты нет» ещё не верна.
    @Published private(set) var polled: Set<Module> = []
    /// Идёт проход `ModuleMigration`: второй поверх него счёл бы занятый модуль сбоем.
    var migration: Task<Void, Never>?

    init(_ environment: SatelliteEnvironment) {
        self.environment = environment
        super.init()
        environment.modules.droppedWithoutUtility = { [weak self] module in
            if module == .keyboard { self?.releaseFnIfNobodyListens() }
        }
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
        firstRefresh = Task { await update() }
    }

    func firstRefreshFinished() async {
        await firstRefresh?.value
    }

    func refresh() {
        Task { await update() }
    }

    /// Только статус одной утилиты, без каталога.
    func refresh(_ module: Module) {
        guard polling.insert(module).inserted else { return }
        Task {
            await poll(module)
            polling.remove(module)
        }
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

    /// Новая версия есть, но этой версии центра не по силам. Только у установленного и только если обновиться больше не на что.
    func needsNewerHub(_ module: Module) -> CatalogApp? {
        guard let installed = entries[module]?.installedVersion, !hasUpdate(module),
              let app = heldByHub[module], Kit.isNewer(app.version, than: installed) else { return nil }
        return app
    }

    /// Занята ли утилита работой, которую перезапуск оборвал бы. Не ответила — обрывать нечего.
    func busyReason(_ module: Module) async -> String? {
        guard let state = try? await environment.commands.moduleState(module.rawValue) else { return nil }
        return UpdateBusy.reason(module, state: state)
    }

    /// Утилита ответила, но её состояние этому центру непонятно. Не ответила — обрывать нечего, как и в `busyReason`.
    func stateUnreadable(_ module: Module) async -> Bool {
        guard let state = try? await environment.commands.moduleState(module.rawValue) else { return false }
        return !UpdateBusy.readable(module, state: state)
    }

    func isEnabled(_ module: Module) -> Bool {
        entries[module]?.status?.enabled ?? false
    }

    /// Утилита старше 1.1.0 не знает значка по просьбе центра и записи проверки из кнопки «Голоса»; центр обновляет её
    /// только по кнопке в Сторе, так что рядом с новым центром она живёт долго. Боты вышли сразу со всем этим.
    /// Версия неизвестна (опроса ещё не было) — не старая: лишнего предупреждения не нужно.
    nonisolated static func isOutdated(_ module: Module, installed: String?) -> Bool {
        guard let installed else { return false }
        return Kit.isNewer(module == .bots ? "1.0.0" : "1.1.0", than: installed)
    }

    func isOutdated(_ module: Module) -> Bool {
        Self.isOutdated(module, installed: entries[module]?.installedVersion)
    }

    // MARK: Команды

    func setEnabled(_ module: Module, _ enabled: Bool) {
        Task {
            try? await environment.commands.setEnabled(module.rawValue, enabled)
            await poll(module)
        }
    }

    /// Быстрое действие карточки или меню. Утилита проверяет его как любое другое; отказ или молчание видно на карточке.
    func perform(_ quick: LinkQuickAction, module: Module) {
        Task {
            do {
                let reply = try await environment.commands.action(module.rawValue, quick.action)
                setActionError(module, (try? JSONDecoder().decode(LinkReplyError.self, from: reply))?.error)
            } catch {
                setActionError(module, "Модуль не ответил, попробуй ещё раз")
            }
            await poll(module)
        }
    }

    /// Действие с вопросом: сначала спрашивает центр, текст вопроса прислала утилита.
    func confirmAndPerform(_ quick: LinkQuickAction, module: Module, ask: (DashConfirmation) -> Void) {
        guard let confirm = quick.confirm else { return perform(quick, module: module) }
        ask(DashConfirmation(title: confirm.title, message: confirm.message, button: confirm.button,
                             run: { [weak self] in self?.perform(quick, module: module) }))
    }

    /// Шаг чек-листа. Ответ несёт новый статус: чек-лист обновляется, не дожидаясь опроса.
    func performSetupStep(_ module: Module, _ id: String) {
        let key = "\(module.rawValue).\(id)"
        Task {
            do {
                let reply = try await environment.commands.performStep(module.rawValue, id)
                stepErrors[key] = reply.error
                apply(reply.state, to: module)
            } catch {
                stepErrors[key] = "Утилита не ответила, попробуй ещё раз"
            }
            await poll(module)
        }
    }

    private func setActionError(_ module: Module, _ error: String?) {
        if actionErrors[module] != error { actionErrors[module] = error }
    }

    private func apply(_ status: LinkStatus, to module: Module) {
        guard var current = entries[module], current.status != status else { return }
        current.status = status
        current.responding = true
        entries[module] = current
    }

    func openWindow(_ module: Module) {
        Task {
            try? await environment.commands.openWindow(module.rawValue)
            await poll(module)
        }
    }

    // MARK: Установка и удаление

    /// Кнопка на странице модуля без утилиты. Это выбор человека: отступ автоперехода и отметка «убрал сам» его не держат.
    func installMissing(_ module: Module) {
        guard let app = catalogApp(module) else { return }
        Task { try? await install(module, app: app) }
    }

    /// «＋» значит «включить»: утилита иначе взяла бы «выключен» из `ModuleOn` или с прошлой установки.
    /// Обновление включённость не трогает: её выбрал человек.
    func install(_ module: Module, app: CatalogApp, checkStaged: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }) async throws {
        guard busy.insert(module).inserted else { return }
        installFailures[module] = nil
        let enabledKey = ModuleHandover.enabledKey(module.rawValue)
        let previous = defaults.object(forKey: enabledKey)
        let bundle = environment.paths.appsDir.appendingPathComponent(Self.bundleName(module) + ".app")
        let fresh = !FileManager.default.fileExists(atPath: bundle.path)
        if fresh { defaults.set(true, forKey: enabledKey) }
        let installer = environment.installer
        let name = Self.bundleName(module)
        do {
            try await serialized {
                try await installer.install(app, name: name, beforeQuit: {
                    // Распознавание наружу не видно: фраза, сказанная только что, успеет дойти до поля.
                    if module == .voice { try await Task.sleep(for: .seconds(4)) }
                    if let reason = await self.busyReason(module) { throw SatelliteInstallError.busy(reason) }
                }, checkStaged: checkStaged)
            }
        } catch {
            if fresh { defaults.set(previous, forKey: enabledKey) }
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled { installFailures[module] = error }
            finish(module)
            if module == .keyboard { releaseFnIfNobodyListens() }
            // Откат тоже перезапустил утилиту.
            environment.commands.refreshScreen(module)
            throw error
        }
        finish(module)
        defaults.removeObject(forKey: ModuleMigration.removedKey(module.rawValue))
        defaults.removeObject(forKey: ModuleMigration.failuresKey(module.rawValue))
        defaults.removeObject(forKey: ModuleMigration.retryAfterKey(module.rawValue))
        await poll(module)
        environment.commands.refreshScreen(module)
    }

    /// Настройки остаются.
    func uninstall(_ module: Module) async throws {
        guard busy.insert(module).inserted else { return }
        defer { finish(module) }
        let installer = environment.installer
        let id = module.rawValue, name = Self.bundleName(module)
        try await serialized { try await installer.remove(id: id, name: name) }
        // Утилита возвращает 🌐 сама, но могла не ответить на просьбу выйти. Повтор безвреден: возвращать будет уже нечего.
        if module == .keyboard { environment.restoreSystemFn() }
        defaults.removeObject(forKey: ModuleHandover.handedOverKey(id))
        defaults.set(true, forKey: ModuleMigration.removedKey(id))
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
        catalogReadAt = Date()
        do {
            let catalog = try SatelliteCatalog.decode(try await environment.loadCatalog())
            available = SatelliteCatalog.available(catalog, hubVersion: environment.hubVersion)
            var held: [Module: CatalogApp] = [:]
            for app in catalog.apps where !available.contains(app) {
                if let module = Module(rawValue: app.id) { held[module] = app }
            }
            heldByHub = held
            catalogFailed = false
        } catch {
            catalogFailed = true
            if modules.wantsUtility(.keyboard) { releaseFnIfNobodyListens() }
            return
        }
        for module in Module.allCases {
            let current = entries[module]
            entries[module] = entry(module, version: current?.installedVersion, reply: current?.status)
        }
        // Каталог прочитан, а поставить нечего: запись убрали или ей нужен центр новее.
        if modules.wantsUtility(.keyboard), catalogApp(.keyboard) == nil { releaseFnIfNobodyListens() }
    }

    private func entry(_ module: Module, version: String?, reply: LinkStatus?) -> Entry? {
        let app = available.first { $0.id == module.rawValue }
        guard app != nil || version != nil else { return nil }
        return Entry(catalog: app, installedVersion: version, status: reply, responding: reply != nil)
    }

    // MARK: Опрос

    @objc private func statusDidChange(_ note: Notification) {
        guard let module = Module.allCases.first(where: { KitLink.statusChanged($0.rawValue) == note.name }) else { return }
        statusPinged.send(module)
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
        defer { polled.insert(module) }
        let started = generation[module, default: 0]
        let id = module.rawValue
        let info = environment.paths.appsDir.appendingPathComponent(Self.bundleName(module) + ".app")
        let version = await Task.detached { Self.installedVersion(ofBundle: info) }.value

        var isStale: Bool { busy.contains(module) || generation[module, default: 0] != started }

        var reply: LinkStatus?
        if version != nil { reply = try? await environment.commands.status(id) }
        guard !isStale else { return }

        let handedOver = defaults.bool(forKey: ModuleHandover.handedOverKey(id))
        switch ModuleHandover.decide(bundlePresent: version != nil, handedOver: handedOver) {
        case .notInstalled:
            modules.setExternal(module, false)
            // Прошлая установка сорвалась, а следующей ждать до конца отступа: до недели.
            if module == .keyboard, modules.wantsUtility(module), defaults.object(forKey: ModuleMigration.failuresKey(id)) != nil {
                releaseFnIfNobodyListens()
            }
        case .utilityGone:
            await utilityGone(module)
        case .handOver:
            // Модуль был выключен: утилита передачи не ждёт, а её выключенность выбрал человек.
            let moduleWasOn = modules.enabled.contains(module)
            // Клавиатура при обновлении: разрешение было у центра, утилите его ещё не выдали, а 🌐 отключена. Слушать Fn некому,
            // поэтому один раз возвращаем системе: язык продолжит меняться, отключить снова попросит чек-лист утилиты.
            // До `setEnabled`: утилита при старте читает, держать ли 0. Выключенный модуль 🌐 не держал, это уже настройки утилиты.
            if module == .keyboard, moduleWasOn, reply?.needsSetup != 0 { environment.restoreSystemFn() }
            modules.setExternal(module, true)
            defaults.set(true, forKey: ModuleHandover.handedOverKey(id))
            // Утилита читает ключ из другого процесса, как только получит setEnabled.
            defaults.synchronize()
            if moduleWasOn {
                await enable(module, started: started)
                guard !isStale else { return }
                reply = try? await environment.commands.status(id)
            }
        case .satelliteOwns:
            modules.setExternal(module, true)
            if reply != nil, enableOwed.contains(module) { await enable(module, started: started) }
            // Сброс при первом запуске со Стором коснулся модуля, которого уже ведёт утилита: выключает её сама утилита.
            if reply != nil, modules.takeUtilityReset(module) {
                try? await environment.commands.setEnabled(module.rawValue, false)
                guard !isStale else { return }
                reply = try? await environment.commands.status(id)
            }
        }
        // Пока шли вызовы, модуль могли удалить или поставить заново: старый ответ его бы затёр.
        guard !isStale else { return }
        // Тот же ответ никого не будит: чек-лист опрашивает раз в секунду.
        let new = entry(module, version: version, reply: reply)
        if entries[module] != new {
            entries[module] = new
            // Статус сменился: прежний отказ действия устарел.
            setActionError(module, nil)
        }
    }

    private func enable(_ module: Module, started: Int) async {
        do {
            try await environment.commands.setEnabled(module.rawValue, true)
            enableOwed.remove(module)
        } catch {
            if generation[module, default: 0] == started { enableOwed.insert(module) }
        }
    }

    /// Бандл удалили руками: как удаление в Сторе, строка уходит из панели, модуль снова в Сторе. Если агента снять
    /// не вышло, ключ остаётся и следующий опрос попробует снова; сама утилита 🌐 уже не вернёт.
    private func utilityGone(_ module: Module) async {
        modules.setOn(module, false)
        modules.setExternal(module, false)
        modules.setHidden(module, false)
        enableOwed.remove(module)
        if module == .keyboard { environment.restoreSystemFn() }
        NotificationCenter.default.post(name: .moduleRemoved, object: module)
        let installer = environment.installer
        let id = module.rawValue
        do {
            try await serialized { try installer.removeStaleAgent(id: id) }
            defaults.removeObject(forKey: ModuleHandover.handedOverKey(id))
            // Бандл убрали руками: это тоже выбор человека, автопереход его не отменяет.
            defaults.set(true, forKey: ModuleMigration.removedKey(id))
        } catch {
            return
        }
    }

    /// 🌐 отключена ради утилиты, а её нет и сейчас она не ставится: слушать Fn некому, смена языка мертва. Возвращаем системе,
    /// отключить снова попросит чек-лист утилиты, когда она встанет. Только если 0 держим мы: иначе `restore` зря записал бы
    /// «не держать» и стёр запомненное. Бандл есть — решает передача (`poll`), а обновление и так держит 🌐 для следующей версии.
    private func releaseFnIfNobodyListens() {
        let module = Module.keyboard
        guard !busy.contains(module), environment.systemFnHeld() else { return }
        let bundle = environment.paths.appsDir.appendingPathComponent(Self.bundleName(module) + ".app")
        guard !FileManager.default.fileExists(atPath: bundle.path) else { return }
        environment.restoreSystemFn()
    }

    /// Как у `scripts/build-app.sh`: `Sources/Apps/<Имя>` и имя бандла совпадают с папкой модуля.
    nonisolated static func bundleName(_ module: Module) -> String {
        module.rawValue.capitalized
    }

    /// nil — бандла нет. Info.plist не читается — версия неизвестна и считается самой старой, обновление придёт.
    private nonisolated static func installedVersion(ofBundle bundle: URL) -> String? {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return nil }
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

/// От ответа утилиты на действие нужна только ошибка: состояние разбирает модель модуля.
private struct LinkReplyError: Decodable {
    let error: String?
}
