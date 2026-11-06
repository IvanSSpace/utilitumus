import AppKit
#if !STASH_NO_SCREEN
import SwiftUI
#endif

// Модель, связь и экран Стеша. Запуск: Tests/run-stash-wire-check.sh
// Все программы здесь поддельные: подмена `StashSystem` не даёт увидеть, закрыть или запустить настоящую.
// Настройки только в своём suite. Общего экземпляра стеша и его настроек проверка не касается. Окно за экраном и прозрачное.

let suite = "local.utilitumus.test.stash"
let keys = ["StashedApps", "StashedApps.unreadable", "StashExcludedBundleIDs", "StashScenarios"]

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Подделка программы: ни один вызов не доходит до настоящего `NSRunningApplication`.
final class FakeApp: NSRunningApplication, @unchecked Sendable {
    let fakeID: String
    let fakeName: String?
    let fakeURL: URL?
    let fakeIcon: NSImage?
    /// Не закрывается штатно, как программа с диалогом о несохранённом.
    let stubborn: Bool
    var dead = false
    var terminations = 0
    var forced = 0

    init(_ id: String, name: String? = nil, url: URL? = nil, icon: NSImage? = nil, stubborn: Bool = false) {
        fakeID = id
        fakeName = name ?? id
        fakeURL = url ?? URL(fileURLWithPath: "/nonexistent/\(id).app")
        fakeIcon = icon
        self.stubborn = stubborn
        super.init()
    }

    override var bundleIdentifier: String? { fakeID }
    override var localizedName: String? { fakeName }
    override var bundleURL: URL? { fakeURL }
    override var icon: NSImage? { fakeIcon }
    override var activationPolicy: NSApplication.ActivationPolicy { .regular }
    override var isTerminated: Bool { dead }
    override var processIdentifier: pid_t { -1 }
    override func terminate() -> Bool {
        terminations += 1
        if !stubborn { dead = true }
        return true
    }
    override func forceTerminate() -> Bool {
        forced += 1
        dead = true
        return true
    }
}

@MainActor final class World {
    var apps: [FakeApp] = []
    var opened: [URL] = []
    var activates: [Bool] = []
    var calls: Int { apps.reduce(opened.count) { $0 + $1.terminations + $1.forced } }
}

@MainActor func makeStore(_ world: World, keep: Bool = false) -> StashStore {
    let defaults = UserDefaults(suiteName: suite)!
    if !keep { keys.forEach(defaults.removeObject(forKey:)) }
    let store = StashStore(defaults: defaults)
    store.system = StashSystem(runningApps: { world.apps }, open: { url, config in
        world.opened.append(url)
        world.activates.append(config.activates)
        return FakeApp("test.opened")
    })
    store.refresh()
    return store
}

func encoded(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try! encoder.encode(value)
}

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    let data = encoded(value)
    guard let back = try? JSONDecoder().decode(T.self, from: data) else { return false }
    return back == value && encoded(back) == data
}

/// Всё, что не должно меняться при отказе: состояние, настройки и вызовы к программам.
struct Snapshot: Equatable {
    let state: Data
    let excluded: Set<String>
    let saved: [Data?]
    let excludedSaved: [String]?
    let calls: Int
    let pending: String?
}

@MainActor func snapshot(_ store: StashStore, _ world: World) -> Snapshot {
    let defaults = UserDefaults(suiteName: suite)!
    return Snapshot(state: encoded(store.wireState), excluded: store.excluded,
                    saved: [defaults.data(forKey: "StashedApps"), defaults.data(forKey: "StashScenarios")],
                    excludedSaved: defaults.stringArray(forKey: "StashExcludedBundleIDs"),
                    calls: world.calls, pending: store.pendingBusy)
}

@MainActor func refused(_ store: StashStore, _ world: World, _ action: StashAction, _ name: String) {
    let before = snapshot(store, world)
    let error = store.handle(action)
    check(error != nil && snapshot(store, world) == before, "\(name): \(error ?? "отказа нет")")
}

