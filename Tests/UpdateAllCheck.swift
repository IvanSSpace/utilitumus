import AppKit
import CryptoKit
import SwiftUI

// «Обновить всё». Запуск: Tests/run-update-all-check.sh. Аргументы: архивы стенда, рабочая папка, папка PNG.
// Установщик настоящий, подпись настоящая; launchctl и связь с утилитой подставные.

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let workRoot = URL(fileURLWithPath: CommandLine.arguments[2])
let pngDir = URL(fileURLWithPath: CommandLine.arguments[3])
nonisolated(unsafe) let fm = FileManager.default

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

struct Boom: Error {}

/// Всё, что стенд подставляет и записывает. Потокобезопасно: установщик идёт вне главного потока.
final class Stage: @unchecked Sendable {
    private let lock = NSLock()
    private var _catalog = Data()
    private var _catalogFails = false
    private var _states: [String: Data] = [:]
    private var _helloFails: Set<String> = []
    private var _offline: Set<String> = []
    private var _busyOnDownload: [String: Data] = [:]
    private var _down: Set<String> = []
    private var _downloads: [String] = []
    private var _quits: [String] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _held: String?
    private var _reached = false

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var catalog: Data { get { locked { _catalog } } set { locked { _catalog = newValue } } }
    var catalogFails: Bool { get { locked { _catalogFails } } set { locked { _catalogFails = newValue } } }
    var helloFails: Set<String> { get { locked { _helloFails } } set { locked { _helloFails = newValue } } }
    var offline: Set<String> { get { locked { _offline } } set { locked { _offline = newValue } } }
    var downloads: [String] { locked { _downloads } }
    var quits: [String] { locked { _quits } }
    var maxInFlight: Int { locked { _maxInFlight } }
    var reached: Bool { locked { _reached } }
    var down: Set<String> { locked { _down } }

    func setState(_ id: String, _ data: Data?) { locked { _states[id] = data } }
    func state(_ id: String) -> Data? { locked { _states[id] } }
    func busyOnDownload(_ id: String, _ data: Data) { locked { _busyOnDownload[id] = data } }
    func hold(_ id: String?) { locked { _held = id; _reached = false } }
    func quit(_ id: String, _ reason: LinkQuitReason) { locked { _quits.append("\(id):\(reason == .update ? "update" : "uninstall")"); _down.insert(id) } }
    func up(_ id: String) { _ = locked { _down.remove(id) } }

