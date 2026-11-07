import Foundation

// Передача модуля от центра утилите и опрос утилит. Запуск: Tests/run-module-handover-check.sh
// Настоящий установщик в папке теста, подставные launchctl, загрузка и связь. Настройки — свой suite. Настоящий FnSystemAction
// собран со швом: AppleFnUsageType живёт в ключе Test.FnUsage домена Kit.

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
    let module: Module

    init(_ name: String, module: Module = .awake, moduleOn: Bool = false, handedOver: Bool = false, bundle: Bool = false) {
        self.module = module
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
        let handedKey = "App.\(module.rawValue).HandedOver"
        spy.onSynchronize = { spyJournal.add("synchronize handed=\(spy.bool(forKey: handedKey))") }
        defaults = spy
        defaults.removePersistentDomain(forName: suiteName)
        // Без флага ModuleOn выглядел бы обновлением со старой версии, и одноразовый сброс выключил бы модули.
        defaults.set(true, forKey: ModuleReset.flagKey)
        defaults.set(moduleOn, forKey: ModuleManager.onKey(module))
        if handedOver { defaults.set(true, forKey: handedKey) }

        let journal = self.journal
        modules = ModuleManager(defaults: defaults)

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
            link: SatelliteLink(quit: { _, _ in journal.add("quit") }, hello: { _ in }))
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
                setEnabled: { id, on in
                    let handed = box.defaults?.bool(forKey: "App.\(id).HandedOver") == true
                    journal.add("setEnabled \(on) handed=\(handed)")
                    try await Task.sleep(for: .seconds(box.enableDelay))
                    if box.takeEnableFailure() { throw Boom() }
                },
                openWindow: { _ in journal.add("openWindow") }),
            loadCatalog: { try box.catalog.get() },
            hubVersion: "0.6.0",
            modules: modules,
            // Настоящий FnSystemAction: сборка со швом пишет в ключи Test.* домена Kit, run-скрипт проверяет это по nm.
            restoreSystemFn: {
                journal.add("fn restore")
                FnSystemAction.restore()
            },
            systemFnHeld: { FnSystemAction.keepsOff }))
        if bundle { makeBundle() }
    }

    var bundleURL: URL { paths.appsDir.appendingPathComponent(SatelliteRegistry.bundleName(module) + ".app") }
    var agentURL: URL { paths.agentsDir.appendingPathComponent("local.utilitumus.app.\(module.rawValue).plist") }
    var handedOverKey: Bool { defaults.bool(forKey: "App.\(module.rawValue).HandedOver") }

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
    private var _enableDelay: TimeInterval = 0
    private var _catalog: Result<Data, Error> = .failure(Boom())
    var defaults: UserDefaults?

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var reply: Result<LinkStatus, Error> { get { locked { _reply } } set { locked { _reply = newValue } } }
    var statusDelay: TimeInterval { get { locked { _statusDelay } } set { locked { _statusDelay = newValue } } }
    var launchctlDelay: TimeInterval { get { locked { _launchctlDelay } } set { locked { _launchctlDelay = newValue } } }
    var downloadDelay: TimeInterval { get { locked { _downloadDelay } } set { locked { _downloadDelay = newValue } } }
    var enableFailures: Int { get { locked { _enableFailures } } set { locked { _enableFailures = newValue } } }
    var enableDelay: TimeInterval { get { locked { _enableDelay } } set { locked { _enableDelay = newValue } } }
    var catalog: Result<Data, Error> { get { locked { _catalog } } set { locked { _catalog = newValue } } }
    func takeEnableFailure() -> Bool {
        locked {
            guard _enableFailures > 0 else { return false }
            _enableFailures -= 1
            return true
        }
    }
}

