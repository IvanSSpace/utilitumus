import CryptoKit
import Foundation

// Обработчик ссылок «Браузера»: ключи включённости, выбор копии помощника, установка, обновление и удаление утилиты.
// Запуск: Tests/run-browser-link-handler-check.sh. LaunchServices подставной, настоящий local.utilitumus.links, http и
// https не регистрируются, не снимаются и не назначаются. Подпись не нужна: проверка подписи в установщике подставная.

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let fm = FileManager.default
let work = URL(fileURLWithPath: CommandLine.arguments[1])
let linksID = "local.utilitumus.links"
let helperName = "Utilitumus Links.app"

// MARK: - Настройки

let suite = "local.utilitumus.test.browserlink"
func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

// MARK: - Подставной LaunchServices

final class FakeLS: @unchecked Sendable {
    var handlers: [String: String] = [:]
    var copies: [URL] = []
    var apps: [String: URL] = [:]
    var registered: [URL] = []
    var setCalls: [(url: URL, scheme: String)] = []
    var stopped: [URL] = []
    /// Диалог отклонён: `setDefault` бросает ошибку.
    var refuses = false
    /// Диалог закрыт без выбора: успех без изменений.
    var ignores = false

    struct Declined: Error {}

    var services: LinkLaunchServices {
        LinkLaunchServices(
            register: { [self] in registered.append($0) },
            defaultHandlerID: { [self] in handlers[$0] },
            copies: { [self] in $0 == linksID ? copies : [] },
            appURL: { [self] in apps[$0] },
            setDefault: { [self] url, scheme in
                setCalls.append((url, scheme))
                if refuses { throw Declined() }
                if ignores { return }
                handlers[scheme] = apps.first { $0.value == url }?.key
            },
            stopHelpers: { [self] in stopped.append($0) })
    }

    var ours: FakeLS {
        handlers = ["http": linksID, "https": linksID]
        return self
    }
}

func handler(_ ls: FakeLS, _ defaults: UserDefaults) -> BrowserLinkHandler {
    var h = BrowserLinkHandler(services: ls.services, defaults: defaults)
    h.settleAttempts = 2
    h.settleDelay = .milliseconds(1)
    // Папка проверки может лежать под /private/tmp, а настоящая копия там обработчиком не считалась бы.
    h.ignoredPrefixes = []
    return h
}

let chrome = URL(fileURLWithPath: "/Applications/Fake/Chrome.app")
let safari = URL(fileURLWithPath: "/Applications/Fake/Safari.app")
let hubCopy = URL(fileURLWithPath: "/Applications/Fake/Utilitumus.app/Contents/Helpers/\(helperName)")

// MARK: - Ключи и включённость

func keyChecks() {
    check(BrowserHelper.moduleOnKey == SatelliteRole.hubModuleOnKey("browser"), "ключ ModuleOn совпадает с утилитой")
    check(BrowserHelper.handedOverKey == ModuleHandover.handedOverKey("browser"), "ключ передачи совпадает с центром")
    check(BrowserHelper.handedOverKey == SatelliteRole.handedOverKey("browser"), "ключ передачи совпадает с утилитой")
    check(BrowserHelper.enabledKey == ModuleHandover.enabledKey("browser"), "ключ включённости совпадает с центром")
    check(BrowserHelper.enabledKey == SatelliteEnabled.key("browser"), "ключ включённости совпадает с утилитой")
    check(BrowserHelper.fallbackKey == "Browser.Fallback", "ключ основного браузера")
}

