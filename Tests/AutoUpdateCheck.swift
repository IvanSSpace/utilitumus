import AppKit
import CryptoKit
import SwiftUI

// Автообновление. Запуск: Tests/run-auto-update-check.sh. Аргументы: архивы стенда, рабочая папка, папка PNG.
// Установщик, проверка хэша, подписи и метки выпуска настоящие; каталог, часы, launchctl и связь с утилитой подставные.

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let workRoot = URL(fileURLWithPath: CommandLine.arguments[2])
let pngDir = URL(fileURLWithPath: CommandLine.arguments[3])
nonisolated(unsafe) let fm = FileManager.default

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

/// Всё, что стенд подставляет и записывает. Потокобезопасно: установщик идёт вне главного потока.
final class Stage: @unchecked Sendable {
    private let lock = NSLock()
    private var _catalog = Data()
    private var _catalogFails = false
    private var _catalogReads = 0
    private var _states: [String: Data] = [:]
    private var _stateReads: [String: Int] = [:]
    private var _helloFails: Set<String> = []
    private var _offline: Set<String> = []
    private var _busyOnDownload: [String: Data] = [:]
    private var _down: Set<String> = []
    private var _downloads: [String] = []
    private var _quits: [String] = []
    private var _held: String?
    private var _heldQuit: String?
    private var _reached = false

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var catalog: Data { get { locked { _catalog } } set { locked { _catalog = newValue } } }
    var catalogFails: Bool { get { locked { _catalogFails } } set { locked { _catalogFails = newValue } } }
    var catalogReads: Int { locked { _catalogReads } }
    var helloFails: Set<String> { get { locked { _helloFails } } set { locked { _helloFails = newValue } } }
    var offline: Set<String> { get { locked { _offline } } set { locked { _offline = newValue } } }
    var downloads: [String] { locked { _downloads } }
    var quits: [String] { locked { _quits } }
    var reached: Bool { locked { _reached } }
    var down: Set<String> { locked { _down } }