/// Ждём конца долгого действия из связи.
@MainActor func settle(_ store: StashStore) async {
    let deadline = Date().addingTimeInterval(StashStore.waitSeconds + 10)
    while store.pendingBusy != nil, Date() < deadline { await pause(0.05) }
}

let scenarioID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
let unknownID = UUID(uuidString: "99999999-2222-3333-4444-555555555555")!
let allActions: [StashAction] = [
    .setClosing(bundleID: "a", closing: false), .selectOnlyHeavy, .stash(bundleIDs: ["a", "b"]), .restore,
    .forceTerminate(bundleIDs: ["a"]), .addScenario(name: "Имя"), .updateScenario(id: scenarioID),
    .renameScenario(id: scenarioID, name: "Имя"), .deleteScenario(id: scenarioID), .selectScenario(id: scenarioID),
    .refreshUsage,
]

// MARK: - Разбор

@MainActor func wire() {
    allActions.forEach { check(roundTrips($0), "действие туда и обратно: \(String(decoding: encoded($0), as: UTF8.self))") }
    check(allActions.count == 11, "проверены все действия")

    let state = StashState(
        running: [.init(bundleID: "a", name: "А", closing: true)],
        stubborn: [.init(bundleID: "b", name: "Б", closing: false)],
        stashed: [.init(bundleID: "c", name: "В", windowCount: 3)],
        usage: ["a": AppUsage(memoryMB: 2048, cpu: 12), "b": AppUsage(memoryMB: 1, cpu: 0)],
        scenarios: [StashScenario(id: scenarioID, name: "Работа", bundleIDs: ["a", "c"])],
        busy: "Занят",
        report: RestoreReport(restored: 1, windowsPlaced: 2, missing: ["М"], failed: ["Н"], hadAccess: false))
    check(roundTrips(state), "состояние туда и обратно, байты те же")
    let empty = StashState(running: [], stubborn: [], stashed: [], usage: [:], scenarios: [], busy: nil, report: nil)
    check(roundTrips(empty), "пустое состояние туда и обратно")

    func decodes(_ raw: String) -> Bool { (try? JSONDecoder().decode(StashAction.self, from: Data(raw.utf8))) != nil }
    check(!decodes(#"{"explode":{}}"#), "чужое действие не разбирается")
    check(!decodes(#"{"stash":{"bundleIDs":"a"}}"#), "значение не того типа не разбирается")
    check(!decodes(#"{"forceTerminate":{"pid":1}}"#), "pid вместо id не разбирается")
    check(!decodes(#"{"stash":{}}"#), "действие без значения не разбирается")
    let extra = Data(#"{"restore":{},"x":1}"#.utf8)
    check((try? JSONDecoder().decode(StashAction.self, from: extra)).map(encoded) != extra, "чужой ключ рядом виден по сверке с кодированием")
}

@MainActor func stateContents() {
    let frame = 1234.5
    let title = StashedWindow.storedTitle("Секретное письмо")
    let record = StashedApp(bundleID: "test.old", path: "/nonexistent/secret-path.app", name: "Старая",
                            windows: [StashedWindow(title: title, x: frame, y: frame, width: frame, height: frame),
                                      StashedWindow(title: "", x: 0, y: 0, width: 1, height: 1)])
    let defaults = UserDefaults(suiteName: suite)!
    keys.forEach(defaults.removeObject(forKey:))
    defaults.set(try! JSONEncoder().encode([record]), forKey: "StashedApps")
    defaults.set(["test.not-running", "test.b"], forKey: "StashExcludedBundleIDs")

    let world = World()
    world.apps = [FakeApp("test.a", name: "Альфа"), FakeApp("test.b", name: "Бета"), FakeApp("com.apple.finder", name: "Finder")]
    let store = makeStore(world, keep: true)
    let state = store.wireState
    check(state.stashed == [.init(bundleID: "test.old", name: "Старая", windowCount: 2)], "стеш: id, имя и число окон")
    check(state.running.map(\.bundleID) == ["test.a", "test.b"], "Finder в список не попал")
    check(state.running.map(\.closing) == [true, false], "отметка берётся из «не закрывать»")
    let json = String(decoding: encoded(state), as: UTF8.self)
    for (leak, name) in [("secret-path", "путь"), ("/nonexistent", "путь"), (title, "хэш заголовка"), ("1234.5", "кадр окна"), ("test.not-running", "лишний id")] {
        check(!json.contains(leak), "в состоянии нет: \(name) (\(leak.prefix(20)))")
    }
    keys.forEach(defaults.removeObject(forKey:))
}

// MARK: - Проверки действий

@MainActor func validations() async {
    let tempApp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stash-wire-\(getpid()).app")
    try? FileManager.default.createDirectory(at: tempApp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempApp) }

    let world = World()
    let quick = FakeApp("test.quick", name: "Быстрая", url: tempApp)
    let other = FakeApp("test.other", name: "Другая")
    let slow = FakeApp("test.slow", name: "Упрямая", stubborn: true)
    let dying = FakeApp("test.dying", name: "Уже вышла")
    let finder = FakeApp("com.apple.finder", name: "Finder")
    world.apps = [quick, other, slow, dying, finder]
    let store = makeStore(world)
    check(store.running.count == 4, "в списке только поддельные и без Finder: \(store.running.map(\.bundleID))")

    // Отметки
    refused(store, world, .setClosing(bundleID: "test.unknown", closing: false), "setClosing: чужой id")
    refused(store, world, .setClosing(bundleID: "/Applications/Safari.app", closing: false), "setClosing: путь")
    refused(store, world, .setClosing(bundleID: "com.apple.finder", closing: false), "setClosing: Finder")
    refused(store, world, .setClosing(bundleID: String(repeating: "x", count: 100_000), closing: false), "setClosing: огромная строка")
    check(store.handle(.setClosing(bundleID: "test.other", closing: false)) == nil, "setClosing: свой id принят")
    check(store.wireState.running.first { $0.bundleID == "test.other" }?.closing == false, "setClosing: отметка снята")
    check(UserDefaults(suiteName: suite)!.stringArray(forKey: "StashExcludedBundleIDs") == ["test.other"], "setClosing: сохранено в suite")
    check(store.handle(.setClosing(bundleID: "test.other", closing: true)) == nil, "setClosing: отметка возвращена")

    // Закрытие: только названные и только из списка
    refused(store, world, .stash(bundleIDs: []), "stash: пустой список")
    refused(store, world, .stash(bundleIDs: ["test.unknown"]), "stash: чужой id")
    refused(store, world, .stash(bundleIDs: ["test.quick", "test.unknown"]), "stash: свой и чужой вместе")
    refused(store, world, .stash(bundleIDs: ["test.quick", "test.quick"]), "stash: повтор")
    refused(store, world, .stash(bundleIDs: ["/Applications/Safari.app"]), "stash: путь")
    refused(store, world, .stash(bundleIDs: ["1"]), "stash: pid")
    refused(store, world, .stash(bundleIDs: ["com.apple.finder"]), "stash: Finder")
    dying.dead = true
    refused(store, world, .stash(bundleIDs: ["test.dying"]), "stash: программа вышла после списка")
    dying.dead = false

    // Возвращать пока нечего
    refused(store, world, .restore, "restore: стеш пуст")

    // Принудительно — только не закрывшиеся
    refused(store, world, .forceTerminate(bundleIDs: ["test.quick"]), "forceTerminate: запущена, но не из незакрывшихся")

    // Закрытие занимает стеш с первого мгновения
    check(store.handle(.stash(bundleIDs: ["test.quick"])) == nil, "stash: свой id принят")
    check(store.wireState.busy == StashStore.closingText, "stash: занятость видна сразу в ответе")
    refused(store, world, .stash(bundleIDs: ["test.other"]), "stash: второй до начала первого")
    await settle(store)
    check(quick.terminations == 1 && other.terminations == 0 && slow.terminations == 0, "stash: закрыта только названная, отмеченные остальные не тронуты")
    check(store.wireState.busy == nil, "stash: занятость снята")
    check(store.wireState.stashed.map(\.bundleID) == ["test.quick"], "stash: записана")
    check(!store.wireState.running.contains { $0.bundleID == "test.quick" }, "stash: из списка ушла")
    check(UserDefaults(suiteName: suite)!.data(forKey: "StashedApps") != nil, "stash: запись в suite")

    // Упрямая программа: 10 секунд стеш занят
    check(store.handle(.stash(bundleIDs: ["test.slow"])) == nil, "stash упрямой принят")
    await pause(0.3)
    check(store.busy == StashStore.closingText, "идёт закрытие")
    refused(store, world, .stash(bundleIDs: ["test.other"]), "stash: занято")
    refused(store, world, .restore, "restore: занято")
    await settle(store)
    check(store.wireState.stubborn.map(\.bundleID) == ["test.slow"], "упрямая в незакрывшихся")
    check(slow.forced == 0, "принудительно сама не закрывается")

    refused(store, world, .forceTerminate(bundleIDs: []), "forceTerminate: пустой список")
    refused(store, world, .forceTerminate(bundleIDs: ["test.unknown"]), "forceTerminate: чужой id")
    refused(store, world, .forceTerminate(bundleIDs: ["test.other"]), "forceTerminate: закрылась бы чужая для списка")
    refused(store, world, .forceTerminate(bundleIDs: ["test.slow", "test.slow"]), "forceTerminate: повтор")
    refused(store, world, .forceTerminate(bundleIDs: ["test.slow", "test.unknown"]), "forceTerminate: свой и чужой вместе")
    check(slow.forced == 0, "после отказов упрямая жива")
    check(store.handle(.forceTerminate(bundleIDs: ["test.slow"])) == nil && slow.forced == 1 && other.forced == 0, "forceTerminate: только названная")
    check(store.wireState.stubborn.isEmpty, "незакрывшихся не осталось")

    // Возврат: путь из записи, никаких путей из связи; пропавшая на диске не запускается
    check(store.handle(.restore) == nil, "restore принят")
    check(store.wireState.busy == StashStore.restoringText, "restore: занятость видна сразу")
    refused(store, world, .restore, "restore: второй до начала первого")
    refused(store, world, .stash(bundleIDs: ["test.other"]), "stash во время возврата")
    await settle(store)
    check(world.opened.map(\.path) == [tempApp.path], "restore: запущена только программа с диска")
    check(world.activates == [false], "restore: без вывода вперёд")
    check(store.wireState.report?.restored == 1 && store.wireState.report?.missing == ["Упрямая"], "restore: отчёт \(String(describing: store.wireState.report))")
    check(store.wireState.stashed.isEmpty && UserDefaults(suiteName: suite)!.data(forKey: "StashedApps") == nil, "restore: запись убрана")
    refused(store, world, .restore, "restore: снова пусто")

    // Сценарии
    let selectedNow = store.selectedBundleIDs
    check(!selectedNow.isEmpty, "что-то отмечено")
    for (bad, name) in [("", "пустое"), ("  \n ", "из пробелов"), (String(repeating: "я", count: 101), "101 символ"), ("а\u{07}б", "управляющий символ"), ("а\nб", "перевод строки внутри")] {
        refused(store, world, .addScenario(name: bad), "addScenario: \(name)")
    }
    check(store.handle(.addScenario(name: "  Работа \n")) == nil, "addScenario: принят")
    check(store.scenarios.map(\.name) == ["Работа"] && store.scenarios[0].bundleIDs == selectedNow, "addScenario: без краевых пробелов, из выбранных")
    let id = store.scenarios[0].id
    check(store.handle(.addScenario(name: String(repeating: "я", count: 100))) == nil, "addScenario: 100 символов принято")

    for (bad, name) in [("", "пустое"), (String(repeating: "я", count: 101), "101 символ"), ("а\u{07}б", "управляющий символ")] {
        refused(store, world, .renameScenario(id: id, name: bad), "renameScenario: \(name)")
    }
    refused(store, world, .renameScenario(id: unknownID, name: "Имя"), "renameScenario: чужой id")
    check(store.handle(.renameScenario(id: id, name: "Отдых")) == nil && store.scenarios[0].name == "Отдых", "renameScenario: принят")
    refused(store, world, .updateScenario(id: unknownID), "updateScenario: чужой id")
    refused(store, world, .selectScenario(id: unknownID), "selectScenario: чужой id")
    refused(store, world, .deleteScenario(id: unknownID), "deleteScenario: чужой id")

    // Сценарий ставит отметки на свои программы, остальные снимает
    store.setClosing("test.other", false)
    check(store.handle(.selectScenario(id: id)) == nil, "selectScenario: принят")
    check(store.isClosing("test.other") == store.scenarios[0].bundleIDs.contains("test.other"), "selectScenario: отметка как в сценарии")

    // Ничего не отмечено
    store.running.forEach { store.setClosing($0.bundleID, false) }
    refused(store, world, .addScenario(name: "Имя"), "addScenario: ничего не отмечено")
    refused(store, world, .updateScenario(id: id), "updateScenario: ничего не отмечено")
    store.setClosing("test.other", true)
    check(store.handle(.updateScenario(id: id)) == nil && store.scenarios[0].bundleIDs == ["test.other"], "updateScenario: принят")

    // Лимит числа сценариев
    while store.scenarios.count < StashStore.maxScenarios { store.addScenario(name: "x") }
    refused(store, world, .addScenario(name: "сверх лимита"), "addScenario: слишком много")
    check(store.handle(.deleteScenario(id: id)) == nil && !store.scenarios.contains { $0.id == id }, "deleteScenario: принят")

    check(store.handle(.selectOnlyHeavy) == nil && store.selectedBundleIDs.isEmpty, "selectOnlyHeavy: замеров нет, тяжёлых нет")
    keys.forEach(UserDefaults(suiteName: suite)!.removeObject(forKey:))
}

/// Проверка сама лежит внутри папки .app: это единственная программа, у которой есть что замерить.
@MainActor func usageRefresh() async {
    let path = CommandLine.arguments[0]
    let parts = path.components(separatedBy: "/Contents/MacOS/")
    check(parts.count == 2 && parts[0].hasSuffix(".app") && path.hasPrefix("/"), "проверка запущена из папки .app: \(path)")
    let world = World()
    world.apps = [FakeApp("test.self", url: URL(fileURLWithPath: parts[0]))]
    let store = makeStore(world)

    await store.refreshUsage()
    check(store.usage.isEmpty, "встроенный путь: окна нет, ps не запускается")
    check(store.handle(.refreshUsage) == nil && store.usagePending, "связь: замер пошёл")
    check(store.handle(.refreshUsage) == nil && store.usagePending, "связь: второй замер на первый не наслаивается")
    let deadline = Date().addingTimeInterval(10)
    while store.usagePending, Date() < deadline { await pause(0.05) }
    check(!store.usagePending && (store.usage["test.self"]?.memoryMB ?? 0) > 0, "связь: замер не зависит от окна утилиты: \(String(describing: store.usage["test.self"]))")
    check(store.wireState.usage == store.usage, "замер виден в состоянии")
    keys.forEach(UserDefaults(suiteName: suite)!.removeObject(forKey:))
}

// MARK: - Экран

#if !STASH_NO_SCREEN

/// Модель без работы, только из состояния, пришедшего по связи.
@MainActor final class FakeStashModel: StashModel {
    let state: StashState
    let icons: (String) -> NSImage?
    let stashedIcons: (String) -> NSImage?

    init(state: StashState, icons: @escaping (String) -> NSImage?, stashedIcons: @escaping (String) -> NSImage?) {
        self.state = state
        self.icons = icons
        self.stashedIcons = stashedIcons
    }

    private func program(_ item: StashState.Program) -> StashProgram {
        StashProgram(bundleID: item.bundleID, name: item.name, icon: icons(item.bundleID))
    }
    var runningPrograms: [StashProgram] { state.running.map(program) }
    var stubbornPrograms: [StashProgram] { state.stubborn.map(program) }
    var stashedPrograms: [StashProgram] {
        state.stashed.map { StashProgram(bundleID: $0.bundleID, name: $0.name, icon: stashedIcons($0.bundleID), windowCount: $0.windowCount) }
    }
    var usage: [String: AppUsage] { state.usage }
    var scenarios: [StashScenario] { state.scenarios }
    var busy: String? { state.busy }
    var report: RestoreReport? { state.report }
    var selectedBundleIDs: [String] { state.running.filter(\.closing).map(\.bundleID) }
    var selectedNames: [String] { state.running.filter(\.closing).map(\.name) }
    func isClosing(_ bundleID: String) -> Bool { state.running.first { $0.bundleID == bundleID }?.closing ?? true }
    func icon(forBundleID id: String) -> NSImage? { icons(id) }

    func start() {}
    func refreshAccess() {}
    func refreshUsage() async {}
    func setClosing(_ bundleID: String, _ closing: Bool) {}
    func selectOnlyHeavy() {}
    func stashSelected() async {}
    func stash(_ scenario: StashScenario) async {}
    func restore() async {}
    func forceTerminate(_ bundleID: String) {}
    func forceTerminateAll() {}
    func addScenario(name: String) -> Bool { false }
    func updateScenario(_ id: UUID) {}
    func renameScenario(_ id: UUID, to name: String) {}
    func deleteScenario(_ id: UUID) {}
    func select(_ scenario: StashScenario) {}
}

/// Прежний `runningByWeight`: нужен прежнему экрану, в модуле он теперь у модели.
extension StashStore {
    var runningByWeight: [RunningEntry] {
        running.sorted { (usage[$0.bundleID]?.memoryMB ?? 0) > (usage[$1.bundleID]?.memoryMB ?? 0) }
    }
}

@MainActor enum Stand {
    static let size = NSSize(width: 738, height: 1400)
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    /// `pageActive = false`: `start()` и замеры `.task` подменили бы подготовленные данные.
    static func shot(_ view: some View, theme: DSTheme) async -> NSBitmapImageRep {
        let root = view
            .environment(\.pageActive, false)
            .environment(\.dsTint, theme.accent(.stash))
            .background(ZStack { Color.black; theme.card })
            .dsThemed()
            .ignoresSafeArea()
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        await pause(0.4)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}

func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData else {
        return max(a.pixelsWide * a.pixelsHigh, b.pixelsWide * b.pixelsHigh)
    }
    let pixelBytes = a.bitsPerPixel / 8
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            let offset = y * a.bytesPerRow + x * pixelBytes
            if memcmp(pa + offset, pb + offset, pixelBytes) != 0 { count += 1 }
        }
    }
    return count
}

func icon(_ hue: Double) -> NSImage {
    NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        return true
    }
}

/// Сцена: заполняет стеш напрямую. Исходник стеша в сборке проверки — копия без `private(set)`.
@MainActor func seed(_ store: StashStore, _ scene: String) {
    func entry(_ i: Int, _ name: String) -> RunningEntry {
        let id = "test.app\(i)"
        let image = icon(Double(i % 12) / 12)
        return RunningEntry(app: FakeApp(id, name: name, icon: image), bundleID: id, name: name, icon: image)
    }
    func record(_ i: Int, _ name: String, windows: Int) -> StashedApp {
        StashedApp(bundleID: "test.stashed\(i)", path: "/nonexistent/stashed\(i).app", name: name,
                   windows: (0..<windows).map { StashedWindow(title: "h\($0)", x: 0, y: 0, width: 100, height: 100) })
    }
    let names = ["Браузер", "Почта", "Терминал", "Заметки", "Плеер"]
    store.running = []
    store.usage = [:]
    store.excluded = []
    store.stashed = []
    store.stubborn = []
    store.scenarios = []
    store.busy = nil
    store.report = nil
    switch scene {
    case "empty":
        break
    case "main":
        store.running = names.enumerated().map { entry($0.offset, $0.element) }
        store.usage = ["test.app0": AppUsage(memoryMB: 3072, cpu: 40), "test.app1": AppUsage(memoryMB: 512, cpu: 3),
                       "test.app2": AppUsage(memoryMB: 80, cpu: 30), "test.app3": AppUsage(memoryMB: 80, cpu: 1)]
        store.excluded = ["test.app1", "test.app9"]
        store.scenarios = [
            StashScenario(id: scenarioID, name: "Работа", bundleIDs: ["test.app0", "test.app1"]),
            StashScenario(id: unknownID, name: "Много программ с длинным названием",
                          bundleIDs: ["test.app0", "test.app2", "test.app3", "test.app4", "test.none1", "test.none2", "test.none3"]),
        ]
    case "all":
        store.running = names.prefix(3).enumerated().map { entry($0.offset, $0.element) }
        store.stashed = [record(0, "Фигма", windows: 3), record(1, "Слак", windows: 1), record(2, "Музыка", windows: 0)]
        store.stubborn = [entry(7, "Упрямая"), entry(8, "Вторая упрямая")]
        store.report = RestoreReport(restored: 2, windowsPlaced: 5, missing: ["Нет на диске"], failed: ["Не открылась"], hadAccess: true)
        store.busy = "Возвращаю программы…"
    case "noaccess":
        store.stashed = [record(0, "Одна", windows: 0)]
        store.report = RestoreReport(restored: 1, windowsPlaced: 0, hadAccess: false)
    case "long":
        store.running = (0..<20).map { entry($0, "Программа \($0)") }
        store.usage = Dictionary(uniqueKeysWithValues: (0..<20).map { ("test.app\($0)", AppUsage(memoryMB: Double(20 - $0) * 100, cpu: Double($0))) })
    case "long-stashed":
        store.running = (0..<20).map { entry($0, "Программа \($0)") }
        store.stashed = [record(0, "Одна", windows: 2)]
    default:
        fatalError(scene)
    }
}

@MainActor func screen(out: String) async {
    let world = World()
    let store = makeStore(world)
    let themes: [(String, DSTheme)] = [("dusk", .dusk), ("calm", .calm)]
    let scenes = ["empty", "main", "all", "noaccess", "long", "long-stashed"]
    let kit = Kit.defaults
    for (themeName, theme) in themes {
        kit.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for scene in scenes {
            seed(store, scene)
            // Состояние проходит через JSON, как по связи.
            let state = try! JSONDecoder().decode(StashState.self, from: encoded(store.wireState))
            let fake = FakeStashModel(state: state, icons: { id in
                store.running.first { $0.bundleID == id }?.icon ?? store.stubborn.first { $0.bundleID == id }?.icon
            }, stashedIcons: { id in
                store.stashed.first { $0.bundleID == id }.map { store.icon(forPath: $0.path) }
            })

            let before = await Stand.shot(LegacyStashView(store: store), theme: theme)
            let after = await Stand.shot(StashView(store: store), theme: theme)
            let remote = await Stand.shot(StashView(store: fake), theme: theme)
            let total = before.pixelsWide * before.pixelsHigh
            let diff = differingPixels(before, after)
            check(diff == 0, "\(themeName) \(scene): экран до и после, разных пикселей \(diff) из \(total)")
            let fakeDiff = differingPixels(after, remote)
            check(fakeDiff == 0, "\(themeName) \(scene): поддельная модель из состояния, разных пикселей \(fakeDiff) из \(total)")
            try? after.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(out)/png/\(themeName)-\(scene).png"))
            shots.append(after)
        }
        for i in shots.indices.dropLast() {
            check(differingPixels(shots[i], shots[i + 1]) > 0, "\(themeName): \(scenes[i]) и \(scenes[i + 1]) различаются, снимки не пустые")
        }
    }
    seed(store, "empty")
    kit.removeObject(forKey: DSTheme.storageKey)
    keys.forEach(UserDefaults(suiteName: suite)!.removeObject(forKey:))
}
#endif

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            wire()
            stateContents()
            await usageRefresh()
            await validations()
            #if !STASH_NO_SCREEN
            await screen(out: CommandLine.arguments[1])
            #endif
            print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