func catalogData(id: String = "awake", minHub: String = "0.6.0", version: String = "2.0.0") -> Data {
    let app: [String: Any] = ["id": id, "version": version, "minHub": minHub,
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
    func decide(_ bundle: Bool, _ handed: Bool) -> D {
        ModuleHandover.decide(bundlePresent: bundle, handedOver: handed)
    }
    check(decide(false, false) == .notInstalled, "нет бандла, не передано → утилиты нет")
    check(decide(false, true) == .utilityGone, "нет бандла, передано → утилиту убрали")
    check(decide(true, false) == .handOver, "бандл, не передано → передать, чек-лист тут ни при чём")
    check(decide(true, true) == .satelliteOwns, "бандл, передано → у утилиты")
    check(ModuleHandover.handedOverKey("awake") == "App.awake.HandedOver", "имя ключа передачи не меняется")
    check(ModuleHandover.handedOverKey("awake") == SatelliteRole.handedOverKey("awake"), "выпущенные утилиты читают тот же ключ")
}

// MARK: - ModuleManager

@MainActor func managerChecks() {
    do {
        let rig = Rig("manager-wants", moduleOn: true)
        check(rig.modules.wantsUtility(.awake), "включён, утилита не ведёт: нужна утилита")
        check(rig.modules.isOn(.awake) && rig.modules.isInPanel(.awake), "и строка в панели есть")
        rig.modules.setExternal(.awake, true)
        check(rig.modules.isOn(.awake) && rig.modules.isInstalled(.awake), "внешний модуль считается включённым и установленным")
        check(!rig.modules.wantsUtility(.awake), "утилита ведёт: ставить нечего")
        check(rig.defaults.bool(forKey: ModuleManager.onKey(.awake)), "ModuleOn не меняется")
        rig.modules.setExternal(.awake, false)
        check(rig.modules.wantsUtility(.awake), "снятие внешнего при включённом: снова нужна утилита")
    }
    do {
        let rig = Rig("manager-off")
        check(!rig.modules.wantsUtility(.awake), "выключенному утилита не нужна")
        rig.modules.setExternal(.awake, true)
        check(rig.modules.isOn(.awake) && rig.modules.isInstalled(.awake), "внешний при выключенном виден как установленный")
        rig.modules.setExternal(.awake, false)
        check(!rig.modules.isOn(.awake), "снятие внешнего варианта не включает выключенный модуль")
    }
    do {
        let rig = Rig("manager-launch", moduleOn: true, handedOver: true)
        check(rig.modules.isExternal(.awake), "передача видна сразу при создании менеджера")
        check(!rig.modules.wantsUtility(.awake), "при запуске переданному утилиту не ставим")
    }
}

// MARK: - Опрос

/// Что `SatelliteRole` решит у выпущенной утилиты, запущенной launchd при живом центре.
@MainActor func role(_ rig: Rig) -> SatelliteRole.Mode {
    SatelliteRole.decide(launchedByLaunchd: true, hubRunning: true, hubVersion: "0.8.0",
                         hubModuleOn: rig.defaults.bool(forKey: SatelliteRole.hubModuleOnKey(rig.module.rawValue)),
                         handedOver: rig.defaults.bool(forKey: SatelliteRole.handedOverKey(rig.module.rawValue)))
}

@MainActor func pollChecks() async {
    do {
        // Главное: чек-лист не сделан, а передать всё равно надо, иначе выпущенная утилита не заработает никогда.
        let rig = Rig("old-passive", moduleOn: true, bundle: true)
        rig.box.reply = .success(waiting)
        check(role(rig) == .passive(reason: "Ждём передачу от центра"), "старая утилита до опроса пассивна: ждёт центр")
        check(rig.modules.wantsUtility(.awake), "до опроса модуль без утилиты")
        await rig.registry.update()
        check(rig.handedOverKey, "чек-лист не сделан: ключ передачи всё равно записан")
        check(role(rig) == .active, "старая утилита становится активной")
        check(rig.modules.isExternal(.awake) && !rig.modules.wantsUtility(.awake), "чек-лист не сделан: страница утилиты")
        check(rig.journal.count("setEnabled true handed=true") == 1, "чек-лист не сделан: утилите сказано работать")
        check(rig.registry.entries[.awake]?.status == waiting, "статус утилиты записан: чек-лист покажет её шаги")
        check(rig.registry.entries[.awake]?.responding == true, "ответ есть: responding = true")
        check(rig.defaults.bool(forKey: ModuleManager.onKey(.awake)), "ModuleOn не тронут")
    }
    do {
        let rig = Rig("no-reply", moduleOn: true, bundle: true)
        await rig.registry.update()
        check(rig.registry.entries[.awake]?.responding == false, "нет ответа: responding = false")
        check(rig.registry.entries[.awake]?.installedVersion == "1.0.0", "версия читается из бандла")
        check(rig.handedOverKey && rig.modules.isExternal(.awake), "нет ответа до передачи: всё равно передаём")
        check(role(rig) == .active, "нет ответа: при следующем запуске утилита уже активна")
    }
    do {
        let rig = Rig("needs-setup-off", bundle: true)
        rig.box.reply = .success(waiting)
        await rig.registry.update()
        check(rig.modules.isExternal(.awake), "модуль выключен, утилита есть: страница утилиты, не «＋»")
        check(rig.handedOverKey, "модуль выключен: передача записана")
        check(!rig.journal.has("setEnabled"), "модуль выключен: включать утилиту не просим, это её настройка")
    }
    do {
        let rig = Rig("not-installed", moduleOn: true)
        check(!rig.registry.polled.contains(.awake), "до первого опроса про утилиту ничего не известно")
        await rig.registry.update()
        check(rig.registry.polled.contains(.awake), "опрос записан: страница «утилиты нет» верна")
        check(rig.modules.wantsUtility(.awake) && rig.modules.isInPanel(.awake), "включён, утилиты нет: строка остаётся, нужна установка")
        check(!rig.defaults.bool(forKey: ModuleMigration.removedKey("awake")), "человек ничего не убирал: автопереход не запрещён")
        check(!rig.handedOverKey && !rig.journal.has("launchctl"), "ключа нет, агента не трогаем")
    }
    do {
        let rig = Rig("hand-over", moduleOn: true, bundle: true)
        rig.box.reply = .success(ready)
        await rig.registry.update()
        let enable = rig.journal.index("setEnabled true handed=true")
        check(enable != nil, "передача: setEnabled(true) ушёл при уже поставленном HandedOver")
        let synced = rig.journal.index("synchronize handed=true")
        check(synced != nil, "передача: ключ сброшен на диск")
        if let synced, let enable { check(synced < enable, "передача: synchronize до setEnabled") }
        check(rig.handedOverKey && rig.modules.isExternal(.awake), "передача: ключ и внешний вариант")
        check(rig.defaults.bool(forKey: ModuleManager.onKey(.awake)), "передача: ModuleOn не тронут")
        await rig.registry.update()
        check(rig.journal.count("setEnabled true handed=true") == 1, "повторный опрос не шлёт setEnabled")
    }
    do {
        // Человек выключил утилиту сам, центр запустился позже: встроенный не работал, передавать нечего.
        let rig = Rig("hand-over-module-off", bundle: true)
        rig.box.reply = .success(ready)
        await rig.registry.update()
        check(rig.handedOverKey && rig.modules.isExternal(.awake), "модуль был выключен: передача записана")
        check(!rig.journal.has("setEnabled"), "модуль был выключен: setEnabled утилите не уходит")
        check(rig.registry.entries[.awake]?.status == ready, "модуль был выключен: статус записан")
    }
    do {
        // Модуль удалили, пока утилита медлила с ответом на setEnabled.
        let rig = Rig("stale-enable", moduleOn: true, bundle: true)
        rig.makeAgent()
        rig.box.reply = .success(ready)
        rig.box.enableDelay = 0.4
        let polling = Task { @MainActor in await rig.registry.update() }
        for _ in 0..<40 where !rig.journal.has("setEnabled") { try? await Task.sleep(for: .seconds(0.01)) }
        try? await rig.registry.uninstall(.awake)
        let before = rig.journal.count("status")
        await polling.value
        check(rig.registry.entries[.awake]?.installedVersion == nil, "удаление во время setEnabled: старый опрос не вернул запись")
        check(rig.journal.count("status") == before, "удаление во время setEnabled: статус удалённого не спрашиваем")
    }
    do {
        // Тот же случай, setEnabled ещё и сорвался: долга перед удалённой утилитой быть не должно.
        let rig = Rig("stale-enable-failed", moduleOn: true, bundle: true)
        rig.makeAgent()
        rig.box.reply = .success(ready)
        rig.box.enableDelay = 0.4
        rig.box.enableFailures = 1
        let polling = Task { @MainActor in await rig.registry.update() }
        for _ in 0..<40 where !rig.journal.has("setEnabled") { try? await Task.sleep(for: .seconds(0.01)) }
        try? await rig.registry.uninstall(.awake)
        await polling.value
        rig.box.enableDelay = 0
        rig.defaults.set(true, forKey: "App.awake.HandedOver")
        rig.makeBundle()
        await rig.registry.update()
        check(rig.journal.count("setEnabled true handed=true") == 1, "сорвавшийся setEnabled удалённой утилиты не повторяется для новой")
    }
    do {
        let rig = Rig("owns-no-reply", moduleOn: true, handedOver: true, bundle: true)
        await rig.registry.update()
        check(rig.modules.isExternal(.awake) && rig.handedOverKey, "передано, нет ответа: остаётся у утилиты")
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
        try? await rig.registry.uninstall(.awake)
        check(rig.journal.has("quit"), "удаление: утилите сказали выйти")
        check(rig.journal.has("launchctl bootout"), "удаление: агент снят")
        check(!fm.fileExists(atPath: rig.bundleURL.path) && !fm.fileExists(atPath: rig.agentURL.path), "удаление: нет бандла и плиста")
        check(!rig.handedOverKey, "удаление: HandedOver сброшен")
        check(!rig.modules.isOn(.awake) && !rig.modules.isExternal(.awake), "удаление: модуль выключен")
        check(!rig.journal.has("fn restore"), "удаление не Клавиатуры: Fn не трогаем")
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

// MARK: - Утилиту удалили руками

/// Ловит `.moduleRemoved`, как главное окно.
@MainActor final class RemovalSpy {
    private(set) var removed: [Module] = []
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(forName: .moduleRemoved, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated { if let module = note.object as? Module { self?.removed.append(module) } }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

@MainActor func goneChecks() async {
    for module in Module.allCases {
        let name = module.rawValue
        let rig = Rig("gone-\(name)", module: module, moduleOn: true, handedOver: true)
        rig.makeAgent()
        rig.modules.setHidden(module, true)
        let spy = RemovalSpy()
        await rig.registry.update()
        check(rig.journal.has("launchctl bootout") && !fm.fileExists(atPath: rig.agentURL.path), "\(name) удалён руками: агент снят")
        check(!rig.handedOverKey, "\(name) удалён руками: HandedOver сброшен")
        check(rig.defaults.bool(forKey: ModuleMigration.removedKey(name)), "\(name) удалён руками: сам не поставится")
        check(!rig.modules.isExternal(module) && !rig.modules.isOn(module) && !rig.modules.isInstalled(module), "\(name) удалён руками: снова только в Сторе")
        check(!rig.modules.isInPanel(module) && !rig.modules.panelModules.contains(module), "\(name) удалён руками: строки в панели нет")
        check(!rig.modules.wantsUtility(module), "\(name) удалён руками: страницы «утилиты нет» не будет")
        check(!rig.defaults.bool(forKey: ModuleManager.onKey(module)), "\(name) удалён руками: ModuleOn снят")
        check(!rig.modules.isHidden(module), "\(name) удалён руками: скрытие снято, как при удалении в Сторе")
        check(spy.removed == [module], "\(name) удалён руками: окно уходит с его страницы")
        check(rig.registry.entries[module]?.installedVersion == nil, "\(name) удалён руками: версии нет")
        check(rig.journal.count("fn restore") == (module == .keyboard ? 1 : 0), "\(name) удалён руками: Fn трогает только Клавиатура")
        let handedCalls = rig.journal.count("launchctl bootout")
        await rig.registry.update()
        check(rig.journal.count("launchctl bootout") == handedCalls && spy.removed == [module], "\(name) удалён руками: следующий опрос ничего не повторяет")
    }
    do {
        // Модуль был выключен: так живут утилиты, поставленные из Стора.
        let rig = Rig("gone-module-off", handedOver: true)
        await rig.registry.update()
        check(!rig.modules.isInstalled(.awake) && !rig.handedOverKey, "утилита из Стора удалена руками: тоже только в Сторе")
    }
    do {
        // Агента снять не вышло: ключ остаётся, следующий опрос пробует снова, а строки в панели уже нет.
        let rig = Rig("gone-agent-stuck", moduleOn: true, handedOver: true)
        rig.makeAgent()
        try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.paths.agentsDir.path)
        await rig.registry.update()
        check(rig.handedOverKey && !rig.defaults.bool(forKey: ModuleMigration.removedKey("awake")), "агент не снялся: ключ остаётся")
        check(!rig.modules.isInstalled(.awake), "агент не снялся: строки в панели всё равно нет")
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.paths.agentsDir.path)
        await rig.registry.update()
        check(!rig.handedOverKey && !fm.fileExists(atPath: rig.agentURL.path), "агент не снялся: следующий опрос довёл до конца")
        check(rig.defaults.bool(forKey: ModuleMigration.removedKey("awake")), "агент снялся: выбор человека записан")
    }
}

// MARK: - Fn

/// Состояние настоящего `FnSystemAction` в домене Kit: мы держим 0, у человека было 1.
func holdFnOff() {
    let kit = Kit.defaults
    for key in ["Keyboard.SavedFnUsage", "Keyboard.KeepSystemFnOff", "Keyboard.SavedDictationEnabled", "Test.ApplyCount"] { kit.removeObject(forKey: key) }
    kit.set(1, forKey: "Test.FnUsage")
    FnSystemAction.disable()
}

@MainActor func fnChecks() async {
    let kit = Kit.defaults
    do {
        let rig = Rig("fn-gone", module: .keyboard, moduleOn: true, handedOver: true)
        holdFnOff()
        check(FnSystemAction.usage == 0 && FnSystemAction.keepsOff, "подготовка: 🌐 отключена")
        await rig.registry.update()
        check(FnSystemAction.usage == 1, "Клавиатуру удалили руками: 🌐 снова как была у человека")
        check(!FnSystemAction.keepsOff && kit.object(forKey: "Keyboard.SavedFnUsage") == nil, "Клавиатуру удалили руками: запомненное снято")
        check(kit.integer(forKey: "Test.ApplyCount") == 2, "Клавиатуру удалили руками: система применила настройки")
    }
    do {
        let rig = Rig("fn-store", module: .keyboard, moduleOn: true, handedOver: true, bundle: true)
        rig.makeAgent()
        holdFnOff()
        try? await rig.registry.uninstall(.keyboard)
        check(FnSystemAction.usage == 1, "удаление в Сторе, утилита не ответила: 🌐 всё равно возвращена")
    }
    do {
        let rig = Rig("fn-handover", module: .keyboard, moduleOn: true, bundle: true)
        rig.box.reply = .success(waiting)
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 1, "передача без разрешения: 🌐 вернулась системе")
        check(rig.journal.count("fn restore") == 1, "передача без разрешения: один раз")
        if let restored = rig.journal.index("fn restore"), let enabled = rig.journal.index("setEnabled true handed=true") {
            check(restored < enabled, "передача без разрешения: возврат до setEnabled, утилита прочитает новое")
        } else {
            check(false, "передача без разрешения: возврат и setEnabled в журнале")
        }
        // Человек сам отключил 🌐 в чек-листе утилиты: следующие опросы это не откатывают.
        FnSystemAction.disable()
        await rig.registry.update()
        check(rig.journal.count("fn restore") == 1 && FnSystemAction.usage == 0, "передача без разрешения: повторный опрос Fn не трогает")
    }
    do {
        let rig = Rig("fn-handover-no-reply", module: .keyboard, moduleOn: true, bundle: true)
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 1, "передача без ответа: разрешения неизвестны, 🌐 вернулась")
    }
    do {
        let rig = Rig("fn-handover-ready", module: .keyboard, moduleOn: true, bundle: true)
        rig.box.reply = .success(ready)
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "разрешение есть: утилита слушает, 🌐 остаётся отключённой")
    }
    do {
        let rig = Rig("fn-handover-off", module: .keyboard, bundle: true)
        rig.box.reply = .success(waiting)
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "модуль был выключен: это настройки утилиты, не трогаем")
    }
    do {
        let rig = Rig("fn-handover-other", moduleOn: true, bundle: true)
        rig.box.reply = .success(waiting)
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "передача другого модуля: Fn не трогаем")
    }
}

