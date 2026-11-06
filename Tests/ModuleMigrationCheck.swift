import Foundation

// Автопереход модулей на утилиты. Запуск: Tests/run-module-migration-check.sh
// Каталог, установка и состояние модулей подставные, сети и настоящих установок нет; настройки — свой suite.

let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
nonisolated(unsafe) let fm = FileManager.default
let suiteName = "local.utilitumus.test.migration"

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

struct Boom: Error {}

/// Реестру нужен только тип; настоящий лежит в Dashboard.swift вместе со всей отрисовкой.
struct DashConfirmation {
    let title: String, message: String, button: String
    let run: @MainActor () -> Void
}

func catalogJSON(_ ids: [String], minHub: String = "0.6.0") -> Data {
    let apps = ids.map {
        """
        {"id":"\($0)","version":"1.0.0","minHub":"\(minHub)","url":"https://example.invalid/\($0).zip","sha256":"00","sizeMB":1}
        """
    }
    return Data("{\"schema\":1,\"apps\":[\(apps.joined(separator: ","))]}".utf8)
}

/// Подставные зависимости одного сценария: что установлено, что включено, чем ответит каталог и установка.
final class Fake: @unchecked Sendable {
    private let lock = NSLock()
    private var _installs: [String] = []
    private var bundles: Set<String> = []
    var on: Set<String> = []
    var catalog: Result<Data, Error> = .success(catalogJSON(["awake", "mouse"]))
    var installError: [String: Error] = [:]
    var time = Date(timeIntervalSince1970: 1_000_000)
    var hub = "0.6.0"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    var installs: [String] { lock.lock(); defer { lock.unlock() }; return _installs }
    func dropBundle(_ id: String) { lock.lock(); bundles.remove(id); lock.unlock() }

    var env: ModuleMigrationEnvironment {
        ModuleMigrationEnvironment(
            defaults: defaults, hubVersion: hub,
            loadCatalog: { [self] in try catalog.get() },
            isBuiltInOn: { [self] in on.contains($0.rawValue) },
            hasBundle: { [self] module in lock.withLock { bundles.contains(module.rawValue) } },
            install: { [self] module, _ in
                try lock.withLock {
                    _installs.append(module.rawValue)
                    if let error = installError[module.rawValue] { throw error }
                    bundles.insert(module.rawValue)
                }
            },
            now: { [self] in time })
    }
}

func logicChecks() async {
    do {
        let f = Fake()
        f.on = ["awake"]
        await ModuleMigration.run(f.env)
        check(f.installs == ["awake"], "включённый модуль ставится, выключенный нет")
    }
    do {
        let f = Fake()
        f.on = ["awake", "mouse"]
        f.defaults.set(true, forKey: ModuleMigration.removedKey("awake"))
        await ModuleMigration.run(f.env)
        check(f.installs == ["mouse"], "убранный человеком модуль не ставится снова")
    }
    do {
        let f = Fake()
        f.on = ["awake", "mouse"]
        f.installError["awake"] = Boom()
        await ModuleMigration.run(f.env)
        check(f.installs == ["mouse", "awake"], "сбой одного модуля не мешает остальным")
        check(f.defaults.integer(forKey: ModuleMigration.failuresKey("awake")) == 1, "сбой записан")
        check(f.defaults.string(forKey: ModuleMigration.doneKey("awake")) == nil, "сбой не считается переходом")
        await ModuleMigration.run(f.env)
        check(f.installs == ["mouse", "awake"], "повтор раньше срока не пробует снова")
        f.time = f.time.addingTimeInterval(3601)
        await ModuleMigration.run(f.env)
        check(f.installs == ["mouse", "awake", "awake"], "после срока пробует снова")
        check(f.defaults.integer(forKey: ModuleMigration.failuresKey("awake")) == 2, "второй сбой записан")
        f.time = f.time.addingTimeInterval(3601)
        await ModuleMigration.run(f.env)
        check(f.installs.count == 3, "срок после второго сбоя длиннее часа (отступ растёт)")
        f.time = f.time.addingTimeInterval(4 * 3600)
        f.installError["awake"] = nil
        await ModuleMigration.run(f.env)
        check(f.installs.count == 4 && f.defaults.string(forKey: ModuleMigration.doneKey("awake")) == "0.6.0", "удачная попытка записывает переход")
        check(f.defaults.object(forKey: ModuleMigration.retryAfterKey("awake")) == nil, "удача снимает отступ")
    }
    do {
        let f = Fake()
        f.on = ["awake", "mouse"]
        f.installError["mouse"] = URLError(.notConnectedToInternet)
        await ModuleMigration.run(f.env)
        check(f.installs == ["mouse"], "нет сети: остальные модули в этот запуск не пробуются")
        check(ModuleMigration.backoff(failures: 1) == 3600 && ModuleMigration.backoff(failures: 99) == 7 * 24 * 3600, "отступ: час, потолок неделя")
    }
    do {
        let f = Fake()
        f.on = ["awake"]
        f.catalog = .success(catalogJSON([]))
        await ModuleMigration.run(f.env)
        check(f.installs.isEmpty, "пустой каталог: ничего")
        f.catalog = .failure(URLError(.notConnectedToInternet))
        await ModuleMigration.run(f.env)
        check(f.installs.isEmpty, "каталог недоступен: ничего")
        f.catalog = .success(Data("не json".utf8))
        await ModuleMigration.run(f.env)
        check(f.installs.isEmpty, "каталог испорчен: ничего")
        check(f.defaults.object(forKey: ModuleMigration.failuresKey("awake")) == nil, "без каталога сбой не записывается")
    }
    do {
        let f = Fake()
        f.on = ["awake"]
        f.catalog = .success(catalogJSON(["awake"], minHub: "9.0.0"))
        await ModuleMigration.run(f.env)
        check(f.installs.isEmpty, "minHub выше версии центра: ничего")
    }
    do {
        let f = Fake()
        f.on = ["awake"]
        await ModuleMigration.run(f.env)
        f.dropBundle("awake")
        await ModuleMigration.run(f.env)
        check(f.installs == ["awake"], "на той же версии центра переход один раз")
        f.hub = "0.7.0"
        await ModuleMigration.run(f.env)
        check(f.installs == ["awake", "awake"], "на новой версии центра снова")
    }
}