    func download(_ url: URL) async throws -> URL {
        let name = url.lastPathComponent
        let id = String(name.split(separator: "-")[0])
        locked { _downloads.append(id); _inFlight += 1; _maxInFlight = max(_maxInFlight, _inFlight) }
        defer { locked { _inFlight -= 1 } }
        if locked({ _offline.contains(id) }) { throw URLError(.notConnectedToInternet) }
        locked { if let flip = _busyOnDownload.removeValue(forKey: id) { _states[id] = flip } }
        while locked({ if _held == id { _reached = true; return true }; return false }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        let copy = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try fm.copyItem(at: fixtures.appendingPathComponent(name), to: copy)
        return copy
    }
}

let stage = Stage()
let paths = SatellitePaths(appsDir: workRoot.appendingPathComponent("Apps"), agentsDir: workRoot.appendingPathComponent("Agents"))

func sha(_ id: String) -> String {
    let data = try! Data(contentsOf: fixtures.appendingPathComponent("\(id)-2.0.0.zip"))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func entry(_ id: String, minHub: String = "0.6.0", brokenSha: Bool = false, notes: [String] = ["Что изменилось в 2.0.0"]) -> [String: Any] {
    ["id": id, "version": "2.0.0", "minHub": minHub, "url": "https://example.invalid/\(id)-2.0.0.zip",
     "sha256": brokenSha ? "00" : sha(id), "sizeMB": 2, "notes": notes]
}

func setCatalog(_ apps: [[String: Any]]) {
    stage.catalog = try! JSONSerialization.data(withJSONObject: ["schema": 1, "apps": apps])
}

func installedVersion(_ name: String) -> String? {
    NSDictionary(contentsOf: paths.appsDir.appendingPathComponent(name + ".app/Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
}

let awakeOn = LinkWire.encoded(AwakeState(isActive: true, endDate: nil, keepDisplay: false, duration: .forever, canStart: true))
let awakeOff = LinkWire.encoded(AwakeState(isActive: false, endDate: nil, keepDisplay: false, duration: .forever, canStart: true))

@MainActor func waitUntil(_ what: String, seconds: Double = 40, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { check(false, "дождаться: \(what)"); return }
        try? await Task.sleep(for: .milliseconds(30))
    }
}

// MARK: - Снимки

struct StoreWithSidebar: View {
    @State private var dashboard = false
    @State private var store = true
    @State private var about = false
    @State private var peeked: Module?
    @State private var selection = Module.mixer

    var body: some View {
        HStack(spacing: 0) {
            DSSidebar(current: nil, showDashboard: $dashboard, showStore: $store, showAbout: $about,
                      peeked: $peeked, selection: $selection)
                .frame(width: DS.sidebarWidth)
            StoreView()
        }
    }
}

@MainActor func shoot(_ name: String, width: CGFloat, height: CGFloat, _ root: some View) async {
    let host = NSHostingView(rootView: root.environment(\.moduleControls, DSModuleControls.forEnvironment).dsThemed().frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
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

/// Окно с панелью и лист отдельно, в обеих темах: `<имя>-<тема>-window|list.png`.
@MainActor func shots(_ name: String, window: Bool = true, list: Bool = true) async {
    for theme in ["graphite", "dusk"] {
        Kit.defaults.set(theme, forKey: DSTheme.storageKey)
        if window {
            await shoot("\(name)-\(theme)-window", width: 980, height: 680,
                        ZStack { DSBackground(module: .mixer, neutral: true); StoreWithSidebar() })
        }
        // Настоящий лист лежит на тёмном фоне окна.
        if list { await shoot("\(name)-\(theme)-list", width: 520, height: 560, ZStack { DSBackground(module: .mixer, neutral: true); UpdateAllSheet() }) }
    }
    Kit.defaults.removeObject(forKey: DSTheme.storageKey)
}

// MARK: - Чистая часть

@MainActor func busyDecoding() {
    func voice(recording: Bool = false, status: VoiceModelStore.Status = .installed) -> Data {
        var state = VoiceController.storedState()
        state.recording = recording
        state.models = state.models.map { VoiceModelRow(model: $0.model, status: status) }
        return LinkWire.encoded(state)
    }
    check(UpdateBusy.reason(.voice, state: voice()) == nil, "голос свободен")
    check(UpdateBusy.reason(.voice, state: voice(recording: true)) != nil, "голос: идёт запись")
    check(UpdateBusy.reason(.voice, state: voice(status: .downloading(progress: 0.5))) != nil, "голос: качает модель")
    check(UpdateBusy.reason(.voice, state: voice(status: .verifying)) != nil, "голос: проверяет модель")
    check(UpdateBusy.reason(.awake, state: awakeOn) != nil, "не спать: включён")
    check(UpdateBusy.reason(.awake, state: awakeOff) == nil, "не спать: выключен")
    var bots = BotsState.empty
    check(UpdateBusy.reason(.bots, state: LinkWire.encoded(bots)) == nil, "боты свободны")
    bots.running = true
    check(UpdateBusy.reason(.bots, state: LinkWire.encoded(bots)) != nil, "боты: идёт команда")
    let stash = StashState(running: [], stubborn: [], stashed: [], usage: [:], scenarios: [], busy: nil, report: nil)
    check(UpdateBusy.reason(.stash, state: LinkWire.encoded(stash)) == nil, "стеш свободен")
    var stashBusy = stash
    stashBusy.busy = "Закрываю"
    check(UpdateBusy.reason(.stash, state: LinkWire.encoded(stashBusy)) != nil, "стеш занят")
    check(UpdateBusy.reason(.awake, state: Data("мусор".utf8)) == nil, "не разобралось: свободна, иначе не обновить никогда")
    check(UpdateBusy.reason(.fans, state: Data()) == nil && UpdateBusy.reason(.keyboard, state: Data()) == nil, "у вентиляторов и клавиатуры `mayRestart` всегда да")
}

// MARK: - Сценарий

@MainActor func runAll() async {
    let sentinelDir = workRoot.appendingPathComponent("home/Application Support/Utilitumus/Voice/Models")
    try! fm.createDirectory(at: sentinelDir, withIntermediateDirectories: true)
    try! Data("модель".utf8).write(to: sentinelDir.appendingPathComponent("model.bin"))

    let installer = SatelliteInstaller(
        paths: paths,
        launchctl: { args in if args.first == "bootstrap", let id = args.last.map({ URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }) {
            stage.up(id.replacingOccurrences(of: "local.utilitumus.app.", with: ""))
        } },
        download: { try await stage.download($0) },
        verify: SatelliteInstaller.liveVerify,
        link: SatelliteLink(quit: { id, reason in
            stage.quit(id, reason)
            // Открытый экран читает как раз тогда, когда утилиты нет.
            if id == "sound" { await readSoundScreen() }
        }, hello: { id in
            if stage.helloFails.contains(id) { throw LinkError.timeout }
        }, helloWindow: 0.2))

    SatelliteRegistry.standEnvironment = SatelliteEnvironment(
        paths: paths, defaults: Kit.defaults, installer: installer,
        commands: SatelliteCommands(
            status: { _ in LinkStatus(enabled: true, line: "Работает", needsSetup: 0) },
            setEnabled: { _, _ in }, openWindow: { _ in },
            moduleState: { id in
                guard let data = stage.state(id) else { throw LinkError.timeout }
                return data
            },
            refreshScreen: { RemoteModules.testModels[$0]?.refresh() }),
        loadCatalog: {
            if stage.catalogFails { throw URLError(.notConnectedToInternet) }
            return stage.catalog
        },
        hubVersion: "0.6.0", modules: .shared)

    // Открытые экраны: связь подставная, настоящая утилита не при чём. Ни уведомлений, ни пингов от неё не будет.
    for module in Module.allCases where module != .browser && module != .voice {
        let id = module.rawValue
        RemoteModules.testModels[module] = RemoteModuleModel<AwakeState, AwakeAction>(
            id: "test.updateall.\(id)",
            initial: AwakeState(isActive: false, endDate: nil, keepDisplay: false, duration: .forever, canStart: true),
            link: RemoteModuleLink(
                state: {
                    if stage.down.contains(id) { throw LinkError.timeout }
                    return awakeOff
                },
                action: { _ in awakeOff }, setWatch: { _ in }, onPing: { _ in }),
            canRead: { true })
    }
    let registry = SatelliteRegistry.shared
    let store = StoreModel.shared
    let updates = UpdateAll.shared
    updates.recheckInterval = .milliseconds(80)
    updates.doneNoticeTime = .milliseconds(100)
    let soundScreen = RemoteModules.testModels[.sound] as! RemoteModuleModel<AwakeState, AwakeAction>
    screen = soundScreen
    await soundScreen.read()

    busyDecoding()

    // Сети нет: тихо, ничего не сломано.
    stage.catalogFails = true
    await registry.update()
    check(registry.catalogFailed, "каталог не прочитан: это видно")
    check(updates.rows.isEmpty && registry.hasBundle(.sound), "без каталога: обновлений нет, утилиты на месте")
    check(NSHostingView(rootView: UpdateAllNotice()).fittingSize.height == 0, "без каталога плашки в панели нет")
    await shots("offline", window: false)

    // Каталог пуст: тишина.
    stage.catalogFails = false
    setCatalog([])
    await registry.update()
    check(!registry.catalogFailed, "каталог снова читается")
    check(updates.rows.isEmpty && updates.startable.isEmpty, "обновлять нечего")
    check(NSHostingView(rootView: UpdateAllNotice()).fittingSize.height == 0, "обновлять нечего: плашки нет")
    await shots("nothing")

    // Основной каталог.
    setCatalog([entry("sound"), entry("load", minHub: "9.9.0"), entry("mixer", notes: ["Громкость запоминается", "Быстрее открывается"]),
                entry("mouse"), entry("clipboard"), entry("keyboard", brokenSha: true), entry("awake"), entry("stash")])
    stage.setState("awake", awakeOn)
    stage.setState("bots", LinkWire.encoded(BotsState.empty))
    await registry.update()
    let wanted: [Module] = [.sound, .mixer, .mouse, .clipboard, .keyboard, .awake]
    check(updates.startable == wanted, "в «Обновить всё» только установленные: \(updates.startable.map(\.rawValue))")
    check(NSHostingView(rootView: UpdateAllNotice()).fittingSize.height > 0, "плашка появилась")

    // Не установленный модуль: только предложение поставить.
    check(!updates.rows.contains { $0.module == .stash }, "не установленного нет в списке")
    check(!store.hasUpdate(.stash) && store.updateNotes(.stash).isEmpty && registry.needsNewerHub(.stash) == nil, "у него нет обновления и заметок")
    check(store.state(.stash) == .available && registry.catalogApp(.stash) != nil, "у него обычная установка")

    // Нужен центр новее.
    let loadRow = updates.rows.first { $0.module == .load }
    check(loadRow?.phase == .needsHub("9.9.0"), "новая версия не по силам центру: сказано об этом")
    check(registry.catalogApp(.load) == nil, "и её не предлагают ставить")
    await shots("notice")

    // Первый проход. Держим первое скачивание, чтобы посмотреть на ход и столкновения.
    stage.hold("sound")
    updates.start()
    check(updates.running, "флаг занят сразу, до первой паузы")
    let queued = updates.queue
    updates.start()
    updates.start()
    check(updates.queue == queued, "второй и третий запуск ничего не добавили")
    await waitUntil("первое скачивание") { stage.reached }

    check(store.state(.sound) == .installing(.download, 0), "плитка в Сторе видит ход обновления")
    store.remove(.sound)
    check(store.failure?.module == .sound && installedVersion("Sound") == "1.0.0", "удаление во время обновления: отказ, бандл цел")
    check(!Kit.defaults.bool(forKey: ModuleMigration.removedKey("sound")), "и утилита не считается удалённой")
    store.dismissFailure()
    store.update(.sound)
    try? await registry.install(.sound, app: registry.catalogApp(.sound)!)
    check(stage.downloads.filter { $0 == "sound" }.count == 1, "кнопка и переход поверх идущего обновления не качают второй раз")

    // Кнопка в Сторе для того, кто ещё в очереди: очередь дождётся и не повторит.
    store.update(.clipboard)
    await Task.yield()
    check(store.isOperating(.clipboard), "обновление из Стора для стоящего в очереди идёт своим ходом")

    // Лист закрыли: очередь идёт дальше.
    updates.listShown = true
    updates.listShown = false
    updates.listClosed()
    check(updates.running && stage.reached, "закрытие листа ничего не отменило")
    await shots("progress")

    stage.helloFails = ["mouse"]
    stage.hold(nil)
    await waitUntil("конца прохода") { !updates.running }

    let phases = Dictionary(uniqueKeysWithValues: updates.rows.map { ($0.module, $0.phase) })
    check(phases[.sound] == .done && installedVersion("Sound") == "2.0.0", "звук обновился")
    check(phases[.mixer] == .done && installedVersion("Mixer") == "2.0.0", "микшер обновился")
    if case .failed(let message)? = phases[.mouse] {
        check(message.contains("прежняя версия"), "мышь: утилита не ответила, текст «\(message)»")
    } else { check(false, "мышь: ждали сбой, \(String(describing: phases[.mouse]))") }
    check(installedVersion("Mouse") == "1.0.0", "мышь откатилась на прежнюю версию")
    check(installedVersion("Clipboard") == "2.0.0", "сбой посередине не остановил следующих")
    check(stage.downloads.filter { $0 == "clipboard" }.count == 1, "буфер скачан один раз: очередь не повторила за Стором")
    if case .failed(let message)? = phases[.keyboard] {
        check(message.contains("контрольная сумма"), "клавиатура: не та сумма, текст «\(message)»")
    } else { check(false, "клавиатура: ждали сбой, \(String(describing: phases[.keyboard]))") }
    check(installedVersion("Keyboard") == "1.0.0", "клавиатура не тронута")
    if case .waiting(let reason)? = phases[.awake] {
        check(!reason.isEmpty, "не спать ждёт: «\(reason)»")
    } else { check(false, "не спать: ждали ожидание, \(String(describing: phases[.awake]))") }
    check(!stage.quits.contains { $0.hasPrefix("awake") } && installedVersion("Awake") == "1.0.0", "занятую утилиту не останавливали")
    check(!stage.downloads.contains("awake"), "и не качали зря")
    check(!stage.downloads.contains("load") && !stage.downloads.contains("stash"), "не установленный и «нужен центр новее» не качались")
    check(!fm.fileExists(atPath: paths.appsDir.appendingPathComponent("Stash.app").path), "не установленный не появился")
    check(stage.maxInFlight == 1, "по одной за раз (одновременно \(stage.maxInFlight))")
    check(stage.quits.allSatisfy { $0.hasSuffix(":update") }, "причина выхода всегда «обновление», путь удаления не трогали: \(stage.quits)")
    check(soundScreen.responding, "открытый экран сам вернулся после обновления, без уведомления от утилиты")
    check(sawNotResponding, "и он правда успел потерять утилиту")
    check(fm.fileExists(atPath: sentinelDir.appendingPathComponent("model.bin").path), "данные на месте")
    check(ModuleManager.shared.isOn(.sound) && !Kit.defaults.bool(forKey: ModuleMigration.removedKey("sound")), "установленным модуль и остался")
    await shots("partial")

    // Занятая не обновляется, пока занята; освободилась — обновляется сама, после двух проверок подряд.
    try? await Task.sleep(for: .milliseconds(300))
    check(installedVersion("Awake") == "1.0.0", "пока занята, не трогаем")
    stage.setState("awake", awakeOff)
    await waitUntil("обновления «не спать»") { installedVersion("Awake") == "2.0.0" && !updates.running }
    check(stage.quits.contains("awake:update"), "освободилась и обновилась сама")

    // Повтор сбойных.
    stage.helloFails = []
    updates.retry(.mouse)
    updates.retry(.mouse)
    await waitUntil("повтора мыши") { !updates.running }
    check(installedVersion("Mouse") == "2.0.0", "повтор: мышь обновилась")
    check(stage.downloads.filter { $0 == "mouse" }.count == 2, "двойной повтор не запустил дважды")
    setCatalog([entry("load", minHub: "9.9.0"), entry("keyboard"), entry("bots"), entry("stash")])
    await registry.update()
    stage.offline = ["keyboard"]
    updates.retry(.keyboard)
    await waitUntil("повтора клавиатуры без сети") { !updates.running }
    if case .failed(let message)? = updates.rows.first(where: { $0.module == .keyboard })?.phase {
        check(message.contains("сеть"), "пропала сеть посреди: спокойный текст «\(message)»")
    } else { check(false, "клавиатура без сети: ждали сбой") }
    stage.offline = []
    updates.retry(.keyboard)
    await waitUntil("повтора клавиатуры") { !updates.running }
    check(installedVersion("Keyboard") == "2.0.0", "повтор: клавиатура обновилась")

    // Занята стала, пока качалось: установщик спрашивает ещё раз перед самой остановкой.
    var botsBusy = BotsState.empty
    botsBusy.running = true
    stage.busyOnDownload("bots", LinkWire.encoded(botsBusy))
    updates.start()
    await waitUntil("конца прохода ботов") { !updates.running }
    if case .waiting? = updates.rows.first(where: { $0.module == .bots })?.phase {
        check(installedVersion("Bots") == "1.0.0" && !stage.quits.contains { $0.hasPrefix("bots") }, "занялась во время скачивания: не остановлена")
    } else { check(false, "боты: ждали ожидание") }
    // Кнопка в Сторе у занятой утилиты: та же проверка, понятный текст, ничего не оборвано.
    store.update(.bots)
    await waitUntil("отказа кнопки") { store.failure != nil }
    check(store.failure?.message.contains("Сейчас нельзя") == true && !stage.quits.contains { $0.hasPrefix("bots") }, "кнопка в Сторе: «\(store.failure?.message ?? "")»")
    store.dismissFailure()
    stage.setState("bots", LinkWire.encoded(BotsState.empty))
    await waitUntil("обновления ботов") { installedVersion("Bots") == "2.0.0" && !updates.running }

    // Переход на утилиту при запуске центра и очередь одновременно: установщик один за раз.
    setCatalog([entry("load", minHub: "0.6.0"), entry("stash")])
    await registry.update()
    let migration = ModuleMigrationEnvironment(
        defaults: Kit.defaults, hubVersion: "0.6.0",
        loadCatalog: { stage.catalog },
        wantsUtility: { $0 == .stash },
        hasBundle: { fm.fileExists(atPath: paths.appsDir.appendingPathComponent(SatelliteRegistry.bundleName($0) + ".app").path) },
        install: { module, app in try await SatelliteRegistry.shared.install(module, app: app) })
    stage.hold("load")
    updates.start()
    let migrating = Task { await ModuleMigration.run(migration) }
    await waitUntil("скачивания load") { stage.reached }
    stage.hold(nil)
    await migrating.value
    await waitUntil("конца прохода load") { !updates.running }
    check(installedVersion("Load") == "2.0.0" && installedVersion("Stash") == "2.0.0", "очередь и переход оба дошли до конца")
    check(stage.maxInFlight == 1, "и не шли одновременно")

    // Итог: всё сделано.
    await waitUntil("исчезновения готовых строк") { updates.rows.isEmpty }
    check(updates.rows.isEmpty && updates.startable.isEmpty, "обновлять больше нечего")
    await waitUntil("исчезновения плашки") { NSHostingView(rootView: UpdateAllNotice()).fittingSize.height == 0 }

    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

@MainActor var screen: RemoteModuleModel<AwakeState, AwakeAction>?
@MainActor var sawNotResponding = false
@MainActor func readSoundScreen() async {
    await screen?.read()
    if screen?.responding == false { sawNotResponding = true }
}

try! fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
UserDefaults.standard.set(true, forKey: ModuleReset.flagKey)
Task { @MainActor in await runAll() }
app.run()