func disabledChecks() {
    func disabled(_ set: (UserDefaults) -> Void) -> Bool {
        let d = freshDefaults()
        set(d)
        return BrowserHelper.moduleDisabled(in: d)
    }
    check(disabled { _ in }, "ничего не записано: выключен")
    check(!disabled { $0.set(true, forKey: "ModuleOn.browser") }, "центр: тумблер включён")
    check(disabled { $0.set(false, forKey: "ModuleOn.browser") }, "центр: тумблер выключен")
    // Раньше помощник смотрел только в ModuleOn и после «＋» считал модуль выключенным.
    check(!disabled { $0.set(true, forKey: "App.browser.HandedOver"); $0.set(true, forKey: "App.browser.Enabled") }, "передан утилите: её выключатель включён, ModuleOn не записан")
    check(disabled { $0.set(true, forKey: "App.browser.HandedOver"); $0.set(false, forKey: "App.browser.Enabled"); $0.set(true, forKey: "ModuleOn.browser") }, "передан утилите: её выключатель главнее ModuleOn")
    check(!disabled { $0.set(true, forKey: "App.browser.HandedOver"); $0.set(true, forKey: "App.browser.Enabled"); $0.set(false, forKey: "ModuleOn.browser") }, "передан утилите: ModuleOn=false не выключает")
    check(!disabled { $0.set(true, forKey: "App.browser.HandedOver"); $0.set(true, forKey: "ModuleOn.browser") }, "передан, ключа утилиты ещё нет: берётся у центра")
    check(disabled { $0.set(true, forKey: "App.browser.HandedOver"); $0.set(false, forKey: "ModuleOn.browser") }, "передан, ключа утилиты нет, центр выключен: выключен")
    check(!disabled { $0.set(true, forKey: "App.browser.HandedOver") }, "передан, ничего больше нет: включён, как у утилиты")
    check(!disabled { $0.set(true, forKey: "App.browser.Enabled") }, "утилита отдельно, без центра: её выключатель")
    check(disabled { $0.set(false, forKey: "App.browser.Enabled") }, "утилита отдельно, выключена")
    check(disabled { $0.set(true, forKey: "App.browser.Enabled"); $0.set(false, forKey: "ModuleOn.browser") }, "не передан: тумблер центра главнее залежавшегося ключа утилиты")
    // Утилиту удалили: центр снимает передачу, и тумблер снова читает общий ключ.
    check(disabled { $0.set(false, forKey: "ModuleOn.browser"); $0.removeObject(forKey: "App.browser.HandedOver"); $0.set(true, forKey: "App.browser.Enabled") }, "после удаления утилиты тумблер центра главный")
}

// MARK: - Копия помощника

func copyChecks() {
    let hub = URL(fileURLWithPath: "/Applications/Fake/Utilitumus.app")
    let utilities = URL(fileURLWithPath: "/Applications/Fake/Utilitumus")
    let utilityCopy = utilities.appendingPathComponent("Browser.app/Contents/Helpers/\(helperName)")
    let hubOwn = hub.appendingPathComponent("Contents/Helpers/\(helperName)")
    let helperSelf = URL(fileURLWithPath: "/Applications/Fake/Elsewhere/\(helperName)")

    let both: (URL) -> Bool = { $0 == utilityCopy || $0 == hubOwn }
    check(BrowserHelper.appURL(mainBundleURL: helperSelf, mainBundleID: linksID, utilitiesDir: utilities, exists: both) == helperSelf, "сам помощник: он сам")
    check(BrowserHelper.appURL(mainBundleURL: hub, mainBundleID: "local.utilitumus", utilitiesDir: utilities, exists: both) == utilityCopy, "центр при утилите: копия утилиты")
    check(BrowserHelper.appURL(mainBundleURL: utilities.appendingPathComponent("Browser.app"), mainBundleID: "local.utilitumus.app.browser", utilitiesDir: utilities, exists: both) == utilityCopy, "утилита: та же копия, что у центра")
    check(BrowserHelper.appURL(mainBundleURL: hub, mainBundleID: "local.utilitumus", utilitiesDir: utilities, exists: { $0 == hubOwn }) == hubOwn, "центр без утилиты: копия внутри центра")
    check(BrowserHelper.appURL(mainBundleURL: hub, mainBundleID: "local.utilitumus", utilitiesDir: utilities, exists: { _ in false }) == hubOwn, "ничего нет: путь внутри центра, как было")
    check(BrowserHelper.knownCopies(mainBundleURL: hub, mainBundleID: "local.utilitumus", utilitiesDir: utilities, exists: both) == [utilityCopy, hubOwn], "регистрируются обе копии")
    check(BrowserHelper.knownCopies(mainBundleURL: hub, mainBundleID: "local.utilitumus", utilitiesDir: utilities, exists: { $0 == hubOwn }) == [hubOwn], "регистрируется только существующая")
    check(BrowserHelper.knownCopies(mainBundleURL: helperSelf, mainBundleID: linksID, utilitiesDir: utilities, exists: both) == [helperSelf], "сам помощник регистрирует себя")
}