// MARK: - Удаление человеком через настоящий реестр

final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor func registryChecks() async {
    let root = workRoot.appendingPathComponent("registry")
    try? fm.removeItem(at: root)
    let paths = SatellitePaths(appsDir: root.appendingPathComponent("Apps"), agentsDir: root.appendingPathComponent("Agents"))
    for url in [paths.appsDir, paths.agentsDir] { try! fm.createDirectory(at: url, withIntermediateDirectories: true) }
    let journal = Journal()

    func makeRegistry(_ defaults: UserDefaults) -> SatelliteRegistry {
        defaults.set(true, forKey: ModuleReset.flagKey)
        defaults.set(true, forKey: ModuleManager.onKey(.awake))
        let modules = ModuleManager(defaults: defaults) { _ in ModuleHooks(start: {}, stop: {}) }
        let installer = SatelliteInstaller(
            paths: paths, launchctl: { _ in }, download: { _ in throw Boom() }, verify: { _, _ in },
            link: SatelliteLink(quit: { _, _ in journal.add("quit") }, hello: { _ in }))
        return SatelliteRegistry(SatelliteEnvironment(
            paths: paths, defaults: defaults, installer: installer,
            commands: SatelliteCommands(status: { _ in throw Boom() }, setEnabled: { _, _ in }, openWindow: { _ in }),
            loadCatalog: { catalogJSON(["awake"]) }, hubVersion: "0.6.0", modules: modules))
    }
    func makeBundle() {
        let contents = paths.appsDir.appendingPathComponent("Awake.app/Contents")
        try! fm.createDirectory(at: contents, withIntermediateDirectories: true)
        (["CFBundleShortVersionString": "1.0.0"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }

    do {
        let f = Fake()
        let defaults = f.defaults
        let registry = makeRegistry(defaults)
        makeBundle()
        try? await registry.uninstall(.awake)
        check(defaults.bool(forKey: ModuleMigration.removedKey("awake")), "удаление в Сторе записывает выбор человека")
        var env = f.env
        env.defaults = defaults
        f.on = ["awake"]
        await ModuleMigration.run(env)
        check(f.installs.isEmpty, "после удаления в Сторе автопереход не ставит снова")
    }
    do {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: ModuleHandover.handedOverKey("awake"))
        let registry = makeRegistry(defaults)
        try? fm.removeItem(at: paths.appsDir.appendingPathComponent("Awake.app"))
        await registry.update()
        check(defaults.bool(forKey: ModuleMigration.removedKey("awake")), "бандл убран руками: выбор человека записан")
    }
    do {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let registry = makeRegistry(defaults)
        try? fm.removeItem(at: paths.appsDir.appendingPathComponent("Awake.app"))
        let app = try! SatelliteCatalog.decode(catalogJSON(["awake"])).apps[0]
        do { try await registry.install(.awake, app: app) } catch {}
        check(!defaults.bool(forKey: ModuleMigration.removedKey("awake")), "сорвавшаяся установка не пишет выбор человека")
        check(defaults.object(forKey: "App.awake.Enabled") == nil, "сорвавшаяся установка не оставляет Enabled")
    }
}

Task { @MainActor in
    await logicChecks()
    await registryChecks()
    UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
    print(failures == 0 ? "Все проверки прошли" : "Провалов: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
