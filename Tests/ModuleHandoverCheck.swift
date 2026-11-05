import Foundation

// Передача модуля от центра утилите и опрос утилит. Запуск: Tests/run-module-handover-check.sh
// Настоящий установщик в папке теста, подставные launchctl, загрузка и связь. Настройки — свой suite.

let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
nonisolated(unsafe) let fm = FileManager.default
let suiteName = "local.utilitumus.test.handover"

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let waiting = LinkStatus(enabled: false, line: "ждёт", needsSetup: 2)
let ready = LinkStatus(enabled: true, line: "работает", needsSetup: 0)

struct Boom: Error {}

/// Журнал из любых потоков: launchctl и загрузка идут не на главном.
final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func has(_ prefix: String) -> Bool { all.contains { $0.hasPrefix(prefix) } }
    func index(_ item: String) -> Int? { all.firstIndex(of: item) }
    func count(_ item: String) -> Int { all.filter { $0 == item }.count }
}

/// Счётчик одновременных вызовов.
final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var peak = 0
    func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
}

/// Записывает `synchronize`: утилита читает ключ передачи из другого процесса.
final class SpyDefaults: UserDefaults, @unchecked Sendable {
    var onSynchronize: () -> Void = {}
    override func synchronize() -> Bool {
        onSynchronize()
        return super.synchronize()
    }
}

/// Папка, suite и все подставные зависимости одного сценария.
@MainActor final class Rig {
    let root: URL
    let paths: SatellitePaths
    let defaults: UserDefaults
    let journal = Journal()
    let gauge = Gauge()
    let box = RigBox()
    let modules: ModuleManager
    let registry: SatelliteRegistry

    init(_ name: String, moduleOn: Bool = false, handedOver: Bool = false, bundle: Bool = false) {
        root = workRoot.appendingPathComponent(name)
        try? fm.removeItem(at: root)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SatellitePaths(appsDir: root.appendingPathComponent("Apps"),
                                   agentsDir: root.appendingPathComponent("Agents"))
        self.paths = paths
        try! fm.createDirectory(at: paths.appsDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: paths.agentsDir, withIntermediateDirectories: true)

        let spy = SpyDefaults(suiteName: suiteName)!
        let spyJournal = journal
        spy.onSynchronize = { spyJournal.add("synchronize handed=\(spy.bool(forKey: "App.awake.HandedOver"))") }
        defaults = spy
        defaults.removePersistentDomain(forName: suiteName)
        // Без флага ModuleOn выглядел бы обновлением со старой версии, и одноразовый сброс выключил бы модули.
        defaults.set(true, forKey: ModuleReset.flagKey)
        defaults.set(moduleOn, forKey: ModuleManager.onKey(.awake))
        if handedOver { defaults.set(true, forKey: "App.awake.HandedOver") }

        let journal = self.journal
        modules = ModuleManager(defaults: defaults) { module in
            ModuleHooks(start: { journal.add("start \(module.rawValue)") },
                        stop: { journal.add("stop \(module.rawValue)") })
        }

        let box = self.box
        box.defaults = defaults
        let gauge = self.gauge
        let installer = SatelliteInstaller(
            paths: paths,
            launchctl: { args in
                journal.add("launchctl \(args[0])")
                Thread.sleep(forTimeInterval: box.launchctlDelay)
            },
            download: { _ in
                gauge.enter()
                defer { gauge.leave() }
                journal.add("download")
                try await Task.sleep(for: .seconds(box.downloadDelay))
                throw Boom()
            },
            verify: { _, _ in },
            link: SatelliteLink(quit: { _ in journal.add("quit") }, hello: { _ in }))
        registry = SatelliteRegistry(SatelliteEnvironment(
            paths: paths,
            defaults: defaults,
            installer: installer,
            commands: SatelliteCommands(
                status: { _ in
                    journal.add("status")
                    Thread.sleep(forTimeInterval: box.statusDelay)
                    return try box.reply.get()
                },
                setEnabled: { _, on in
                    let handed = box.defaults?.bool(forKey: "App.awake.HandedOver") == true
                    journal.add("setEnabled \(on) handed=\(handed)")
                    if box.takeEnableFailure() { throw Boom() }
                },
                openWindow: { _ in journal.add("openWindow") }),
            loadCatalog: { try box.catalog.get() },
            hubVersion: "0.6.0",
            modules: modules))
        if bundle { makeBundle() }
    }

