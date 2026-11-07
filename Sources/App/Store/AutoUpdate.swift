import AppKit
import Security

/// Что автообновление отказывается делать само. Остаётся обновление по кнопке.
enum AutoUpdateRefusal: Error, Equatable {
    /// В новой версии появилось разрешение, которого не было: система спросит человека.
    case newPermissions([String])
    /// На диске версия не старше той, что скачана. Реестр мог не знать о ней.
    case notNewer
}

/// Правила автообновления без времени, сети и состояния.
enum AutoUpdatePolicy {
    /// Читается как «нет ключа — включено»: при переходе на эту версию писать ничего не нужно.
    static let enabledKey = "AutoUpdate.Enabled"
    static let lastCheckKey = "AutoUpdate.LastCheck"
    static let lastRecordKey = "AutoUpdate.LastRecord"
    static func failuresKey(_ id: String) -> String { "AutoUpdate.Failures.\(id)" }
    static func retryAfterKey(_ id: String) -> String { "AutoUpdate.RetryAfter.\(id)" }
    /// Версия, к которой относятся сбои: новый выпуск начинает с чистого листа, сломанный не качается по кругу.
    static func failedVersionKey(_ id: String) -> String { "AutoUpdate.FailedVersion.\(id)" }
    /// Версия, которую отказались ставить сами: повторно её не качаем.
    static func manualVersionKey(_ id: String) -> String { "AutoUpdate.ManualVersion.\(id)" }

    /// Каталог читается раз в 6 часов. Выпуски редкие, файл маленький, а исправление безопасности доходит за рабочий день.
    static let checkInterval: TimeInterval = 6 * 3600
    /// Таймер только сверяет часы и пробует занятых и отложенных заново; сеть он не трогает, пока не подошёл срок.
    static let tickInterval: TimeInterval = 30 * 60

    /// Обновляются только по кнопке, что бы ни было в каталоге:
    /// `fans` — центр не знает, поднята ли в выпуске версия службы; поднята — вентиляторы не работают, пока человек
    /// не введёт пароль (`FanHelperInstaller`). Плюс выход утилиты снимает выбранные человеком обороты.
    /// `clipboard` — ключ истории в файловой связке, подпись без Team ID: новый бинарник может вызвать окно пароля связки
    /// (`ClipboardKeyring`), а проверить это на настоящей связке нельзя.
    static let personOnly: Set<Module> = [.fans, .clipboard]

    /// Срок проверки каталога. Часы могли уйти назад: тогда тоже пора, иначе проверка замрёт надолго.
    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= checkInterval || elapsed < 0
    }

    /// Последняя проверка перед установкой, идёт в установщике после хэша, подписи и метки выпуска. Новый бандл уже проверен.
    @Sendable static func checkStaged(_ staged: URL, _ installed: URL) throws {
        guard let new = version(staged), let old = version(installed), Kit.isNewer(new, than: old) else {
            throw AutoUpdateRefusal.notNewer
        }
        let added = declaredPermissions(staged).subtracting(declaredPermissions(installed))
        guard added.isEmpty else { throw AutoUpdateRefusal.newPermissions(added.sorted()) }
    }

    private static func version(_ bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// То, о чём система спросит или что выдаёт подпись: `NS…UsageDescription` и права из подписи.
    /// «Универсальный доступ» и мониторинг ввода здесь не видны: для них отметка `manualUpdate` в каталоге.
    static func declaredPermissions(_ bundle: URL) -> Set<String> {
        var found: Set<String> = []
        if let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] {
            found.formUnion(info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") })
        }
        var code: SecStaticCode?
        var signing: CFDictionary?
        if SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
           SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
           let entitlements = (signing as NSDictionary?)?[kSecCodeInfoEntitlementsDict] as? [String: Any] {
            found.formUnion(entitlements.keys)
        }
        return found
    }
}

/// Что и когда обновилось само: одна запись на последний проход с результатом.
struct AutoUpdateRecord: Codable, Equatable {
    struct Item: Codable, Equatable {
        let id: String
        let from: String
        let to: String
    }

    let at: Date
    var items: [Item]

    func line(now: Date = Date()) -> String {
        let names = items.map { item in
            "\(Module(rawValue: item.id)?.title ?? item.id) \(item.from) → \(item.to)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Обновилось само: \(names.joined(separator: ", ")). \(formatter.string(from: at))"
    }
}

/// Автообновление утилит: когда проверять и что отдать очереди `UpdateAll`. Ставит та же очередь и тот же установщик, что у
/// кнопки. Работает только внутри запущенного центра, отдельного процесса и окон нет. Центр так сам себя не обновляет.
@MainActor
final class AutoUpdate: ObservableObject {
    static let shared = AutoUpdate()

    /// Только установленный выпуск: пилот и `scripts/dev.sh` (`installsOnItsOwn`), сборка со швом, отмеченная дев-сборка и
    /// собранный руками центр вне «Программ» настоящие утилиты не трогают.
    nonisolated static var liveBuildAllows: Bool {
        #if KIT_TEST_DEFAULTS
        return false
        #else
        return SatelliteRegistry.installsOnItsOwn
            && Bundle.main.object(forInfoDictionaryKey: "UtilitumusDevBuild") == nil
            && Bundle.main.bundleURL.path == "/Applications/Utilitumus.app"
        #endif
    }

    /// Стенд подставляет своё; настоящая сборка их не меняет.
    var buildAllows = AutoUpdate.liveBuildAllows
    var now: () -> Date = { Date() }
    /// Сеть после сна поднимается не сразу.
    var wakeDelay: Duration = .seconds(60)