/// Клавиатура включена, утилиты нет: поставить её не вышло, или модуль убрали. Слушать Fn некому, если 0 держим мы.
@MainActor func fnStrandedChecks() async {
    let kit = Kit.defaults
    /// 0 в системе поставил сам человек, не мы.
    func ownZero() {
        for key in ["Keyboard.SavedFnUsage", "Keyboard.KeepSystemFnOff", "Keyboard.SavedDictationEnabled", "Test.ApplyCount"] { kit.removeObject(forKey: key) }
        kit.set(0, forKey: "Test.FnUsage")
    }
    let keyboardCatalog = catalogData(id: "keyboard")

    do {
        let rig = Rig("fn-install-failed", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(keyboardCatalog)
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "утилиты нет, но ещё не пробовали: 🌐 пока не трогаем")
        try? await rig.registry.install(.keyboard, app: sampleApp("keyboard"))
        check(rig.journal.has("download"), "установка дошла до загрузки")
        check(FnSystemAction.usage == 1 && !FnSystemAction.keepsOff, "установка не удалась: 🌐 снова как была у человека")
        check(rig.modules.wantsUtility(.keyboard), "установка не удалась: модуль остаётся на странице «утилиты нет»")
        try? await rig.registry.install(.keyboard, app: sampleApp("keyboard"))
        await rig.registry.update()
        check(rig.journal.count("fn restore") == 1, "установка не удалась снова: возвращать уже нечего, один раз")
    }
    do {
        let rig = Rig("fn-install-failed-other", moduleOn: true)
        rig.box.catalog = .success(catalogData())
        holdFnOff()
        try? await rig.registry.install(.awake, app: sampleApp())
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "не удалась установка другого модуля: Fn не трогаем")
    }
    do {
        let rig = Rig("fn-migration-failed", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(keyboardCatalog)
        holdFnOff()
        rig.registry.startMigration()
        await rig.registry.migration?.value
        check(rig.journal.has("download"), "автопереход дошёл до загрузки")
        check(FnSystemAction.usage == 1, "автопереход не удался: 🌐 вернулась")
    }
    do {
        let rig = Rig("fn-update-failed", module: .keyboard, moduleOn: true, handedOver: true, bundle: true)
        rig.box.reply = .success(ready)
        rig.box.catalog = .success(keyboardCatalog)
        holdFnOff()
        await rig.registry.update()
        try? await rig.registry.install(.keyboard, app: sampleApp("keyboard"))
        check(rig.journal.has("download"), "обновление дошло до загрузки")
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "не удалось обновление: утилита на месте, 🌐 не трогаем")
    }
    do {
        let rig = Rig("fn-catalog-failed", module: .keyboard, moduleOn: true)
        holdFnOff()
        await rig.registry.update()
        check(rig.registry.catalogFailed, "каталог сорвался")
        check(FnSystemAction.usage == 1 && rig.journal.count("fn restore") == 1, "каталог сорвался, поставить нечем: 🌐 вернулась")
    }
    do {
        let rig = Rig("fn-catalog-no-entry", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(catalogData())
        holdFnOff()
        await rig.registry.update()
        check(!rig.registry.catalogFailed && FnSystemAction.usage == 1, "в каталоге нет утилиты: 🌐 вернулась")
    }
    do {
        let rig = Rig("fn-catalog-needs-hub", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(catalogData(id: "keyboard", minHub: "9.0.0"))
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 1, "утилите нужен центр новее: 🌐 вернулась")
    }
    do {
        // Отметка сбоя осталась с прошлого запуска, а до конца отступа новой попытки не будет.
        let rig = Rig("fn-backoff", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(keyboardCatalog)
        rig.defaults.set(1, forKey: ModuleMigration.failuresKey("keyboard"))
        holdFnOff()
        await rig.registry.update()
        check(FnSystemAction.usage == 1, "прошлая установка сорвалась, ждём отступ: 🌐 вернулась")
    }
    do {
        let rig = Rig("fn-own-zero", module: .keyboard, moduleOn: true)
        ownZero()
        await rig.registry.update()
        check(rig.registry.catalogFailed && !rig.journal.has("fn restore"), "0 держим не мы: каталог сорвался, Fn не трогаем")
        check(kit.object(forKey: "Keyboard.KeepSystemFnOff") == nil && FnSystemAction.usage == 0, "0 держим не мы: намерение и значение на месте")
    }
    do {
        let rig = Rig("fn-off-no-utility", module: .keyboard)
        holdFnOff()
        await rig.registry.update()
        check(rig.registry.catalogFailed && !rig.journal.has("fn restore"), "модуль выключен: опрос и сбой каталога Fn не трогают")
    }

    // Убрали через Стор или меню: туда идут `ModuleManager.setOn`.
    do {
        let rig = Rig("fn-drop", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(keyboardCatalog)
        await rig.registry.update()
        holdFnOff()
        rig.modules.setOn(.keyboard, false)
        check(FnSystemAction.usage == 1 && rig.journal.count("fn restore") == 1, "убрали модуль без утилиты: 🌐 вернулась")
        check(!rig.defaults.bool(forKey: ModuleManager.onKey(.keyboard)), "убрали модуль без утилиты: он выключен")
        rig.modules.setOn(.keyboard, false)
        check(rig.journal.count("fn restore") == 1, "повторное выключение ничего не делает")
    }
    do {
        let rig = Rig("fn-drop-own-zero", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(keyboardCatalog)
        await rig.registry.update()
        ownZero()
        rig.modules.setOn(.keyboard, false)
        check(!rig.journal.has("fn restore") && FnSystemAction.usage == 0, "убрали модуль, 0 держим не мы: Fn не трогаем")
    }
    do {
        let rig = Rig("fn-drop-external", module: .keyboard, moduleOn: true, handedOver: true, bundle: true)
        rig.box.reply = .success(ready)
        await rig.registry.update()
        holdFnOff()
        rig.modules.setOn(.keyboard, false)
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "модуль ведёт утилита: 🌐 у неё, не трогаем")
    }
    do {
        // Бандл уже есть, опроса ещё не было: утилита поставлена и слушает сама.
        let rig = Rig("fn-drop-bundle", module: .keyboard, moduleOn: true, bundle: true)
        holdFnOff()
        rig.modules.setOn(.keyboard, false)
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "бандл есть, передачи ещё не было: не трогаем")
    }
    do {
        let rig = Rig("fn-drop-other", moduleOn: true)
        await rig.registry.update()
        holdFnOff()
        rig.modules.setOn(.awake, false)
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "убрали другой модуль: Fn не трогаем")
    }
    do {
        // Идёт установка: может и встать. Сорвётся — вернёт ветка сбоя, хотя модуль уже выключен.
        let rig = Rig("fn-drop-busy", module: .keyboard, moduleOn: true)
        rig.box.catalog = .success(keyboardCatalog)
        rig.box.downloadDelay = 0.3
        await rig.registry.update()
        holdFnOff()
        let installing = Task { try? await rig.registry.install(.keyboard, app: sampleApp("keyboard")) }
        for _ in 0..<100 where !rig.registry.busy.contains(.keyboard) { try? await Task.sleep(for: .seconds(0.01)) }
        rig.modules.setOn(.keyboard, false)
        check(FnSystemAction.usage == 0 && !rig.journal.has("fn restore"), "убрали во время установки: пока ждём её")
        await installing.value
        check(FnSystemAction.usage == 1 && rig.journal.count("fn restore") == 1, "убрали во время установки, она сорвалась: 🌐 вернулась")
    }
}