    var bundleURL: URL { paths.appsDir.appendingPathComponent("Awake.app") }
    var agentURL: URL { paths.agentsDir.appendingPathComponent("local.utilitumus.app.awake.plist") }
    var handedOverKey: Bool { defaults.bool(forKey: "App.awake.HandedOver") }

    func makeBundle(version: String = "1.0.0") {
        let contents = bundleURL.appendingPathComponent("Contents")
        try! fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": version]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }

    func makeAgent() {
        try! Data("<plist/>".utf8).write(to: agentURL)
    }
}

/// То, что подставные замыкания читают с чужих потоков.
final class RigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _reply: Result<LinkStatus, Error> = .failure(Boom())
    private var _statusDelay: TimeInterval = 0
    private var _launchctlDelay: TimeInterval = 0
    private var _downloadDelay: TimeInterval = 0
    private var _enableFailures = 0
    private var _catalog: Result<Data, Error> = .failure(Boom())
    var defaults: UserDefaults?

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var reply: Result<LinkStatus, Error> { get { locked { _reply } } set { locked { _reply = newValue } } }
    var statusDelay: TimeInterval { get { locked { _statusDelay } } set { locked { _statusDelay = newValue } } }
    var launchctlDelay: TimeInterval { get { locked { _launchctlDelay } } set { locked { _launchctlDelay = newValue } } }
    var downloadDelay: TimeInterval { get { locked { _downloadDelay } } set { locked { _downloadDelay = newValue } } }
    var enableFailures: Int { get { locked { _enableFailures } } set { locked { _enableFailures = newValue } } }
    var catalog: Result<Data, Error> { get { locked { _catalog } } set { locked { _catalog = newValue } } }
    func takeEnableFailure() -> Bool {
        locked {
            guard _enableFailures > 0 else { return false }
            _enableFailures -= 1
            return true
        }
    }
}

func catalogData(minHub: String = "0.6.0", version: String = "2.0.0") -> Data {
    let app: [String: Any] = ["id": "awake", "version": version, "minHub": minHub,
                              "url": "https://example.com/Awake.zip", "sha256": "ab", "sizeMB": 2]
    return try! JSONSerialization.data(withJSONObject: ["schema": 1, "apps": [app]])
}

func sampleApp(_ id: String = "awake") -> CatalogApp {
    CatalogApp(id: id, version: "2.0.0", minHub: "0.6.0",
               url: URL(string: "https://example.com/App.zip")!, sha256: "ab", sizeMB: 2)
}

// MARK: - Таблица

func tableChecks() {
    typealias D = ModuleHandover.Decision
    func decide(_ bundle: Bool, _ handed: Bool, _ reply: LinkStatus?) -> D {
        ModuleHandover.decide(bundlePresent: bundle, handedOver: handed, reply: reply)
    }
    check(decide(false, false, nil) == .keepBuiltIn, "нет бандла, не передано → встроенный")
    check(decide(false, true, nil) == .returnToBuiltIn, "нет бандла, передано → вернуть встроенный")
    check(decide(false, true, ready) == .returnToBuiltIn, "нет бандла, передано, ответ есть → всё равно вернуть")
    check(decide(true, false, nil) == .keepBuiltIn, "бандл, не передано, нет ответа → встроенный")
    check(decide(true, false, waiting) == .keepBuiltIn, "бандл, не передано, чек-лист не сделан → встроенный")
    check(decide(true, false, ready) == .handOver, "бандл, не передано, чек-лист сделан → передать")
    check(decide(true, true, ready) == .satelliteOwns, "бандл, передано, ответ есть → у утилиты")
    check(decide(true, true, waiting) == .satelliteOwns, "бандл, передано, чек-лист не сделан → у утилиты")
    check(decide(true, true, nil) == .satelliteOwns, "бандл, передано, нет ответа → у утилиты")
}

// MARK: - ModuleManager