// MARK: - Обработчик

func markerChecks() {
    let d = freshDefaults()
    let ls = FakeLS()
    let h = handler(ls, d)
    ls.copies = [hubCopy]
    ls.handlers = ["https": linksID]
    h.noteDefault()
    check(d.bool(forKey: BrowserLinkHandler.markerKey), "метка ставится, когда обработчик наш")
    check(h.isDefault, "isDefault: наш")
    ls.handlers = [:]
    h.noteDefault()
    check(!d.bool(forKey: BrowserLinkHandler.markerKey), "метка снимается: обработчика нет, копии есть")
    ls.handlers = ["https": linksID]
    h.noteDefault()
    ls.handlers = [:]
    ls.copies = []
    h.noteDefault()
    check(d.bool(forKey: BrowserLinkHandler.markerKey), "метка остаётся: обработчик не читается и копий совсем нет")
    ls.handlers = ["https": "com.google.Chrome"]
    h.noteDefault()
    check(!d.bool(forKey: BrowserLinkHandler.markerKey), "метка снимается: обработчик другой")
    check(ls.setCalls.isEmpty && ls.registered.isEmpty, "метка ничего не назначает и не регистрирует")
}

func releaseChecks() async {
    let bundle = URL(fileURLWithPath: "/Applications/Fake/Utilitumus/Browser.app")
    let inner = bundle.appendingPathComponent("Contents/Helpers/\(helperName)")
    // Копии, которых нет на диске, в «другие» не попадают: берём настоящие пустые папки.
    let realHub = work.appendingPathComponent("hub/Utilitumus.app/Contents/Helpers/\(helperName)")
    try? fm.createDirectory(at: realHub, withIntermediateDirectories: true)

    // Наш обработчик, других копий нет, основной браузер известен.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.apps = ["com.google.Chrome": chrome, "com.apple.Safari": safari]
        ls.copies = [inner]
        d.set("com.google.Chrome", forKey: "Browser.Fallback")
        d.set(true, forKey: BrowserLinkHandler.markerKey)
        do {
            try await handler(ls, d).release(removing: bundle)
            check(ls.setCalls.map(\.scheme) == ["http", "https"] && ls.setCalls.allSatisfy { $0.url == chrome }, "возврат: оба протокола основному браузеру")
            check(ls.handlers == ["http": "com.google.Chrome", "https": "com.google.Chrome"], "возврат: обработчик правда сменился")
            check(!d.bool(forKey: BrowserLinkHandler.markerKey), "возврат: метка снята")
        } catch { check(false, "возврат не должен бросать: \(error)") }
    }
    // Основного нет — Safari.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.apps = ["com.apple.Safari": safari]
        ls.copies = [inner]
        try? await handler(ls, d).release(removing: bundle)
        check(ls.setCalls.count == 2 && ls.setCalls.allSatisfy { $0.url == safari }, "нет основного: Safari")
    }
    // Основной — не браузер из списка: не доверяем общим настройкам.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        let evil = URL(fileURLWithPath: "/Applications/Fake/Evil.app")
        ls.apps = ["com.evil.app": evil, "com.apple.Safari": safari]
        ls.copies = [inner]
        d.set("com.evil.app", forKey: "Browser.Fallback")
        try? await handler(ls, d).release(removing: bundle)
        check(ls.setCalls.allSatisfy { $0.url == safari } && ls.setCalls.count == 2, "основной не из списка браузеров: Safari")
    }
    // Основной — сам помощник: не отдаём ссылки себе.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.apps = [linksID: inner, "com.apple.Safari": safari]
        ls.copies = [inner]
        d.set(linksID, forKey: "Browser.Fallback")
        try? await handler(ls, d).release(removing: bundle)
        check(ls.setCalls.allSatisfy { $0.url == safari } && ls.setCalls.count == 2, "основной — помощник: Safari")
    }
    // Вернуть некому.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.copies = [inner]
        do {
            try await handler(ls, d).release(removing: bundle)
            check(false, "без браузера должна быть ошибка")
        } catch {
            check(error as? BrowserLinkError == .noBrowserToReturn, "нет ни основного, ни Safari: отказ")
        }
        check(ls.setCalls.isEmpty, "нет браузера: ничего не назначалось")
    }
    // Человек отказал в диалоге.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.apps = ["com.apple.Safari": safari]
        ls.copies = [inner]
        ls.refuses = true
        do {
            try await handler(ls, d).release(removing: bundle)
            check(false, "отказ должен бросить")
        } catch {
            if case .declined? = error as? BrowserLinkError { check(true, "отказ в диалоге: ошибка declined") } else { check(false, "ждали declined: \(error)") }
        }
        check(ls.handlers == ["http": linksID, "https": linksID], "отказ: обработчик прежний")
    }
    // Диалог закрыт без выбора: успех без изменений.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.apps = ["com.apple.Safari": safari]
        ls.copies = [inner]
        ls.ignores = true
        do {
            try await handler(ls, d).release(removing: bundle)
            check(false, "тихий отказ должен бросить")
        } catch {
            if case .declined? = error as? BrowserLinkError { check(true, "успех без изменений: всё равно отказ") } else { check(false, "ждали declined: \(error)") }
        }
    }
    // Другая копия есть.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.apps = ["com.apple.Safari": safari]
        ls.copies = [inner, realHub]
        try? await handler(ls, d).release(removing: bundle)
        check(ls.setCalls.isEmpty, "другая копия жива (центр): браузер не возвращается")
    }
    // «Другая» копия в Корзине, во временной папке или внутри удаляемого бандла не считается.
    do {
        let d = freshDefaults(), ls = FakeLS().ours
        ls.apps = ["com.apple.Safari": safari]
        let trash = work.appendingPathComponent(".Trash/Utilitumus.app/Contents/Helpers/\(helperName)")
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let temp = work.appendingPathComponent("temp-copy/\(helperName)")
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        ls.copies = [inner, trash, temp]
        var h = handler(ls, d)
        h.ignoredPrefixes = [work.appendingPathComponent("temp-copy").path + "/"]
        try? await h.release(removing: bundle)
        check(ls.setCalls.count == 2, "копия в Корзине и во временной папке копией не считается")
    }
    // Не наш обработчик: нечего возвращать.
    do {
        let d = freshDefaults(), ls = FakeLS()
        ls.handlers = ["http": "com.google.Chrome", "https": "com.google.Chrome"]
        ls.apps = ["com.apple.Safari": safari]
        try? await handler(ls, d).release(removing: bundle)
        check(ls.setCalls.isEmpty, "обработчик чужой: ничего не меняется")
    }
    // Сирота: утилиту убрали мимо центра.
    do {
        let d = freshDefaults(), ls = FakeLS()
        ls.apps = ["com.apple.Safari": safari]
        let h = handler(ls, d)
        check(h.orphanOffer() == nil, "сирота: метки нет, предлагать нечего")
        d.set(true, forKey: BrowserLinkHandler.markerKey)
        check(h.orphanOffer()?.id == "com.apple.Safari", "сирота: метка, копий и обработчика нет — предложить Safari")
        ls.copies = [hubCopy]
        check(h.orphanOffer() == nil, "сирота: копия есть — не предлагать")
        ls.copies = []
        ls.handlers = ["https": "com.google.Chrome"]
        check(h.orphanOffer() == nil, "сирота: обработчик назначен — не предлагать")
        ls.handlers = [:]
        do {
            try await h.restoreOrphaned()
            check(ls.handlers == ["http": "com.apple.Safari", "https": "com.apple.Safari"], "сирота: браузер возвращён по обоим протоколам")
            check(!d.bool(forKey: BrowserLinkHandler.markerKey), "сирота: метка снята")
        } catch { check(false, "сирота: \(error)") }
    }
}