// MARK: - Кнопка «Установить»

@MainActor func missingPageChecks() async {
    do {
        let rig = Rig("missing-button", moduleOn: true)
        rig.box.catalog = .success(catalogData())
        await rig.registry.update()
        // Отступ после сбоя и отметка «убрал сам» держат только автопереход.
        rig.defaults.set(true, forKey: ModuleMigration.removedKey("awake"))
        rig.defaults.set(Date().addingTimeInterval(9999).timeIntervalSince1970, forKey: ModuleMigration.retryAfterKey("awake"))
        rig.registry.installMissing(.awake)
        for _ in 0..<100 where rig.registry.installFailures[.awake] == nil { try? await Task.sleep(for: .seconds(0.02)) }
        check(rig.journal.count("download") == 1, "кнопка: установка пошла несмотря на отступ и отметку")
        check(rig.registry.installFailures[.awake] is Boom, "кнопка: причина сбоя видна странице")
        check(!rig.registry.busy.contains(.awake), "кнопка: после сбоя можно снова")
        check(rig.modules.wantsUtility(.awake), "кнопка: сбой оставляет модуль на странице «утилиты нет»")
        rig.box.downloadDelay = 0.3
        rig.registry.installMissing(.awake)
        for _ in 0..<100 where !rig.registry.busy.contains(.awake) { try? await Task.sleep(for: .seconds(0.01)) }
        check(rig.registry.installFailures[.awake] == nil, "кнопка: новая попытка снимает прежний сбой")
        for _ in 0..<100 where rig.registry.busy.contains(.awake) { try? await Task.sleep(for: .seconds(0.02)) }
        check(rig.journal.count("download") == 2, "кнопка: повтор дошёл до установщика")
    }
    do {
        let rig = Rig("missing-no-catalog", moduleOn: true)
        await rig.registry.update()
        rig.registry.installMissing(.awake)
        try? await Task.sleep(for: .seconds(0.05))
        check(!rig.journal.has("download") && rig.registry.catalogFailed, "кнопка без каталога: ставить нечего, каталог сорвался")
    }
}

Task { @MainActor in
    tableChecks()
    managerChecks()
    await pollChecks()
    await goneChecks()
    await fnChecks()
    await fnStrandedChecks()
    await missingPageChecks()
    await stallChecks()
    await serialChecks()
    await catalogChecks()
    await notificationChecks()
    UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
    print(failures == 0 ? "Все проверки прошли" : "Провалов: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