@MainActor func managerChecks() {
    do {
        let rig = Rig("manager-stop", moduleOn: true)
        rig.modules.startEnabled()
        check(rig.journal.count("start awake") == 1, "встроенный запущен")
        rig.modules.setExternal(.awake, true)
        check(rig.journal.count("stop awake") == 1, "setExternal(true) останавливает встроенный")
        check(rig.modules.isOn(.awake) && rig.modules.isInstalled(.awake), "внешний модуль считается включённым и установленным")
        check(!rig.modules.runsBuiltIn(.awake), "встроенный не работает")
        check(rig.defaults.bool(forKey: ModuleManager.onKey(.awake)), "ModuleOn не меняется")
        rig.modules.setOn(.awake, true)
        check(rig.journal.count("start awake") == 1, "setOn при внешнем варианте не стартует встроенный")
        rig.modules.setExternal(.awake, false)
        check(rig.journal.count("start awake") == 2, "снятие внешнего варианта стартует встроенный")
    }
    do {
        let rig = Rig("manager-off")
        rig.modules.startEnabled()
        rig.modules.setExternal(.awake, true)
        check(rig.modules.isOn(.awake) && rig.modules.isInstalled(.awake), "внешний при выключенном встроенном виден как установленный")
        check(!rig.journal.has("start"), "и встроенный не стартует")
        rig.modules.setExternal(.awake, false)
        check(!rig.modules.isOn(.awake) && !rig.journal.has("start"), "снятие внешнего варианта не включает выключенный модуль")
    }
    do {
        let rig = Rig("manager-launch", moduleOn: true, handedOver: true)
        check(rig.modules.isExternal(.awake), "передача видна сразу при создании менеджера")
        rig.modules.startEnabled()
        check(!rig.journal.has("start"), "при запуске переданный модуль не стартует даже на миг")
    }
}

// MARK: - Опрос

@MainActor func pollChecks() async {
    do {
        let rig = Rig("return", moduleOn: true, handedOver: true)
        rig.makeAgent()
        rig.modules.startEnabled()
        await rig.registry.update()
        check(rig.journal.has("launchctl bootout"), "бандл удалён: агент снят")
        check(!fm.fileExists(atPath: rig.agentURL.path), "бандл удалён: плист удалён")
        check(!rig.handedOverKey, "бандл удалён: HandedOver сброшен")
        check(!rig.modules.isExternal(.awake), "бандл удалён: модуль снова встроенный")
        check(rig.journal.count("start awake") == 1, "бандл удалён: встроенный снова работает")
        check(rig.registry.entries[.awake]?.installedVersion == nil, "бандл удалён: версии нет")
    }
    do {
        let rig = Rig("no-reply", moduleOn: true, bundle: true)
        rig.modules.startEnabled()
        await rig.registry.update()
        check(rig.registry.entries[.awake]?.responding == false, "нет ответа: responding = false")
        check(rig.registry.entries[.awake]?.installedVersion == "1.0.0", "версия читается из бандла")
        check(!rig.modules.isExternal(.awake) && !rig.journal.has("stop"), "нет ответа до передачи: встроенный работает")
        check(!rig.handedOverKey, "нет ответа до передачи: ключа нет")
    }
    do {
        let rig = Rig("needs-setup", moduleOn: true, bundle: true)
        rig.box.reply = .success(waiting)
        rig.modules.startEnabled()
        await rig.registry.update()
        check(rig.registry.entries[.awake]?.status == waiting, "статус утилиты записан")
        check(rig.registry.entries[.awake]?.responding == true, "ответ есть: responding = true")
        check(!rig.modules.isExternal(.awake) && !rig.journal.has("stop"), "чек-лист не сделан: встроенный работает")
        check(!rig.journal.has("setEnabled"), "чек-лист не сделан: команд утилите нет")
    }
    do {
        let rig = Rig("needs-setup-off", bundle: true)
        rig.box.reply = .success(waiting)
        await rig.registry.update()
        check(rig.modules.isExternal(.awake), "встроенный выключен, утилита есть: страница утилиты, не «＋»")
        check(!rig.handedOverKey, "и передачи ещё не было")
        rig.modules.setOn(.awake, true)
        await rig.registry.update()
        check(!rig.modules.isExternal(.awake) && rig.modules.runsBuiltIn(.awake),
              "встроенный снова включён, передачи не было: он и работает")
    }
    do {
        let rig = Rig("hand-over", moduleOn: true, bundle: true)
        rig.box.reply = .success(ready)
        rig.modules.startEnabled()
        await rig.registry.update()
        let stop = rig.journal.index("stop awake")
        let enable = rig.journal.index("setEnabled true handed=true")
        check(stop != nil, "передача: встроенный остановлен")
        check(enable != nil, "передача: setEnabled(true) ушёл при уже поставленном HandedOver")
        if let stop, let enable { check(stop < enable, "передача: сначала стоп встроенного, потом setEnabled") }
        let synced = rig.journal.index("synchronize handed=true")
        check(synced != nil, "передача: ключ сброшен на диск")
        if let synced, let enable { check(synced < enable, "передача: synchronize до setEnabled") }
        check(rig.handedOverKey && rig.modules.isExternal(.awake), "передача: ключ и внешний вариант")
        check(rig.defaults.bool(forKey: ModuleManager.onKey(.awake)), "передача: ModuleOn не тронут")
        await rig.registry.update()
        check(rig.journal.count("setEnabled true handed=true") == 1, "повторный опрос не шлёт setEnabled")
    }
    do {
        let rig = Rig("owns-no-reply", moduleOn: true, handedOver: true, bundle: true)
        rig.modules.startEnabled()
        await rig.registry.update()
        check(rig.modules.isExternal(.awake) && rig.handedOverKey, "передано, нет ответа: остаётся у утилиты")
        check(!rig.journal.has("start"), "передано, нет ответа: встроенный не включается")
        check(rig.registry.entries[.awake]?.responding == false, "передано, нет ответа: «не отвечает»")
        check(!rig.journal.has("launchctl"), "передано, нет ответа: агент не тронут")
    }
    do {
        let rig = Rig("enable-retry", moduleOn: true, bundle: true)
        rig.box.reply = .success(ready)
        rig.box.enableFailures = 1
        await rig.registry.update()
        check(rig.handedOverKey, "setEnabled сорвался: передача всё равно записана")
        check(rig.journal.count("setEnabled true handed=true") == 1, "первая попытка setEnabled")
        await rig.registry.update()
        check(rig.journal.count("setEnabled true handed=true") == 2, "следующий опрос повторяет setEnabled")
        await rig.registry.update()
        check(rig.journal.count("setEnabled true handed=true") == 2, "после успеха больше не повторяет")
    }
}