    func readCatalog() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        _catalogReads += 1
        if _catalogFails { throw URLError(.notConnectedToInternet) }
        return _catalog
    }

    func setState(_ id: String, _ data: Data?) { locked { _states[id] = data } }
    func state(_ id: String) -> Data? { locked { _stateReads[id, default: 0] += 1; return _states[id] } }
    func stateReads(_ id: String) -> Int { locked { _stateReads[id, default: 0] } }
    func busyOnDownload(_ id: String, _ data: Data) { locked { _busyOnDownload[id] = data } }
    func hold(_ id: String?) { locked { _held = id; _reached = false } }
    func holdQuit(_ id: String?) { locked { _heldQuit = id; _reached = false } }
    func up(_ id: String) { _ = locked { _down.remove(id) } }

    func quit(_ id: String) async {
        locked { _quits.append(id); _down.insert(id) }
        while locked({ if _heldQuit == id { _reached = true; return true }; return false }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func reset() {
        locked {
            _catalogFails = false; _catalogReads = 0; _states = [:]; _stateReads = [:]; _helloFails = []; _offline = []
            _busyOnDownload = [:]; _down = []; _downloads = []; _quits = []; _held = nil; _heldQuit = nil; _reached = false
        }
    }

    func download(_ url: URL) async throws -> URL {
        let name = url.lastPathComponent
        let id = String(name.split(separator: "-")[0])
        locked { _downloads.append(id) }
        if locked({ _offline.contains(id) }) { throw URLError(.notConnectedToInternet) }
        locked { if let flip = _busyOnDownload.removeValue(forKey: id) { _states[id] = flip } }
        while locked({ if _held == id { _reached = true; return true }; return false }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let copy = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try fm.copyItem(at: fixtures.appendingPathComponent(name), to: copy)
        return copy
    }
}

/// Браузер: считает, что просили у LaunchServices.
final class LinkCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _register = 0
    private var _setDefault = 0
    var register: Int { lock.withLock { _register } }
    var setDefault: Int { lock.withLock { _setDefault } }
    func noteRegister() { lock.withLock { _register += 1 } }
    func noteSetDefault() { lock.withLock { _setDefault += 1 } }
}

let stage = Stage()
let linkCalls = LinkCalls()
let paths = SatellitePaths(appsDir: workRoot.appendingPathComponent("Apps"), agentsDir: workRoot.appendingPathComponent("Agents"))

func sha(_ file: String) -> String {
    let data = try! Data(contentsOf: fixtures.appendingPathComponent(file))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func entry(_ id: String, version: String = "2.0.0", file: String? = nil, minHub: String = "0.6.0", brokenSha: Bool = false, manual: Any? = nil) -> [String: Any] {
    let file = file ?? "\(id)-2.0.0"
    var result: [String: Any] = ["id": id, "version": version, "minHub": minHub, "url": "https://example.invalid/\(file).zip",
                                 "sha256": brokenSha ? "00" : sha(file + ".zip"), "sizeMB": 2, "notes": [String]()]
    if let manual { result["manualUpdate"] = manual }
    return result
}

func setCatalog(_ apps: [[String: Any]]) {
    stage.catalog = try! JSONSerialization.data(withJSONObject: ["schema": 1, "apps": apps])
}

func installedVersion(_ name: String) -> String? {
    NSDictionary(contentsOf: paths.appsDir.appendingPathComponent(name + ".app/Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
}

let awakeOn = LinkWire.encoded(AwakeState(isActive: true, endDate: nil, keepDisplay: false, duration: .forever, canStart: true))
let awakeOff = LinkWire.encoded(AwakeState(isActive: false, endDate: nil, keepDisplay: false, duration: .forever, canStart: true))

/// `NSApp.delegate` слабая ссылка, а `runAll` закончится раньше выхода.
@MainActor var quitDelegate: AppDelegate?
@MainActor var fakeNow = Date(timeIntervalSince1970: 2_000_000_000)

@MainActor func waitUntil(_ what: String, seconds: Double = 40, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { check(false, "дождаться: \(what)"); return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor func noticeHeight() -> CGFloat { NSHostingView(rootView: UpdateAllNotice()).fittingSize.height }

@MainActor func shoot(_ name: String, width: CGFloat, height: CGFloat, _ root: some View) async {
    let host = NSHostingView(rootView: root.environment(\.moduleControls, DSModuleControls.forEnvironment).dsThemed().frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    try? await Task.sleep(for: .seconds(0.35))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: pngDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    window.contentView = nil
}

// MARK: - Сценарии

@MainActor func runAll() async {
    let handler = BrowserLinkHandler(
        services: LinkLaunchServices(
            register: { _ in linkCalls.noteRegister() }, defaultHandlerID: { _ in nil }, copies: { _ in [] }, appURL: { _ in nil },
            setDefault: { _, _ in linkCalls.noteSetDefault() }, stopHelpers: { _ in }),
        defaults: Kit.defaults)
    let installer = SatelliteInstaller(
        paths: paths,
        launchctl: { args in if args.first == "bootstrap", let id = args.last.map({ URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }) {
            stage.up(id.replacingOccurrences(of: "local.utilitumus.app.", with: ""))
        } },
        download: { try await stage.download($0) },
        verify: SatelliteInstaller.liveVerify,
        link: SatelliteLink(quit: { id, _ in await stage.quit(id) }, hello: { id in
            if stage.helloFails.contains(id) { throw LinkError.timeout }
        }, helloWindow: 0.2),
        hooks: ["browser": .browser(handler)])

    SatelliteRegistry.standEnvironment = SatelliteEnvironment(
        paths: paths, defaults: Kit.defaults, installer: installer,
        commands: SatelliteCommands(
            status: { _ in LinkStatus(enabled: true, line: "Работает", needsSetup: 0) },
            setEnabled: { _, _ in }, openWindow: { _ in },
            moduleState: { id in
                guard let data = stage.state(id) else { throw LinkError.timeout }
                return data
            },
            refreshScreen: { _ in }),
        loadCatalog: { try stage.readCatalog() },
        hubVersion: "0.6.0", modules: .shared)

    let registry = SatelliteRegistry.shared
    let store = StoreModel.shared
    let updates = UpdateAll.shared
    let auto = AutoUpdate.shared
    auto.now = { fakeNow }
    let defaults = Kit.defaults

    /// Как после установки на чистый Mac: стоит 1.0.0, кроме `stash`, в настройках ничего, каталог читали.
    func fresh(_ apps: [[String: Any]]) async {
        stage.reset()
        try? fm.removeItem(at: paths.appsDir)
        try! fm.createDirectory(at: paths.appsDir, withIntermediateDirectories: true)
        for name in try! fm.contentsOfDirectory(atPath: fixtures.appendingPathComponent("v1").path) {
            try! fm.copyItem(at: fixtures.appendingPathComponent("v1/\(name)"), to: paths.appsDir.appendingPathComponent(name))
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("AutoUpdate.") { defaults.removeObject(forKey: key) }
        for module in Module.allCases { updates.forgetForStand(module) }
        auto.buildAllows = true
        setCatalog(apps)
        await registry.update()
        defaults.set(fakeNow, forKey: AutoUpdatePolicy.lastCheckKey)
    }

    /// Виток таймера и всё, что он запустил.
    func tick() async {
        await auto.tick()
        await waitUntil("конца прохода") { !updates.running }
    }

    func advance(_ seconds: TimeInterval) { fakeNow = fakeNow.addingTimeInterval(seconds) }

    func phase(_ module: Module) -> UpdateRow.Phase? { updates.rows.first { $0.module == module }?.phase }
    func noticeModules() -> [Module] { updates.noticeRows.map(\.module) }

    // MARK: Сборка
    check(AutoUpdate.isInstalledRelease == false, "сборка со швом сама не обновляет: настоящие утилиты вне опасности")
    check(auto.buildAllows == false, "и значение по умолчанию у стенда такое же")
    check(SatelliteRegistry.installsOnItsOwn, "обычная сборка без флага пилота ставит сама (с флагом: разбор в скрипте)")
    await fresh([entry("sound")])
    auto.buildAllows = false
    check(!auto.isOn && !auto.willHandle(.sound), "сборка не разрешает: выключено, что бы ни было в настройках")
    let readsBefore = stage.catalogReads
    advance(30 * 24 * 3600)
    auto.start()
    await tick()
    check(stage.catalogReads == readsBefore && stage.downloads.isEmpty, "сборка не разрешает: каталог не читается, ничего не качается")
    check(noticeModules() == [.sound], "и обновление остаётся на плашке")
    auto.buildAllows = true

    // MARK: Настройка
    await fresh([entry("sound")])
    check(defaults.object(forKey: AutoUpdatePolicy.enabledKey) == nil && auto.isOn, "ключа нет (кто уже пользуется): включено")
    defaults.set(false, forKey: AutoUpdatePolicy.enabledKey)
    check(!auto.isOn && noticeModules() == [.sound] && noticeHeight() > 0, "выключено: обновление на плашке, как раньше")
    advance(30 * 24 * 3600)
    let readsOff = stage.catalogReads
    await tick()
    check(stage.downloads.isEmpty && stage.catalogReads == readsOff && installedVersion("Sound") == "1.0.0", "выключено: ни чтения каталога, ни загрузки")
    defaults.set(true, forKey: AutoUpdatePolicy.enabledKey)
    await tick()
    check(installedVersion("Sound") == "2.0.0", "включили: обновилось")

    // MARK: Когда проверять
    await fresh([])
    let reads0 = stage.catalogReads
    for _ in 0..<11 { advance(AutoUpdatePolicy.tickInterval); await tick() }
    check(stage.catalogReads == reads0, "11 витков по 30 минут: каталог не читался")
    advance(AutoUpdatePolicy.tickInterval)
    await tick()
    check(stage.catalogReads == reads0 + 1, "через 6 часов: одно чтение (\(stage.catalogReads - reads0))")
    await tick()
    check(stage.catalogReads == reads0 + 1, "второй виток сразу: чтений не прибавилось")
    // Сон: таймер не ходил сутки, первый же виток сверяет часы.
    advance(24 * 3600)
    await tick()
    check(stage.catalogReads == reads0 + 2, "после сна на сутки первый виток читает каталог один раз")
    // Часы ушли назад.
    advance(-30 * 24 * 3600)
    await tick()
    check(stage.catalogReads == reads0 + 3, "часы ушли назад: проверка не замирает")
    check(AutoUpdatePolicy.isDue(lastCheck: nil, now: fakeNow), "первая проверка: пора")
    check(AutoUpdatePolicy.checkInterval == 6 * 3600 && AutoUpdatePolicy.tickInterval == 1800, "интервалы: 6 часов и 30 минут")

    // MARK: Что обновлять
    await fresh([entry("sound"), entry("mixer"),
                 entry("fans"), entry("clipboard"),
                 entry("stash"),
                 entry("load", minHub: "9.9.0"),
                 entry("mouse", version: "0.9.0"),
                 entry("keyboard", version: "1.0.0"),
                 entry("bots", manual: true),
                 entry("browser")])
    let windowsBefore = NSApp.windows.count
    await tick()
    check(Set(stage.downloads) == ["sound", "mixer", "browser"], "скачаны только подходящие: \(stage.downloads)")
    check(installedVersion("Sound") == "2.0.0" && installedVersion("Mixer") == "2.0.0" && installedVersion("Browser") == "2.0.0", "подходящие обновились")
    check(!fm.fileExists(atPath: paths.appsDir.appendingPathComponent("Stash.app").path) && !stage.downloads.contains("stash"), "не установленная не ставится")
    check(installedVersion("Load") == "1.0.0" && !stage.downloads.contains("load"), "нужен центр новее: не трогаем")
    check(installedVersion("Mouse") == "1.0.0" && !stage.downloads.contains("mouse"), "понижение: версия старше не качается и не ставится")
    check(installedVersion("Keyboard") == "1.0.0" && !stage.downloads.contains("keyboard"), "понижение: та же версия не качается")
    check(installedVersion("Fans") == "1.0.0" && !stage.downloads.contains("fans"), "вентиляторы только по кнопке: пароль службы")
    check(installedVersion("Clipboard") == "1.0.0" && !stage.downloads.contains("clipboard"), "буфер только по кнопке: окно связки")
    check(installedVersion("Bots") == "1.0.0" && !stage.downloads.contains("bots"), "отметка каталога: только по кнопке")
    check(Set(AutoUpdatePolicy.personOnly.map(\.rawValue)) == SatelliteCatalog.personOnly, "только по кнопке: в общем списке только настоящие модули")
    check(Set(noticeModules()).isSuperset(of: [.fans, .clipboard, .bots]) && noticeHeight() > 0, "только по кнопке: остались на плашке")
    check(updates.startable.contains(.fans) && updates.startable.contains(.clipboard), "и в «Обновить всё»")
    check(linkCalls.register == 1 && linkCalls.setDefault == 0, "браузер: регистрация есть, браузер по умолчанию не менялся (\(linkCalls.register), \(linkCalls.setDefault))")
    check(NSApp.windows.count == windowsBefore && !updates.listShown && store.failure == nil, "ни окна, ни листа, ни сообщения внизу Стора")
    if let line = auto.lastLine {
        check(line.contains("Звук 1.0.0 → 2.0.0") && line.contains("Микшер 1.0.0 → 2.0.0"), "строка итога: «\(line)»")
    } else { check(false, "нет строки итога") }
    // Клик: вентиляторы ставит та же очередь, служба и пароль в установке не участвуют.
    updates.start()
    await waitUntil("конца прохода по кнопке") { !updates.running }
    check(installedVersion("Fans") == "2.0.0" && installedVersion("Clipboard") == "2.0.0" && installedVersion("Bots") == "2.0.0", "по кнопке вентиляторы, буфер и отмеченный ставятся")
    await shoot("list", width: 520, height: 560, ZStack { DSBackground(module: .mixer, neutral: true); UpdateAllSheet() })
    await shoot("settings", width: 640, height: 500, SettingsView())

    // Кривая отметка каталога: значит «по кнопке».
    await fresh([entry("sound", manual: "да")])
    check(registry.catalogApp(.sound)?.manualUpdate == true && !auto.willHandle(.sound), "кривая отметка каталога считается отметкой")

    // MARK: Плашка не мигает
    await fresh([entry("sound")])
    check(noticeHeight() == 0, "каталог прочитан, до прохода: плашки нет")
    stage.hold("sound")
    await auto.tick()
    await waitUntil("скачивания звука") { stage.reached }
    check(updates.running && !updates.visiblyRunning && noticeHeight() == 0, "идёт проход: плашки нет")
    stage.hold(nil)
    var worst: CGFloat = 0
    while updates.running { worst = max(worst, noticeHeight()); try? await Task.sleep(for: .milliseconds(10)) }
    worst = max(worst, noticeHeight())
    check(worst == 0 && installedVersion("Sound") == "2.0.0", "до самого конца и после плашки не было (\(worst))")

    // MARK: Состояние не разобрать
    await fresh([entry("awake")])
    stage.setState("awake", Data(#"{"из будущей версии":true}"#.utf8))
    await tick()
    check(!stage.quits.contains("awake") && stage.downloads.isEmpty, "непонятное состояние: не скачана и не остановлена: \(stage.quits)")
    check(defaults.string(forKey: AutoUpdatePolicy.manualVersionKey("awake")) == "2.0.0" && noticeModules() == [.awake],
          "непонятное состояние: осталась на плашке для кнопки")
    check(defaults.object(forKey: AutoUpdatePolicy.failuresKey("awake")) == nil, "непонятное состояние не считается сбоем")

    // MARK: Занятые
    var botsBusy = BotsState.empty
    botsBusy.running = true
    var voiceBusy = VoiceController.storedState()
    voiceBusy.recording = true
    await fresh([entry("awake"), entry("bots"), entry("voice"), entry("sound")])
    stage.setState("awake", awakeOn)
    stage.setState("bots", LinkWire.encoded(botsBusy))
    stage.setState("voice", LinkWire.encoded(voiceBusy))
    await tick()
    check(!stage.quits.contains("awake") && !stage.quits.contains("bots") && !stage.quits.contains("voice"), "занятые не остановлены: \(stage.quits)")
    check(stage.downloads == ["sound"], "занятые пропущены, не скачаны, остальные обновились: \(stage.downloads)")
    check(phase(.awake) == .ready && noticeModules().isEmpty, "занятые не висят на плашке: обновятся сами")
    check(defaults.object(forKey: AutoUpdatePolicy.failuresKey("awake")) == nil, "занятость не считается сбоем")
    // Без опроса раз в 30 секунд, как у кнопки: один запрос за виток.
    let readsAwake = stage.stateReads("awake")
    try? await Task.sleep(for: .seconds(0.3))
    check(stage.stateReads("awake") == readsAwake, "между витками занятую не опрашивают")
    advance(AutoUpdatePolicy.tickInterval)
    await tick()
    check(!stage.quits.contains("awake") && installedVersion("Awake") == "1.0.0", "следующий виток: всё ещё занята, занятые не тронуты")
    stage.setState("awake", awakeOff)
    stage.setState("bots", LinkWire.encoded(BotsState.empty))
    stage.setState("voice", nil)
    // У архива голоса нет помощника, поставить его стенд не может; занятость проверена выше.
    defaults.set("2.0.0", forKey: AutoUpdatePolicy.manualVersionKey("voice"))
    advance(AutoUpdatePolicy.tickInterval)
    await tick()
    check(installedVersion("Awake") == "2.0.0" && installedVersion("Bots") == "2.0.0", "освободились: обновились на следующем витке")

    // Заняли себя, пока качалось: установщик спрашивает ещё раз.
    await fresh([entry("bots")])
    stage.setState("bots", LinkWire.encoded(BotsState.empty))
    stage.busyOnDownload("bots", LinkWire.encoded(botsBusy))
    await tick()
    check(!stage.quits.contains("bots") && installedVersion("Bots") == "1.0.0", "занялась во время скачивания: занятые не остановлены")
    check(noticeModules().isEmpty && defaults.object(forKey: AutoUpdatePolicy.failuresKey("bots")) == nil, "и это не сбой")
    stage.setState("bots", LinkWire.encoded(BotsState.empty))
    advance(AutoUpdatePolicy.tickInterval)
    await tick()
    check(installedVersion("Bots") == "2.0.0", "следующий виток обновил")

    // MARK: Подмена файла и версии
    func refused(_ what: String, _ apps: [[String: Any]], _ expected: String) async {
        await fresh(apps)
        await tick()
        check(installedVersion("Sound") == "1.0.0", "подмена (\(what)): не поставилось")
        check(stage.downloads == ["sound"] && stage.quits.isEmpty, "подмена (\(what)): скачано один раз, утилита не остановлена")
        if case .failed(let message)? = phase(.sound) {
            check(message.contains(expected), "подмена (\(what)): текст «\(message)»")
        } else { check(false, "подмена (\(what)): ждали сбой, \(String(describing: phase(.sound)))") }
    }
    await refused("хэш", [entry("sound", brokenSha: true)], "контрольная сумма")
    await refused("подпись", [entry("sound", file: "sound-adhoc-2.0.0")], "не от автора")
    await refused("метка выпуска", [entry("sound", file: "sound-noepoch-2.0.0")], "метки выпуска")
    await refused("версия в каталоге не та, что в файле", [entry("sound", version: "3.0.0")], "версия 2.0.0, в каталоге 3.0.0")

    // На диске новее, чем знает реестр: последняя проверка в установщике.
    await fresh([entry("sound")])
    try! fm.removeItem(at: paths.appsDir.appendingPathComponent("Sound.app"))
    try! fm.copyItem(at: fixtures.appendingPathComponent("x/Sound.app"), to: paths.appsDir.appendingPathComponent("Sound.app"))
    check(registry.hasUpdate(.sound), "реестр ещё думает, что стоит 1.0.0")
    await tick()
    check(installedVersion("Sound") == "3.0.0" && stage.quits.isEmpty, "понижение: файл 2.0.0 на установленную 3.0.0 не лёг")
    await waitUntil("опроса звука") { !registry.hasUpdate(.sound) }
    let downloadsDisk = stage.downloads.count
    advance(30 * 24 * 3600)
    await tick()
    check(stage.downloads.count == downloadsDisk, "и больше не качается")

    // MARK: Новое разрешение
    await fresh([entry("sound", file: "sound-mic-2.0.0"), entry("mixer", file: "mixer-ent-2.0.0")])
    await tick()
    check(installedVersion("Sound") == "1.0.0" && installedVersion("Mixer") == "1.0.0" && stage.quits.isEmpty, "новое разрешение: не поставилось, утилита не остановлена")
    check(Set(stage.downloads) == ["sound", "mixer"], "новое разрешение: посмотреть файл пришлось один раз")
    check(phase(.sound) == .ready && Set(noticeModules()) == [.sound, .mixer], "новое разрешение: на плашке, без «Не вышло» (\(noticeModules()))")
    let downloadsPerm = stage.downloads.count
    for _ in 0..<4 { advance(24 * 3600); await tick() }
    check(stage.downloads.count == downloadsPerm, "новое разрешение: повторно не качается (\(stage.downloads.count))")
    updates.start()
    await waitUntil("прохода по кнопке") { !updates.running }
    check(installedVersion("Sound") == "2.0.0" && installedVersion("Mixer") == "2.0.0", "новое разрешение: по кнопке ставится")

    // MARK: Сбой и пауза
    await fresh([entry("sound", brokenSha: true)])
    var attempts = 0
    for _ in 0..<48 {
        await tick()
        attempts = stage.downloads.count
        advance(AutoUpdatePolicy.tickInterval)
    }
    check(attempts == 4, "пауза: сутки витков, скачано \(attempts) раза (сразу, через 1 ч, 5 ч и 21 ч: паузы 1, 4 и 16 ч)")
    if case .failed? = phase(.sound) {
        check(noticeModules() == [.sound] && noticeHeight() > 0, "сбой виден на плашке, кнопка повторить есть")
    } else { check(false, "сбой: ждали строку") }
    // Исправленный выпуск не ждёт паузу сломанного.
    check(!auto.willHandle(.sound), "та же версия: пауза идёт")
    defaults.set("1.9.0", forKey: AutoUpdatePolicy.failedVersionKey("sound"))
    check(auto.willHandle(.sound), "другая версия: пауза не действует")
    // Утилита не ответила: откат и пауза.
    await fresh([entry("mouse")])
    stage.helloFails = ["mouse"]
    await tick()
    check(installedVersion("Mouse") == "1.0.0" && stage.down.isEmpty, "не ответила: прежняя версия на месте и запущена")
    check(defaults.integer(forKey: AutoUpdatePolicy.failuresKey("mouse")) == 1, "и пауза началась")
    let afterRollback = stage.downloads.count
    advance(1800)
    await tick()
    check(stage.downloads.count == afterRollback, "пауза: через 30 минут не качаем снова")
    advance(1900)
    stage.helloFails = []
    await tick()
    check(installedVersion("Mouse") == "2.0.0" && defaults.object(forKey: AutoUpdatePolicy.failuresKey("mouse")) == nil, "пауза кончилась: обновилось, счётчик сброшен")

    // MARK: Нет сети
    await fresh([entry("sound")])
    stage.catalogFails = true
    let last = defaults.object(forKey: AutoUpdatePolicy.lastCheckKey) as? Date
    advance(7 * 3600)
    await tick()
    check(registry.catalogFailed && stage.downloads.isEmpty, "нет сети: каталог не прочитан, ничего не качается")
    check((defaults.object(forKey: AutoUpdatePolicy.lastCheckKey) as? Date) == last, "срок не сдвинулся: следующий виток проверит снова")
    check(noticeHeight() == 0 && !updates.listShown, "тихо: ни плашки, ни окна")
    let offlineReads = stage.catalogReads
    await tick()
    check(stage.catalogReads == offlineReads + 1, "следующий виток пробует снова, один раз")
    stage.catalogFails = false
    await tick()
    check(installedVersion("Sound") == "2.0.0", "сеть вернулась: обновилось само")
    // Сеть пропала посреди скачивания.
    await fresh([entry("mouse")])
    stage.offline = ["mouse"]
    await tick()
    check(phase(.mouse) == .ready && noticeModules().isEmpty && defaults.object(forKey: AutoUpdatePolicy.failuresKey("mouse")) == nil, "пропала посреди скачивания: тихо, без паузы и без строки")
    stage.offline = []
    advance(AutoUpdatePolicy.tickInterval)
    await tick()
    check(installedVersion("Mouse") == "2.0.0", "следующий виток обновил")

    // MARK: Выход посреди очереди
    // Прямой вызов: идёт скачивание, в очереди есть ещё. Порядок очереди по `Module.allCases`, держим первого.
    await fresh([entry("sound"), entry("mixer")])
    let first = Module.allCases.first { $0 == .sound || $0 == .mixer }!
    stage.hold(first.rawValue)
    await auto.tick()
    await waitUntil("скачивания") { stage.reached }
    check(updates.installing, "установка идёт: выход должен подождать")
    var replied = false
    updates.stopForQuit { replied = true }
    await waitUntil("ответа на выход") { replied }
    check(!updates.running && stage.quits.isEmpty && stage.down.isEmpty, "выход во время скачивания: очередь снята, никого не остановили")
    check(installedVersion("Mixer") == "1.0.0" && installedVersion("Sound") == "1.0.0", "выход во время скачивания: ничего не заменено")

    // Настоящий выход через делегат: утилита уже остановлена, а новая ещё не запущена.
    await fresh([entry("sound")])
    stage.holdQuit("sound")
    await auto.tick()
    await waitUntil("остановки утилиты") { stage.reached }
    check(stage.down == ["sound"], "утилита остановлена, очередь в опасном месте")
    quitDelegate = AppDelegate()
    NSApp.delegate = quitDelegate
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        check(stage.down.isEmpty, "выход: утилита снова запущена, а не осталась остановленной")
        check(installedVersion("Sound") != nil, "выход: бандл на месте (\(installedVersion("Sound") ?? "нет"))")
        print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { stage.holdQuit(nil) }
    // Из таймера, как событие меню, а не из блока главной очереди: иначе задачи главного актора стояли бы до конца выхода.
    Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
        NSApp.terminate(nil)
        // `terminate` не возвращается: `terminateLater` крутит цикл до ответа, затем выход.
        check(false, "выход: `terminate` вернулся")
        exit(1)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
try! fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
UserDefaults.standard.set(true, forKey: ModuleReset.flagKey)
Task { @MainActor in await runAll() }
app.run()