    private var registry: SatelliteRegistry { .shared }
    private var updates: UpdateAll { .shared }
    private var defaults: UserDefaults { registry.environment.defaults }
    private var timer: Timer?
    private var ticking = false
    /// Запись текущего прохода: новый проход начинает новую.
    private var passRecord: AutoUpdateRecord?

    private init() {}

    // MARK: Что решено

    var isOn: Bool { buildAllows && (defaults.object(forKey: AutoUpdatePolicy.enabledKey) as? Bool ?? true) }

    /// Эту утилиту обновим сами. Занятая тоже: дождётся следующего витка.
    /// `hasUpdate` — только установленная, версия строго новее, каталог её отдал этой версии центра (`minHub`).
    func willHandle(_ module: Module) -> Bool {
        guard isOn, registry.hasUpdate(module), let app = registry.catalogApp(module) else { return false }
        let id = module.rawValue
        if AutoUpdatePolicy.personOnly.contains(module) || app.manualUpdate { return false }
        if defaults.string(forKey: AutoUpdatePolicy.manualVersionKey(id)) == app.version { return false }
        if defaults.string(forKey: AutoUpdatePolicy.failedVersionKey(id)) == app.version,
           now().timeIntervalSince1970 < defaults.double(forKey: AutoUpdatePolicy.retryAfterKey(id)) { return false }
        return true
    }

    var lastRecord: AutoUpdateRecord? {
        defaults.data(forKey: AutoUpdatePolicy.lastRecordKey).flatMap { try? JSONDecoder().decode(AutoUpdateRecord.self, from: $0) }
    }

    var lastLine: String? { lastRecord?.line(now: now()) }

    // MARK: Когда

    /// Запуск центра. Каталог при запуске читает `SatelliteRegistry.start()`, здесь второго чтения нет.
    func start() {
        guard buildAllows, timer == nil else { return }
        let timer = Timer(timeInterval: AutoUpdatePolicy.tickInterval, repeats: true) { _ in
            Task { @MainActor in await AutoUpdate.shared.tick() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Таймер во сне стоит: после пробуждения сверяем часы, а не ждём его.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: AutoUpdate.shared.wakeDelay)
                await AutoUpdate.shared.tick()
            }
        }
        Task {
            await registry.firstRefreshFinished()
            // Каталог не прочитался: второго чтения подряд не будет, дождёмся витка таймера.
            if noteCatalogRead() { await tick() }
        }
    }

    /// Виток: подошёл срок — прочитать каталог; дальше обновить всё, что можно, по уже известному.
    func tick() async {
        guard isOn, !ticking, !updates.installing, Updater.shared.state != .installing else { return }
        ticking = true
        defer { ticking = false }
        let last = defaults.object(forKey: AutoUpdatePolicy.lastCheckKey) as? Date
        if AutoUpdatePolicy.isDue(lastCheck: last, now: now()) {
            await updates.check()
            // Нет сети: тихо. Срок не сдвигается, следующий виток попробует снова.
            guard noteCatalogRead() else { return }
        }
        guard isOn, Updater.shared.state != .installing else { return }
        passRecord = nil
        updates.startAutomatic(Module.allCases.filter(willHandle))
    }

    /// Только удачное чтение сдвигает срок.
    private func noteCatalogRead() -> Bool {
        guard registry.catalogReadAt != nil, !registry.catalogFailed else { return false }
        defaults.set(now(), forKey: AutoUpdatePolicy.lastCheckKey)
        return true
    }

    // MARK: Итоги

    /// Итог, о котором человеку говорить незачем. Сбоем он не считается, строки «Не вышло» не будет.
    func handledQuietly(_ error: Error, module: Module, app: CatalogApp) -> Bool {
        switch error {
        case SatelliteInstallError.busy:
            return true
        case AutoUpdateRefusal.newPermissions(let added):
            NSLog("Utilitumus: %@ %@ просит новое: %@, обновление по кнопке", module.rawValue, app.version, added.joined(separator: ", "))
            defaults.set(app.version, forKey: AutoUpdatePolicy.manualVersionKey(module.rawValue))
            objectWillChange.send()
            return true
        case AutoUpdateRefusal.notNewer:
            noteFailure(module, version: app.version)
            registry.refresh(module)
            return true
        case let error as URLError where error.code != .cancelled:
            return true
        default:
            return false
        }
    }

    /// Пауза как у перехода на утилиту: 1 ч, 4 ч, 16 ч, 64 ч, дальше раз в неделю. Новая версия начинает заново.
    func noteFailure(_ module: Module, version: String) {
        let id = module.rawValue
        let same = defaults.string(forKey: AutoUpdatePolicy.failedVersionKey(id)) == version
        let failures = (same ? defaults.integer(forKey: AutoUpdatePolicy.failuresKey(id)) : 0) + 1
        defaults.set(version, forKey: AutoUpdatePolicy.failedVersionKey(id))
        defaults.set(failures, forKey: AutoUpdatePolicy.failuresKey(id))
        defaults.set(now().addingTimeInterval(ModuleMigration.backoff(failures: failures)).timeIntervalSince1970,
                     forKey: AutoUpdatePolicy.retryAfterKey(id))
        objectWillChange.send()
    }

    func noteUpdated(_ module: Module, from: String, to: String) {
        let id = module.rawValue
        for key in [AutoUpdatePolicy.failuresKey(id), AutoUpdatePolicy.retryAfterKey(id), AutoUpdatePolicy.failedVersionKey(id)] {
            defaults.removeObject(forKey: key)
        }
        var record = passRecord ?? AutoUpdateRecord(at: now(), items: [])
        record.items.append(.init(id: id, from: from, to: to))
        passRecord = record
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: AutoUpdatePolicy.lastRecordKey) }
        objectWillChange.send()
    }
}
