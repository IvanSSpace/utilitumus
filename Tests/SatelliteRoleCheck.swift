import Foundation

// Проверка роли утилиты. Запуск: Tests/run-satellite-role-check.sh
// Без аргументов — чистая логика. С аргументами — клиент связи и замена бандла для Tests/run-awake-app-check.sh:
// один источник, подпись ставит скрипт.

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let waiting = SatelliteRole.Mode.passive(reason: "Ждём передачу от центра")
let outdated = SatelliteRole.Mode.passive(reason: "Модуль уже работает в Utilitumus — обновите центр")

func roleChecks() {
    func decide(_ launchd: Bool, _ running: Bool, _ version: String?, _ on: Bool, _ handed: Bool) -> SatelliteRole.Mode {
        SatelliteRole.decide(launchedByLaunchd: launchd, hubRunning: running, hubVersion: version, hubModuleOn: on, handedOver: handed)
    }
    let bools = [false, true]
    for running in bools { for version in [nil, "0.5.3", "0.6.0"] as [String?] { for on in bools { for handed in bools {
        check(decide(false, running, version, on, handed) == .forwardAndExit, "не launchd, центр \(running), \(version ?? "нет"), модуль \(on), передано \(handed) — forwardAndExit")
    } } } }
    for version in [nil, "0.5.3", "0.6.0"] as [String?] { for on in bools { for handed in bools {
        check(decide(true, false, version, on, handed) == .active, "центр не запущен, \(version ?? "нет"), модуль \(on), передано \(handed) — active")
    } } }
    for version in ["0.6.0", "0.6.1", "0.10.0", "1.0"] {
        for handed in bools {
            check(decide(true, true, version, false, handed) == .active, "центр \(version), модуль выключен, передано \(handed) — active")
        }
        check(decide(true, true, version, true, false) == waiting, "центр \(version), модуль включён, не передано — ждём")
        check(decide(true, true, version, true, true) == .active, "центр \(version), модуль включён, передано — active")
    }
    // Битая версия и версия с мусором считаются старше 0.6.0: «0.6.0abc» по числам была бы равна 0.6.0.
    for version in ["0.5.3", "0.5.99", "0.1", "abc", "", "1.x", "0.6.0abc", "v1.0"] {
        for handed in bools {
            check(decide(true, true, version, true, handed) == outdated, "центр «\(version)», модуль включён, передано \(handed) — обновите центр")
            check(decide(true, true, version, false, handed) == .active, "центр «\(version)», модуль выключен, передано \(handed) — active")
        }
    }
    check(decide(true, true, nil, true, true) == outdated, "центр без версии считается старым")
    check(decide(true, true, nil, false, false) == .active, "центр без версии, модуль выключен — active")
}

func releaseChecks() {
    let cases: [(SatelliteRole.Mode, Bool, String?, Bool, String)] = [
        (.active, true, nil, false, "центра нет, активна и включена — держать"),
        (.active, true, "0.6.0", false, "активна и включена — держать"),
        (waiting, true, "0.6.0", false, "центр запустился, ждём передачу — держать: кнопку встроенного ещё никто не нажал"),
        (waiting, false, "0.6.0", true, "ждём передачу, но выключена — снять"),
        (outdated, true, "0.5.3", true, "старый центр — снять"),
        (outdated, true, "abc", true, "центр с мусором вместо версии — снять, как старый"),
        (outdated, false, "0.5.3", true, "старый центр и выключена — снять"),
        (outdated, true, nil, false, "версию центра не прочитали — уже включённую держать"),
        (outdated, false, nil, true, "версию не прочитали, но выключена — снять"),
        (.active, false, "0.6.0", true, "активна, но выключена — снять"),
    ]
    for (mode, enabled, version, release, name) in cases {
        check(SatelliteRole.mustRelease(mode: mode, enabled: enabled, hubVersion: version) == release, "блокировка: " + name)
    }
    check(SatelliteRole.decide(launchedByLaunchd: true, hubRunning: true, hubVersion: nil, hubModuleOn: true, handedOver: false) == outdated,
          "версию не прочитали: при старте остаётся пассивной")
}

func keyChecks() {
    check(SatelliteEnabled.key("awake") == "App.awake.Enabled", "ключ включённости")
    check(SatelliteRole.handedOverKey("awake") == "App.awake.HandedOver", "ключ передачи")
    check(SatelliteRole.hubModuleOnKey("awake") == "ModuleOn.awake", "ключ модуля центра")
    check(SatelliteEnabled.key("test.awake") == "App.test.awake.Enabled", "ключ с точкой в id")
}

