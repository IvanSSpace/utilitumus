import AppKit
import SwiftUI
import Combine

// Дашборд, меню, чек-лист и остановка при передаче для модулей, которых ведёт утилита. Без утилиты и без подписи:
// статус подставной, окно за экраном. Запуск: Tests/run-dashboard-routing-check.sh. Аргументы: рабочая папка, папка PNG.

let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let pngDir = URL(fileURLWithPath: CommandLine.arguments[2])
nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func clear() { lock.lock(); items = []; lock.unlock() }
}
let journal = Journal()

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: [String: LinkStatus] = [:]
    func status(_ id: String) -> LinkStatus? { lock.lock(); defer { lock.unlock() }; return _status[id] }
    func set(_ id: String, _ status: LinkStatus?) { lock.lock(); _status[id] = status; lock.unlock() }
}
let box = Box()

@MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

func bundle(_ name: String, in dir: URL) {
    let app = dir.appendingPathComponent(name + ".app/Contents")
    try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleShortVersionString": "1.0.0"]
    (info as NSDictionary).write(to: app.appendingPathComponent("Info.plist"), atomically: true)
}

@MainActor func snapshot(_ name: String, _ view: some View) async -> NSBitmapImageRep {
    let root = ZStack { DSBackground(module: .sound, neutral: true); view }
        .environment(\.pageActive, true)
        .environment(\.moduleControls, DSModuleControls.forEnvironment)
        .dsThemed()
        .frame(width: 760, height: 420)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 420),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    await pause(0.5)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: pngDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    window.contentView = nil
    return rep
}

func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, fromRow: Int = 0) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let x = a.bitmapData, let y = b.bitmapData else { return Int.max }
    var count = 0
    for i in (fromRow * a.pixelsWide)..<(a.pixelsWide * a.pixelsHigh) where memcmp(x + i * 4, y + i * 4, 4) != 0 { count += 1 }
    return count
}

final class FakeAwake: AwakeModel {
    var isActive = false
    var endDate: Date?
    var keepDisplay: Bool
    var duration: AwakeDuration
    var canStart = true
    init(keepDisplay: Bool, duration: AwakeDuration) {
        self.keepDisplay = keepDisplay
        self.duration = duration
    }
    func toggle() {}
}

final class WireBox: @unchecked Sendable {
    var data = Data()
    var refusal = Data()
    var watches: [LinkWatch] = []
}

/// Модель с управляемой связью: отвечает заданным состоянием, утилиты нет.
@MainActor func fixtureModel<S: Codable & Equatable & Sendable, A: Codable & Sendable, M: RemoteModuleModel<S, A>>(
    make: (RemoteModuleLink) -> M, edit: (inout S) -> Void) async -> (model: M, wire: WireBox) {
    let wire = WireBox()
    let link = RemoteModuleLink(state: { wire.data }, action: { _ in wire.refusal },
                                setWatch: { wire.watches.append($0) }, onPing: { _ in })
    let model = make(link)
    var state = model.state
    edit(&state)
    wire.data = LinkWire.encoded(state)
    wire.refusal = LinkWire.encoded(LinkReply(state: state, error: "Стеш занят в другой программе"))
    await model.read()
    return (model, wire)
}