// MARK: - Главный поток

/// Самый длинный перерыв между тиками главного потока, пока идёт `body`.
@MainActor func longestStall(during body: () async -> Void) async -> TimeInterval {
    var longest: TimeInterval = 0
    var last = Date()
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
        let now = Date()
        longest = max(longest, now.timeIntervalSince(last))
        last = now
    }
    RunLoop.main.add(timer, forMode: .common)
    await body()
    timer.invalidate()
    return longest
}

@MainActor func stallChecks() async {
    do {
        let rig = Rig("stall-status", handedOver: true, bundle: true)
        rig.box.statusDelay = 1
        let started = Date()
        let stall = await longestStall { await rig.registry.update() }
        check(Date().timeIntervalSince(started) >= 1, "зависшая утилита действительно задержала опрос")
        check(stall < 0.3, "зависшая утилита: главный поток свободен (перерыв \(stall) с)")
    }
    do {
        let rig = Rig("stall-launchctl", handedOver: true)
        rig.makeAgent()
        rig.box.launchctlDelay = 1
        let stall = await longestStall { await rig.registry.update() }
        check(rig.journal.has("launchctl bootout"), "launchctl вызван")
        check(stall < 0.3, "медленный launchctl: главный поток свободен (перерыв \(stall) с)")
    }
    do {
        let rig = Rig("stall-refresh", handedOver: true, bundle: true)
        rig.box.statusDelay = 1
        let started = Date()
        rig.registry.refresh()
        check(Date().timeIntervalSince(started) < 0.3, "refresh() возвращается сразу")
    }
}

// MARK: - Установщик через реестр