func enabledChecks() {
    let suite = "local.utilitumus.test.role"
    let defaults = UserDefaults(suiteName: suite)!
    func reset() { defaults.removePersistentDomain(forName: suite) }
    defer { reset() }

    reset()
    defaults.set(true, forKey: "ModuleOn.awake")
    defaults.set(true, forKey: "Modules.ResetForStore.v1")
    defaults.set(false, forKey: "ModuleOn.fans")
    defaults.set("dusk", forKey: "Design.Theme")
    defaults.set(3600, forKey: "AwakeDuration")
    check(SatelliteEnabled.load(id: "awake", defaults: defaults), "нет ключа, ModuleOn включён — true")
    check(defaults.object(forKey: "App.awake.Enabled") as? Bool == true, "значение записано в свой ключ")
    check(defaults.object(forKey: "Modules.ResetForStore.v1") as? Bool == true, "Modules.ResetForStore.v1 не тронут")
    check(defaults.object(forKey: "ModuleOn.awake") as? Bool == true, "ModuleOn.awake не тронут")
    check(defaults.object(forKey: "ModuleOn.fans") as? Bool == false, "чужой ModuleOn не тронут")
    check(defaults.string(forKey: "Design.Theme") == "dusk", "тема не тронута")
    check(defaults.integer(forKey: "AwakeDuration") == 3600, "настройка модуля не тронута")
    check(defaults.persistentDomain(forName: suite)?.count == 6, "новых ключей, кроме своего, нет")

    defaults.set(false, forKey: "ModuleOn.awake")
    check(SatelliteEnabled.load(id: "awake", defaults: defaults), "свой ключ есть — ModuleOn больше не смотрим")

    reset()
    defaults.set(false, forKey: "ModuleOn.awake")
    check(!SatelliteEnabled.load(id: "awake", defaults: defaults), "нет ключа, ModuleOn выключен — false")
    check(defaults.object(forKey: "App.awake.Enabled") as? Bool == false, "false тоже записан")

    reset()
    check(SatelliteEnabled.load(id: "awake", defaults: defaults), "нет ни ключа, ни ModuleOn: поставили отдельно — true")
    check(defaults.object(forKey: "App.awake.Enabled") as? Bool == true, "и записан")
    defaults.set(true, forKey: "ModuleOn.awake")
    defaults.set(false, forKey: "App.awake.Enabled")
    check(!SatelliteEnabled.load(id: "awake", defaults: defaults), "записанный при первом запуске ключ дальше решает сам")

    reset()
    defaults.set(true, forKey: "ModuleOn.awake")
    defaults.set(false, forKey: "App.awake.Enabled")
    check(!SatelliteEnabled.load(id: "awake", defaults: defaults), "свой false важнее включённого ModuleOn")
}

func requirementChecks() {
    let both = KitLink.requirement(identifiers: ["hub", "self"], hashes: ["aa"])
    let marker = #"info["UtilitumusSecurityEpoch"] = "1""#
    check(both == "(identifier \"hub\" and certificate leaf = H\"aa\" and \(marker)) or (identifier \"self\" and certificate leaf = H\"aa\" and \(marker))", "требование: центр или свой identifier, оба с меткой")
    check(KitLink.requirement(identifiers: ["x"], hashes: ["aa"]) == KitLink.requirement(identifier: "x", hashes: ["aa"]), "один identifier — то же требование")
}

func updateChecks() {
    func app(_ id: String, _ version: String) -> CatalogApp {
        CatalogApp(id: id, version: version, minHub: "9.9.9", url: URL(string: "https://example.com/a.zip")!, sha256: "ab", sizeMB: 1)
    }
    let catalog = Catalog(schema: 1, apps: [app("other", "9.0.0"), app("awake", "1.2.0")])
    check(SatelliteSelfUpdate.newer(in: catalog, id: "awake", than: "1.1.9")?.version == "1.2.0", "обновление: новее — нашлось, minHub не мешает")
    check(SatelliteSelfUpdate.newer(in: catalog, id: "awake", than: "1.2.0") == nil, "обновление: та же версия — нет")
    check(SatelliteSelfUpdate.newer(in: catalog, id: "awake", than: "1.10.0") == nil, "обновление: своя новее — нет")
    check(SatelliteSelfUpdate.newer(in: catalog, id: "nope", than: "0") == nil, "обновление: чужой id — нет")
}

// MARK: - Клиент для стенда

/// Печатает каждое `statusChanged` утилиты: она объявляет о себе сама.
func watchStatus() -> Never {
    _ = DistributedNotificationCenter.default().addObserver(
        forName: KitLink.statusChanged("test.awake"), object: nil, queue: .main) { _ in
        print("statusChanged")
        fflush(stdout)
    }
    print("слушаю")
    fflush(stdout)
    RunLoop.main.run()
    exit(0)
}

/// Печатает результат; код выхода 0, только если вызов прошёл.
@MainActor func client(_ args: [String]) async -> Int32 {
    let link = LinkClient(id: "test.awake")
    do {
        switch args[0] {
        case "hello":
            let hello = try await link.hello()
            print("\(hello.id) \(hello.version) \(hello.protocolVersion)")
        case "status":
            let status = try await link.status()
            print("\(status.enabled)|\(status.line)|\(status.needsSetup)")
        case "enable": try await link.setEnabled(true)
        case "disable": try await link.setEnabled(false)
        case "open": try await link.openWindow()
        case "quit": try await link.quit()
        default:
            print("неизвестная команда: \(args[0])")
            return 2
        }
        return 0
    } catch {
        print("ошибка: \(error)")
        return 1
    }
}

/// `replace <zip> <sha256> <версия> <цель>`: как утилита обновляет себя.
@MainActor func replace(_ args: [String]) async -> Int32 {
    let app = CatalogApp(id: "test.awake", version: args[2], minHub: "0.6.0", url: URL(fileURLWithPath: args[0]), sha256: args[1], sizeMB: 1)
    do {
        try await SatelliteSelfUpdate.install(app, target: URL(fileURLWithPath: args[3]))
        return 0
    } catch {
        print("отказ: \(error.localizedDescription)")
        return 1
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    roleChecks()
    releaseChecks()
    keyChecks()
    enabledChecks()
    requirementChecks()
    updateChecks()
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
if args[0] == "watch" { watchStatus() }
Task { @MainActor in
    exit(args[0] == "replace" ? await replace(Array(args.dropFirst())) : await client(args))
}
dispatchMain()