@MainActor func run() async {
    let appsDir = workRoot.appendingPathComponent("Apps")
    try? FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
    for name in ["Sound", "Load", "Mouse", "Keyboard"] { bundle(name, in: appsDir) }
    let paths = SatellitePaths(appsDir: appsDir, agentsDir: workRoot.appendingPathComponent("Agents"))
    SatelliteRegistry.standEnvironment = SatelliteEnvironment(
        paths: paths, defaults: Kit.defaults,
        installer: SatelliteInstaller(paths: paths, launchctl: { _ in }, download: { $0 }, verify: { _, _ in }),
        commands: SatelliteCommands(
            status: { id in
                guard let status = box.status(id) else { throw LinkError.timeout }
                return status
            },
            setEnabled: { id, on in journal.add("enabled \(id) \(on)") },
            openWindow: { _ in },
            action: { id, data in
                journal.add("action \(id) \(String(decoding: data, as: UTF8.self))")
                return Data(#"{"error":"нельзя"}"#.utf8)
            },
            performStep: { id, step in
                journal.add("step \(id) \(step)")
                throw LinkError.timeout
            }),
        loadCatalog: { Data(#"{"schema":1,"apps":[]}"#.utf8) },
        hubVersion: "0.6.0", modules: .shared)
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared

    // MARK: Чистая часть — карточка из статуса
    print("== карточка из статуса")
    let quick = LinkQuickAction(title: "Обновить", icon: nil, action: Data(#"{"refresh":{}}"#.utf8))
    let plain = LinkStatus(enabled: true, line: "память 8 из 16 ГБ", needsSetup: 0, quickActions: [quick])
    var expected = DashState(text: "память 8 из 16 ГБ", actionTitle: "Обновить")
    expected.quick = quick
    check(DashboardLive.externalState(status: plain, model: nil) == expected, "строка и действие из статуса")
    check(DashboardLive.externalState(status: nil, model: nil) == DashState(text: "не отвечает", attention: true), "нет ответа: не отвечает")
    check(DashboardLive.externalState(status: LinkStatus(enabled: false, line: "x", needsSetup: 0), model: nil)
          == DashState(on: false, text: "выключен"), "выключена: «выключен», кнопка «Включить»")
    check(DashboardLive.externalState(status: LinkStatus(enabled: true, line: "x", needsSetup: 2, attention: false), model: nil)
          == DashState(text: "нужен доступ", attention: true), "нужен шаг: «нужен доступ»")
    check(DashboardLive.externalState(status: LinkStatus(enabled: true, line: "перегрев", needsSetup: 0, attention: true), model: nil)
          == DashState(text: "перегрев", attention: true), "оранжевое из статуса")

    // Карточка «Не спать»: модель, а не строка статуса.
    let awakeModel = RemoteAwakeModel(id: "test.awake", canRead: { false })
    let awakeStatus = LinkStatus(enabled: true, line: "Mac не уснёт", needsSetup: 0, quickActions: [quick])
    check(DashboardLive.externalState(status: awakeStatus, model: awakeModel) == DashboardLive.awake(awakeModel),
          "Не спать: карточка из модели, не из статуса")
    check(DashboardLive.awake(awakeModel) == DashboardLive.awake(FakeAwake(keepDisplay: awakeModel.keepDisplay, duration: awakeModel.duration)),
          "Не спать: карточка зависит только от состояния модели")
    check(awakeModel.menuUsesQuickActions == false, "Не спать: меню рисует свой пункт")

    // MARK: Меню
    print("== меню")
    let order = Module.allCases
    for m in [Module.sound, .load, .awake] { modules.setExternal(m, true) }
    let entries: [Module: SatelliteRegistry.Entry] = [
        .load: .init(catalog: nil, installedVersion: "1", status: plain, responding: true),
        .sound: .init(catalog: nil, installedVersion: "1", status: LinkStatus(enabled: true, line: "x", needsSetup: 0), responding: true),
        .awake: .init(catalog: nil, installedVersion: "1", status: awakeStatus, responding: true),
    ]
    let sections = MenuQuickActions.sections(order: order, modules: modules, entries: entries)
    check(sections == [.init(module: .load, actions: [quick])], "секция только у модуля с утилитой и действиями; Не спать и без действий нет")
    var off = entries
    off[.load]?.status = LinkStatus(enabled: false, line: "x", needsSetup: 0, quickActions: [quick])
    check(MenuQuickActions.sections(order: order, modules: modules, entries: off).isEmpty, "выключенного модуля в меню нет")
    for m in [Module.sound, .load, .awake] { modules.setExternal(m, false) }

    // MARK: Сброс
    print("== сброс")
    let snapshotKeys: [String: Any] = ["ModuleOn.keyboard": true, "Keyboard.KeepSystemFnOff": true, "App.keyboard.HandedOver": true]
    let plan = ModuleReset.plan(snapshot: snapshotKeys, moduleIDs: ["keyboard", "sound"], handedOver: { $0 == "keyboard" })
    check(plan?.askUtility == ["keyboard"] && plan?.restoresSystemFn == false, "сброс: ведомая Клавиатура спрашивает утилиту и 🌐 сам не возвращает")
    let plain2 = ModuleReset.plan(snapshot: snapshotKeys, moduleIDs: ["keyboard", "sound"])
    check(plain2?.askUtility == [] && plain2?.restoresSystemFn == true, "сброс: без утилиты как прежде")

    // MARK: Чек-лист утилиты
    print("== чек-лист")
    let steps = [
        LinkSetupStep(id: "mouse.ax", title: "Универсальный доступ", why: "зачем", icon: "lock.shield.fill", done: false),
        LinkSetupStep(id: "mouse.opt", title: "Рекомендация", why: "зачем", icon: "star", kind: .recommendation, required: false, done: false),
        LinkSetupStep(id: "mouse.capture", title: "Запись звука", why: "система спросит", icon: "waveform", verifiable: false, done: true),
    ]
    box.set("mouse", LinkStatus(enabled: true, line: "x", needsSetup: 1, setupSteps: steps))
    box.set("load", plain)
    box.set("sound", LinkStatus(enabled: true, line: "слежу за микрофоном", needsSetup: 0))
    box.set("keyboard", nil)
    modules.setOn(.mouse, true)
    await registry.update()
    // Утилита стоит, шаг не сделан: передача всё равно состоялась, чек-лист — шаги утилиты.
    check(modules.isExternal(.mouse), "шаг не сделан: модуль передан")
    let shown = Module.mouse.setupSteps
    check(shown.map(\.id) == ["mouse.ax", "mouse.opt", "mouse.capture"], "чек-лист — шаги утилиты")
    check(shown.map(\.status) == [.needed, .optional, .onDemand], "статусы: нужен, необязательный, непроверяемый не считается готовым")
    check(Module.mouse.setupProgress.done == 0 && Module.mouse.setupProgress.total == 2, "непроверяемый шаг не идёт в счёт готовых")
    AccessState.shared.refresh()
    check(Module.mouse.isBlocked, "модуль заблокирован шагом утилиты")
    shown[0].perform()
    await pause(0.3)
    check(journal.all.contains("step mouse mouse.ax"), "шаг уходит утилите, не выполняется в центре: \(journal.all)")
    check(registry.stepErrors["mouse.mouse.ax"] != nil, "молчание утилиты видно на шаге")
    // Ответа нет: у ведомого модуля шагов «из центра» нет.
    modules.setExternal(.keyboard, true)
    check(Module.keyboard.setupSteps.isEmpty, "ведомый без ответа: шагов центра нет, не «готово» по разрешениям центра")
    modules.setExternal(.keyboard, false)
    // Быстрое действие: идёт утилите как есть, отказ виден.
    journal.clear()
    registry.perform(quick, module: .load)
    await pause(0.3)
    check(journal.all == [#"action load {"refresh":{}}"#], "быстрое действие уходит в moduleAction как есть: \(journal.all)")
    check(registry.actionErrors[.load] == "нельзя", "отказ утилиты виден")

    // MARK: Модуль без утилиты
    print("== модуль без утилиты")
    // Чистый лист: ни бандлов, ни передачи, ни включённых модулей.
    for module in Module.allCases {
        modules.setOn(module, false)
        Kit.defaults.removeObject(forKey: ModuleHandover.handedOverKey(module.rawValue))
    }
    try? FileManager.default.removeItem(at: appsDir)
    await registry.update()
    check(Module.allCases.allSatisfy { !modules.isExternal($0) && !modules.isOn($0) }, "чистый лист перед снимками")
    check(MenuQuickActions.sections(order: order, modules: modules, entries: entries).isEmpty, "без утилит быстрых действий в меню нет, что бы ни лежало в статусах")
    check(AppMenuBarScene.switchable(modules).isEmpty, "без утилит переключателей в меню нет")
    let emptyPage = await snapshot("no-modules", DashboardPage(open: { _ in }))
    for module in Module.allCases {
        modules.setOn(module, true)
        await registry.update()
        check(modules.wantsUtility(module), "\(module.rawValue): модуль включён, утилита нужна")
        let state = DashboardLive.snapshot(module)
        check(state == DashState(text: "утилита не установлена", attention: true) && state.actionTitle == nil && state.on,
              "\(module.rawValue): карточка «утилита не установлена», оранжевая, без действий и без «Включить»")
        check(!AppMenuBarScene.switchable(modules).contains(module), "\(module.rawValue): в меню переключателя нет")
        // Просить некого: ни команды, ни включения, ни установки сама карточка не делает.
        journal.clear()
        DashboardLive.perform(module, ask: { _ in check(false, "\(module.rawValue): вопрос у карточки без действий") })
        await pause(0.05)
        check(journal.all.isEmpty && modules.wantsUtility(module), "\(module.rawValue): действие карточки ничего не делает: \(journal.all)")
        modules.setOn(module, false)
        check(DashboardLive.snapshot(module) == DashState(text: "утилита не установлена", attention: true),
              "\(module.rawValue): и у открытой страницы не установленного модуля та же строка, а не «выключен» с кнопкой")
    }
    modules.setOn(.mixer, true)
    let missingPage = await snapshot("missing-mixer", DashboardPage(open: { _ in }))
    check(differing(emptyPage, missingPage) > 0, "карточка модуля без утилиты видна на дашборде")
    modules.setOn(.mixer, false)

    print("== шапка дашборда")
    check(DashboardPage.summary(on: 2, of: 3, needAccess: [], missing: [.mixer]) == "Нет утилиты: \(Module.mixer.title) · 2 из 3 модулей включены",
          "нет утилиты: шапка говорит об этом, а не «Всё работает»")
    check(DashboardPage.summary(on: 1, of: 3, needAccess: [.mouse], missing: [.mixer, .load])
          == "Нужен доступ: \(Module.mouse.title) · Нет утилиты: \(Module.mixer.title), \(Module.load.title) · 1 из 3 модулей включён",
          "нужен доступ и нет утилиты: оба")
    check(DashboardPage.summary(on: 2, of: 2, needAccess: [], missing: []).hasPrefix("Всё работает"), "всё на месте: «Всё работает»")
    check(DashboardPage.summary(on: 0, of: 1, needAccess: [], missing: []).hasPrefix("Ничего не включено"), "всё выключено: «Ничего не включено»")

    // MARK: Пиксели — карточка модуля с утилитой
    print("== пиксели")
    // Мышь с невыполненным шагом: карточка оранжевая, шапка просит доступ.
    let mouseStatus = LinkStatus(enabled: true, line: "x", needsSetup: 1, setupSteps: [steps[0]])
    bundle(SatelliteRegistry.bundleName(.mouse), in: appsDir)
    box.set(Module.mouse.rawValue, mouseStatus)
    Kit.defaults.set(true, forKey: ModuleHandover.handedOverKey(Module.mouse.rawValue))
    await registry.update()
    AccessState.shared.refresh()
    check(modules.isExternal(.mouse), "mouse: утилита ведёт модуль")
    check(DashboardLive.snapshot(.mouse).text != "утилита не установлена", "mouse: карточка больше не про установку")
    let mouseShot = await snapshot("external-mouse", DashboardPage(open: { _ in }))
    check(differing(emptyPage, mouseShot) > 0, "карточка Мыши снята")
    Kit.defaults.removeObject(forKey: ModuleHandover.handedOverKey(Module.mouse.rawValue))
    try? FileManager.default.removeItem(at: appsDir.appendingPathComponent(SatelliteRegistry.bundleName(.mouse) + ".app"))
    await registry.update()
    check(!modules.isExternal(.mouse), "mouse: снято")

    // MARK: Маршрутизация по RemoteModules
    print("== RemoteModules")
    for module in Module.allCases {
        let model = RemoteModules.model(module)
        if module == .browser {
            check(model == nil, "browser: модели нет, экран читает общий домен сам")
            continue
        }
        let expectedType = "Remote\(module.rawValue.prefix(1).uppercased() + module.rawValue.dropFirst())Model"
        check(model.map { String(describing: type(of: $0)) } == expectedType, "\(module.rawValue): модель \(expectedType)")
        check(model != nil && model === RemoteModules.model(module), "\(module.rawValue): модель одна на всех (shared)")
    }
    for m in Module.allCases { modules.setExternal(m, true) }
    check(RemoteModules.external(modules).map(\.0).count == Module.allCases.count - 1, "external: все ведомые, кроме браузера")
    for m in Module.allCases { modules.setExternal(m, false) }

    // MARK: Пиксели — карточка из состояния по связи
    print("== пиксели из состояния утилиты")
    struct Fixture {
        let module: Module
        let model: any RemoteModuleSurface
        /// Что должна показать карточка по этим данным, записано руками.
        let expected: DashState
    }
    var fixtures: [Fixture] = []
    do {
        let (m, _) = await fixtureModel(make: { RemoteFansModel(id: "t.fans", link: $0, canRead: { true }) }) { (s: inout FansState) in
            s.fullPower = true; s.helperStatus = .ready; s.conflict = nil
        }
        fixtures.append(Fixture(module: .fans, model: m, expected: DashState(text: "Макс", actionTitle: "Авто", actionIcon: "arrow.uturn.backward")))
    }
    do {
        let (m, _) = await fixtureModel(make: { RemoteMixerModel(id: "t.mixer", link: $0, canRead: { true }) }) { (s: inout MixerState) in
            s.apps = [MixerAppState(id: "a", name: "Музыка", volume: 0.5, muted: false)]
        }
        fixtures.append(Fixture(module: .mixer, model: m, expected: DashState(text: "играет Музыка · 50 %")))
    }
    do {
        let (m, _) = await fixtureModel(make: { RemoteKeyboardModel(id: "t.keyboard", link: $0, canRead: { true }) }) { (s: inout KeyboardState) in
            s.features = [KeyboardFeature.fnLanguage.rawValue]; s.tapActive = true; s.systemUsage = 0; s.secureInputApp = nil
            s.currentName = "Русская"
        }
        fixtures.append(Fixture(module: .keyboard, model: m, expected: DashState(text: "Русская")))
    }
    do {
        let (m, _) = await fixtureModel(make: { RemoteSoundModel(id: "t.sound", link: $0, canRead: { true }) }) { (s: inout SoundState) in
            s.currentInputName = "MacBook Pro Microphone"
        }
        fixtures.append(Fixture(module: .sound, model: m, expected: DashState(text: "MacBook Pro Microphone")))
    }
    do {
        let (m, _) = await fixtureModel(make: { RemoteClipboardModel(id: "t.clipboard", link: $0, canRead: { true }) }) { (s: inout ClipboardState) in
            s.totalCount = 7; s.storeError = nil
        }
        fixtures.append(Fixture(module: .clipboard, model: m, expected: DashState(text: "\(m.hotKeyLabel) · 7 записей")))
    }
    do {
        let (m, _) = await fixtureModel(make: { RemoteStashModel(id: "t.stash", link: $0, canRead: { true }) }) { (s: inout StashState) in
            s.stashed = []; s.busy = nil; s.usage = [:]
            s.running = [.init(bundleID: "a", name: "A", closing: true), .init(bundleID: "b", name: "B", closing: true)]
        }
        fixtures.append(Fixture(module: .stash, model: m, expected: DashState(text: "выбрано 2", actionTitle: "Спрятать", actionIcon: "archivebox")))
    }
    do {
        let (m, _) = await fixtureModel(make: { RemoteLoadModel(id: "t.load", canRead: { true }, link: $0) }) { (s: inout LoadState) in s.measure = nil }
        fixtures.append(Fixture(module: .load, model: m, expected: DashState(text: "открой для замера", actionTitle: "Обновить")))
    }
    do {
        let (m, _) = await fixtureModel(make: { RemoteVoiceModel(id: "t.voice", link: $0, canRead: { true }) }) { (s: inout VoiceState) in
            s.recording = true
        }
        fixtures.append(Fixture(module: .voice, model: m, expected: DashState(text: "идёт запись…")))
    }
    let plainStatus = LinkStatus(enabled: true, line: "строка статуса", needsSetup: 0)
    for f in fixtures {
        check(DashboardLive.externalState(status: plainStatus, model: f.model) == f.expected,
              "\(f.module.rawValue): карточка из состояния утилиты")
    }
    // Настоящий путь: модуль без утилиты, утилита появилась, реестр передал ей модуль, карточка сменилась; утилиту убрали, карточка вернулась.
    for f in fixtures {
        RemoteModules.testModels[f.module] = f.model
        modules.setOn(f.module, true)
        AccessState.shared.refresh()
        check(DashboardLive.snapshot(f.module) == DashboardLive.missingState, "\(f.module.rawValue): без утилиты модель не читается")
        let missing = await snapshot("fixture-missing-\(f.module.rawValue)", DashboardPage(open: { _ in }))
        modules.setOn(f.module, false)
        bundle(SatelliteRegistry.bundleName(f.module), in: appsDir)
        box.set(f.module.rawValue, plainStatus)
        Kit.defaults.set(true, forKey: ModuleHandover.handedOverKey(f.module.rawValue))
        await registry.update()
        check(modules.isExternal(f.module), "\(f.module.rawValue): утилита ведёт модуль")
        check(DashboardLive.snapshot(f.module) == f.expected, "\(f.module.rawValue): карточка идёт через реестр и модель")
        check(AppMenuBarScene.switchable(modules).contains(f.module), "\(f.module.rawValue): в меню есть переключатель")
        let external = await snapshot("fixture-external-\(f.module.rawValue)", DashboardPage(open: { _ in }))
        check(!f.module.isBlocked, "\(f.module.rawValue): у утилиты без шагов шапка не просит доступ")
        check(differing(missing, external) > 0, "\(f.module.rawValue): карточка на экране сменилась")
        Kit.defaults.removeObject(forKey: ModuleHandover.handedOverKey(f.module.rawValue))
        try? FileManager.default.removeItem(at: appsDir.appendingPathComponent(SatelliteRegistry.bundleName(f.module) + ".app"))
        await registry.update()
        check(!modules.isExternal(f.module), "\(f.module.rawValue): снято")
        RemoteModules.testModels[f.module] = nil
    }

    // MARK: Меню и действия карточки
    print("== меню и действия")
    for f in fixtures where [Module.fans, .stash, .clipboard].contains(f.module) {
        check(f.model.menuUsesQuickActions == false, "\(f.module.rawValue): меню рисует модуль, не быстрые действия статуса")
    }
    for f in fixtures where [Module.mixer, .keyboard, .sound, .load, .voice].contains(f.module) {
        check(f.model.menuUsesQuickActions == true, "\(f.module.rawValue): в меню быстрые действия статуса, как раньше")
    }
    // Отказ Стеша из-за метки другого процесса виден на карточке, обычный вид без текста.
    if let stash = fixtures.first(where: { $0.module == .stash })?.model as? RemoteStashModel {
        check(stash.actionError == nil, "стеш: без отказа текста нет")
        await stash.restore()
        check(stash.actionError == "Стеш занят в другой программе", "стеш: отказ из-за метки другого процесса виден: \(stash.actionError ?? "nil")")
        let shown = DashboardLive.externalState(status: plainStatus, model: stash)
        check(shown.text == "Стеш занят в другой программе" && shown.attention, "стеш: текст отказа на карточке")
    }
    // Слежение за состоянием включено только пока дашборд виден.
    do {
        let (m, wire) = await fixtureModel(make: { RemoteMixerModel(id: "t.mixer2", link: $0, canRead: { true }) }) { (_: inout MixerState) in }
        check(wire.watches == [.none], "микшер: до показа дашборда слежения нет: \(wire.watches)")
        m.setDashboardVisible(true)
        m.setDashboardVisible(false)
        check(wire.watches == [.none, .changes, .none], "микшер: слежение только пока дашборд виден: \(wire.watches)")
        m.setScreenOpen(true)
        m.setDashboardVisible(true)
        m.setDashboardVisible(false)
        check(wire.watches.last == .screen, "аренда экрана сильнее слежения дашборда: \(wire.watches)")
    }
    // Вентиляторы и Нагрузка шлют и меряют только при аренде экрана: пока дашборд виден, карточка живая, скрыт — аренды нет.
    do {
        let wire = WireBox()
        var ping: (@MainActor () -> Void)?
        let link = RemoteModuleLink(state: { wire.data }, action: { _ in wire.refusal },
                                    setWatch: { wire.watches.append($0) }, onPing: { ping = $0 })
        let model = RemoteFansModel(id: "t.fans.live", link: link, canRead: { true })
        func publish(rpm: Double) {
            var state = model.state
            state.helperStatus = .ready
            state.fans = [FanReading(index: 0, actual: rpm, min: 1200, max: 6000, isManual: false, target: 0)]
            wire.data = LinkWire.encoded(state)
        }
        func text() -> String { model.dashboardState(base: DashState(text: "статус"), status: nil).text }
        check(wire.watches == [.none], "вентиляторы: до показа дашборда аренды нет: \(wire.watches)")
        model.setDashboardVisible(true)
        check(wire.watches == [.none, .screen], "вентиляторы: дашборд виден, аренда экрана: \(wire.watches)")
        publish(rpm: 2000)
        ping?()
        await pause(0.3)
        check(text().contains("2000 об/мин"), "вентиляторы: пинг утилиты обновил карточку: \(text())")
        publish(rpm: 3000)
        ping?()
        await pause(0.3)
        check(text().contains("3000 об/мин"), "вентиляторы: следующий пинг тоже: \(text())")
        model.setDashboardVisible(false)
        check(wire.watches == [.none, .screen, .none], "вентиляторы: дашборд скрыт, аренда снята: \(wire.watches)")
    }
    do {
        let (m, wire) = await fixtureModel(make: { RemoteLoadModel(id: "t.load2", canRead: { true }, link: $0) }) { (_: inout LoadState) in }
        check(wire.watches == [.none], "нагрузка: до показа дашборда аренды нет: \(wire.watches)")
        m.setDashboardVisible(true)
        m.setDashboardVisible(false)
        check(wire.watches == [.none, .screen, .none], "нагрузка: аренда экрана только пока дашборд виден: \(wire.watches)")
    }
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