@MainActor func serialChecks() async {
    do {
        let rig = Rig("serial")
        rig.box.downloadDelay = 0.1
        await withTaskGroup(of: Void.self) { group in
            for module in [Module.awake, .clipboard, .keyboard] {
                group.addTask { @MainActor in try? await rig.registry.install(module, app: sampleApp(module.rawValue)) }
            }
        }
        check(rig.journal.count("download") == 3, "все три установки дошли до установщика")
        check(rig.gauge.peak == 1, "установщик вызывается по одному (одновременно: \(rig.gauge.peak))")
        check(rig.registry.busy.isEmpty, "после ошибок никто не занят")
    }
    do {
        let rig = Rig("busy", moduleOn: true, handedOver: true)
        rig.makeAgent()
        rig.box.downloadDelay = 0.5
        let install = Task { @MainActor in try? await rig.registry.install(.awake, app: sampleApp()) }
        await Task.yield()
        try? await Task.sleep(for: .seconds(0.1))
        check(rig.registry.busy.contains(.awake), "идёт установка: модуль занят")
        await rig.registry.update()
        check(rig.handedOverKey && fm.fileExists(atPath: rig.agentURL.path),
              "опрос во время установки не снимает агента и не сбрасывает передачу")
        await install.value
    }
    do {
        let rig = Rig("enabled-key")
        do {
            try await rig.registry.install(.awake, app: sampleApp())
            check(false, "установка с подставной загрузкой должна упасть")
        } catch {
            check(error is Boom, "ошибка установщика доходит до вызвавшего")
        }
        check(rig.defaults.object(forKey: "App.awake.Enabled") == nil, "сорвавшаяся установка не оставляет App.awake.Enabled")
        check(!rig.registry.busy.contains(.awake), "после ошибки модуль не занят")
    }
    do {
        let rig = Rig("uninstall", moduleOn: true, handedOver: true, bundle: true)
        rig.makeAgent()
        rig.defaults.set("значение", forKey: "Awake.Настройка")
        rig.modules.startEnabled()
        check(!rig.journal.has("start"), "до удаления встроенный не работает")
        try? await rig.registry.uninstall(.awake)
        check(rig.journal.has("quit"), "удаление: утилите сказали выйти")
        check(rig.journal.has("launchctl bootout"), "удаление: агент снят")
        check(!fm.fileExists(atPath: rig.bundleURL.path) && !fm.fileExists(atPath: rig.agentURL.path), "удаление: нет бандла и плиста")
        check(!rig.handedOverKey, "удаление: HandedOver сброшен")
        check(!rig.modules.isOn(.awake) && !rig.modules.isExternal(.awake), "удаление: модуль выключен")
        check(!rig.journal.has("start"), "удаление: встроенный не стартует и на миг")
        check(rig.defaults.string(forKey: "Awake.Настройка") == "значение", "удаление: настройки остаются")
    }
}

// MARK: - Каталог

@MainActor func catalogChecks() async {
    do {
        let rig = Rig("catalog-down", bundle: true)
        await rig.registry.update()
        check(rig.registry.catalogApp(.awake) == nil, "каталог недоступен: записи нет")
        check(rig.registry.entries[.awake]?.installedVersion == "1.0.0", "каталог недоступен: установленное видно")
        rig.box.catalog = .success(catalogData())
        await rig.registry.update()
        check(rig.registry.catalogApp(.awake)?.version == "2.0.0", "каталог загрузился")
        check(rig.registry.hasUpdate(.awake), "в каталоге новее: есть обновление")
        rig.box.catalog = .failure(Boom())
        await rig.registry.update()
        check(rig.registry.catalogApp(.awake)?.version == "2.0.0", "сбой каталога не стирает последний удачный")
        rig.box.catalog = .success(Data("не json".utf8))
        await rig.registry.update()
        check(rig.registry.catalogApp(.awake)?.version == "2.0.0", "мусор вместо каталога не стирает последний удачный")
    }
    do {
        let rig = Rig("catalog-minhub")
        rig.box.catalog = .success(catalogData(minHub: "9.0.0"))
        await rig.registry.update()
        check(rig.registry.catalogApp(.awake) == nil, "приложение для более нового центра не предлагается")
    }
    do {
        let rig = Rig("catalog-entry")
        rig.box.catalog = .success(catalogData())
        await rig.registry.update()
        check(rig.registry.entries[.awake]?.catalog?.id == "awake", "запись содержит приложение каталога")
        check(rig.registry.entries[.sound] == nil, "у модуля без каталога и бандла записи нет")
    }
}

// MARK: - Уведомление

@MainActor func notificationChecks() async {
    let rig = Rig("status-changed", handedOver: true, bundle: true)
    rig.box.reply = .success(waiting)
    rig.registry.start()
    for _ in 0..<50 where rig.registry.entries[.awake]?.status != waiting {
        try? await Task.sleep(for: .seconds(0.05))
    }
    check(rig.registry.entries[.awake]?.status == waiting, "start() опрашивает при запуске")
    rig.box.reply = .success(ready)
    KitLink.postStatusChanged("awake")
    for _ in 0..<60 where rig.registry.entries[.awake]?.status != ready {
        try? await Task.sleep(for: .seconds(0.05))
    }
    check(rig.registry.entries[.awake]?.status == ready, "statusChanged: статус перечитан по связи")
}

Task { @MainActor in
    tableChecks()
    managerChecks()
    await pollChecks()
    await stallChecks()
    await serialChecks()
    await catalogChecks()
    await notificationChecks()
    UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
    print(failures == 0 ? "Все проверки прошли" : "Провалов: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