// MARK: - Установщик

func makeArchive(version: String) -> (zip: URL, sha: String) {
    let staging = work.appendingPathComponent("staging-\(version)")
    try? fm.removeItem(at: staging)
    let app = staging.appendingPathComponent("Browser.app")
    let helper = app.appendingPathComponent("Contents/Helpers/\(helperName)")
    try! fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "local.utilitumus.app.browser", "CFBundleExecutable": "Browser", "CFBundleShortVersionString": version]
    (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    for exe in [app.appendingPathComponent("Contents/MacOS/Browser"), helper.appendingPathComponent("Contents/MacOS/UtilitumusLinks")] {
        try! "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }
    let zip = work.appendingPathComponent("Browser-\(version).zip")
    try? fm.removeItem(at: zip)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
    try! p.run()
    p.waitUntilExit()
    let sha = SHA256.hash(data: try! Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
    return (zip, sha)
}

func installerChecks() async {
    let ls = FakeLS()
    let d = freshDefaults()
    let h = handler(ls, d)
    ls.apps = ["com.apple.Safari": safari]
    let root = work.appendingPathComponent("installer")
    try? fm.removeItem(at: root)
    let paths = SatellitePaths(appsDir: root.appendingPathComponent("apps"), agentsDir: root.appendingPathComponent("agents"))
    var quits: [String] = []
    var order: [String] = []
    let installer = SatelliteInstaller(
        paths: paths, launchctl: { _ in }, download: { $0 }, verify: { _, _ in },
        link: SatelliteLink(quit: { _, reason in quits.append("\(reason)"); order.append("quit") }, hello: { _ in }, helloWindow: 1),
        hooks: ["browser": .browser(h)])
    func app(_ a: (zip: URL, sha: String), _ v: String) -> CatalogApp {
        CatalogApp(id: "browser", version: v, minHub: "0.6.0", url: a.zip, sha256: a.sha, sizeMB: 1)
    }
    let bundle = paths.appsDir.appendingPathComponent("Browser.app")
    let helper = bundle.appendingPathComponent("Contents/Helpers/\(helperName)")

    let v1 = makeArchive(version: "1.0.0")
    do {
        try await installer.install(app(v1, "1.0.0"), name: "Browser")
        check(ls.registered.map(\.path) == [helper.path], "установка: помощник зарегистрирован, больше ничего")
        check(ls.setCalls.isEmpty && ls.handlers.isEmpty, "установка: обработчик не назначался")
        check(ls.stopped.isEmpty, "первая установка: останавливать нечего")
    } catch { check(false, "установка: \(error)") }

    let v2 = makeArchive(version: "1.1.0")
    do {
        ls.registered = []
        ls.handlers = ["http": linksID, "https": linksID]
        try await installer.install(app(v2, "1.1.0"), name: "Browser")
        check(ls.stopped.map(\.path) == [bundle.path], "обновление: запущенный помощник остановлен")
        check(ls.registered.map(\.path) == [helper.path], "обновление: помощник зарегистрирован заново")
        check(ls.setCalls.isEmpty && ls.handlers == ["http": linksID, "https": linksID], "обновление: браузер не возвращается, обработчик на месте")
        check(quits == ["update"], "обновление: quit(update)")
    } catch { check(false, "обновление: \(error)") }

    // Удаление: человек отказал — всё на месте.
    ls.refuses = true
    ls.copies = [helper]
    quits = []
    do {
        try await installer.remove(id: "browser", name: "Browser")
        check(false, "отказ должен остановить удаление")
    } catch {
        check(fm.fileExists(atPath: bundle.path), "отказ: бандл утилиты на месте")
        check(quits.isEmpty, "отказ: утилита не останавливалась")
        check(ls.handlers == ["http": linksID, "https": linksID], "отказ: обработчик прежний")
    }
    // Удаление: браузер вернулся, потом бандл удалён.
    ls.refuses = false
    ls.setCalls = []
    ls.stopped = []
    do {
        try await installer.remove(id: "browser", name: "Browser")
        check(!fm.fileExists(atPath: bundle.path), "удаление: бандл убран")
        check(ls.setCalls.count == 2 && ls.handlers["https"] == "com.apple.Safari", "удаление: Safari стал обработчиком до удаления")
        check(quits == ["uninstall"] && ls.stopped.map(\.path) == [bundle.path], "удаление: quit(uninstall) и остановка помощника")
    } catch { check(false, "удаление: \(error)") }

    // Остальные утилиты LaunchServices не трогают.
    let before = ls.setCalls.count + ls.registered.count + ls.stopped.count
    let other = SatelliteInstaller(paths: paths, launchctl: { _ in }, download: { $0 }, verify: { _, _ in },
                                   link: SatelliteLink(quit: { _, _ in }, hello: { _ in }, helloWindow: 1))
    try? await other.remove(id: "awake", name: "Awake")
    check(ls.setCalls.count + ls.registered.count + ls.stopped.count == before, "другая утилита и установщик без хуков: LaunchServices не тронут")
}

// MARK: - Утилита

@MainActor func moduleChecks() async {
    let d = freshDefaults(), ls = FakeLS()
    ls.apps = ["com.apple.Safari": safari]
    let copy = URL(fileURLWithPath: "/Applications/Fake/Utilitumus/Browser.app/Contents/Helpers/\(helperName)")
    let module = BrowserModule(handler: handler(ls, d), copies: { [copy] })

    check(ls.registered.isEmpty, "init ничего не регистрирует")
    module.start()
    check(ls.registered == [copy], "start: регистрирует копию")
    check(ls.setCalls.isEmpty, "start: обработчик не назначает")
    check(module.statusLine(passiveReason: nil) == "Не браузер по умолчанию", "статус: не по умолчанию")
    check(module.statusLine(passiveReason: "Ждём") == "Ждём", "статус: причина пассивности")
    check(module.setupSteps.count == 1 && module.setupSteps[0].required && !module.setupSteps[0].done, "шаг: обязательный, не сделан")
    ls.handlers = ["https": linksID]
    check(module.setupSteps[0].done && module.statusLine(passiveReason: nil) == "Ссылки открывает Utilitumus", "шаг и статус: обработчик наш")
    ls.handlers = [:]
    check(module.performSetupStep("browser.default") == nil, "шаг по кнопке принят")
    for _ in 0..<50 where ls.setCalls.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
    check(ls.setCalls.map(\.scheme) == ["http", "https"] && ls.setCalls.allSatisfy { $0.url == copy }, "шаг: назначает копию утилиты на оба протокола")
    check(BrowserModule(handler: handler(FakeLS(), d), copies: { [] }).performSetupStep("browser.default") == "Помощник ссылок не найден", "шаг без копии: текст ошибки")

    check(module.state() == Data("{}".utf8), "состояние пустое")
    for bad in [#"{"toggle":{}}"#, #"{}"#, #"{"a":{},"b":{}}"#, "мусор", #"{"x":{"y":1}}"#] {
        let reply = String(decoding: module.handle(Data(bad.utf8)), as: UTF8.self)
        check(reply.contains("Непонятная команда"), "действие отвергнуто: \(bad)")
    }
    module.stop()
    check(ls.setCalls.count == 2, "stop ничего не меняет в системе")
}

// MARK: - Запуск

keyChecks()
disabledChecks()
copyChecks()
markerChecks()
await releaseChecks()
await installerChecks()
await moduleChecks()
UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
print(failures == 0 ? "ВСЁ ПРОШЛО" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
