import AppKit
import Combine
import SwiftUI

// Набор модулей дев-сборки на стенде за экраном: что видно и что осталось нетронутым в настройках.
// Запуск: Tests/run-dev-scope-check.sh. Аргументы: рабочая папка, папка PNG, ожидаемый набор (`awake,load`, пусто или `*`),
// шаг: `seed` (записать настройки), `scoped` (суженная сборка), `model` (она же без окон), `plain` (обычная сборка на тех же настройках).
// Стенд настроек не чистит между запусками: обычная сборка должна увидеть ровно то, что было до дев-сборки.

let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let pngDir = URL(fileURLWithPath: CommandLine.arguments[2])
let expectedArg = CommandLine.arguments[3]
let stepName = CommandLine.arguments[4]

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

/// Модуль вне набора в настройках стенда: у каждого есть порядок, закрепление, скрытие, включённость и передача утилите.
let arranged: [Module] = Module.allCases.reversed()
let pinned: Set<Module> = [.sound, .mixer, .awake]
let hiddenOnes: Set<Module> = [.fans, .load]
let builtIn: Set<Module> = [.mixer, .awake, .load]

/// Всё, что не должно меняться: порядок, выбранный модуль, значки, скрытые, включённость, передача утилите.
func guardedSettings(_ defaults: UserDefaults) -> [String: String] {
    let prefixes = ["ModuleOrder", "SelectedModule", "ModuleOn.", "ModuleHidden.", "MenuBarIcon.", "App.", "ModuleMigration."]
    var result: [String: String] = [:]
    for (key, value) in defaults.dictionaryRepresentation() where prefixes.contains(where: { key.hasPrefix($0) }) {
        result[key] = "\(value)"
    }
    return result
}

@MainActor func seed() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: "ModulesV2")
    defaults.set(true, forKey: "ModulesV3")
    defaults.set(true, forKey: "Welcome.Seen.v1")
    defaults.set(arranged.map(\.rawValue), forKey: "ModuleOrder")
    defaults.set(Module.sound.rawValue, forKey: "SelectedModule")
    defaults.set(true, forKey: ModuleReset.flagKey)
    for module in Module.allCases {
        defaults.set(true, forKey: ModuleManager.onKey(module))
        defaults.set(hiddenOnes.contains(module), forKey: "ModuleHidden.\(module.rawValue)")
        if !builtIn.contains(module) { defaults.set(true, forKey: ModuleHandover.handedOverKey(module.rawValue)) }
        if pinned.contains(module) { Kit.defaults.set(true, forKey: MenuBarIcon.key(module)) }
    }
    defaults.synchronize()
    Kit.defaults.synchronize()
}

/// Бандлы всех утилит в папке стенда: опрос видит их установленными, каталог предлагает обновление всем.
func installBundles(_ apps: URL) {
    for module in Module.allCases {
        let contents = apps.appendingPathComponent(SatelliteRegistry.bundleName(module) + ".app/Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        (["CFBundleShortVersionString": "1.1.0"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }
}

func catalogAll() -> Data {
    let apps = Module.allCases.map { module -> [String: Any] in
        ["id": module.rawValue, "version": "9.9.9", "minHub": "0.6.0", "url": "https://example.com/\(module.rawValue).zip",
         "sha256": String(repeating: "0", count: 64), "sizeMB": 2]
    }
    return try! JSONSerialization.data(withJSONObject: ["schema": 1, "apps": apps])
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
let calls = Calls()

/// Статус: утилиты вне встроенных отвечают, у встроенных связи нет.
@MainActor func setEnvironment(apps: URL) {
    let paths = SatellitePaths(appsDir: apps, agentsDir: workRoot.appendingPathComponent("Agents"))
    SatelliteRegistry.standEnvironment = SatelliteEnvironment(
        paths: paths, defaults: .standard,
        installer: SatelliteInstaller(paths: paths, launchctl: { calls.add("launchctl \($0.first ?? "")") }, download: { $0 }, verify: { _, _ in }),
        commands: SatelliteCommands(
            status: { id in
                guard let module = Module(rawValue: id), !builtIn.contains(module) else { throw LinkError.timeout }
                return LinkStatus(enabled: true, line: id, needsSetup: 0, quickActions: [LinkQuickAction(title: "действие", icon: "bolt", action: Data())])
            },
            setEnabled: { id, on in calls.add("setEnabled \(id) \(on)") },
            openWindow: { id in calls.add("openWindow \(id)") }),
        loadCatalog: { catalogAll() },
        hubVersion: "0.6.0", modules: .shared)
}

#if KIT_TEST_DEFAULTS
/// Настоящая модель говорила бы с настоящей утилитой: у стенда модель без связи.
final class SilentModel: RemoteModuleSurface {
    var responding: Bool { true }
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func refresh() {}
    func dashboardState(base: DashState, status: LinkStatus?) -> DashState { base }
    func performDashboardAction() -> Bool { false }
    func performDashboardAction(ask: (DashConfirmation) -> Void) -> Bool { false }
    func setDashboardVisible(_ visible: Bool) {}
    var menuUsesQuickActions: Bool { true }
}
#endif

// MARK: - Текст на экране

/// Весь текст вида, как его видит доступность. Спрашивается у самого вида в своём процессе: разрешений не нужно.
@MainActor func texts(_ element: Any, depth: Int = 0, into out: inout [String]) {
    guard depth < 40, let node = element as? NSAccessibilityElementProtocol as? NSObject else { return }
    if let label = node.value(forKey: "accessibilityLabel") as? String, !label.isEmpty { out.append(label) }
    if let value = node.value(forKey: "accessibilityValue") as? String, !value.isEmpty { out.append(value) }
    for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { texts(child, depth: depth + 1, into: &out) }
}

@MainActor func render<V: View>(_ name: String, height: CGFloat = 900, _ view: V) async -> String {
    let root = ZStack { DSBackground(module: .mixer, neutral: true); view }
        .environment(\.moduleControls, DSModuleControls.forEnvironment)
        .dsThemed()
        .frame(width: 1000, height: height)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    await pause(1.2)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: pngDir.appendingPathComponent(name + ".png"))
    var found: [String] = []
    texts(host, into: &found)
    window.orderOut(nil)
    window.contentView = nil
    return found.joined(separator: "\n")
}

/// Какие модули упомянуты в тексте страницы: по названию на экране.
func mentioned(_ text: String) -> Set<Module> {
    Set(Module.allCases.filter { text.contains($0.title) })
}

// MARK: - Сценарии

@MainActor func common(expected: [Module], label: String) async {
    let modules = ModuleManager.shared
    let icons = ModuleMenuIcons.shared
    let registry = SatelliteRegistry.shared
    let want = Set(expected)
    let before = guardedSettings(.standard)
    let beforeKit = guardedSettings(Kit.defaults)
    icons.makeItem = { _ in nil }
    var told: [String] = []
    icons.tellUtility = { module, on in told.append("\(module.rawValue) \(on)") }

    print("== \(label): что показано")
    // Запуск как у центра: значки, панель, опрос всех утилит и каталога.
    icons.start()
    SidebarModel.shared.start()
    registry.start()
    await registry.update()
    await pause(0.2)

    check(Set(modules.order) == want, "order: только набор, \(modules.order.map(\.rawValue))")
    check(modules.order == arranged.filter(want.contains), "порядок показанных взят из настроек")
    let layout = SidebarModel.shared.layout()
    check(Set(layout.flattened) == want, "панель: закреплённые, список и скрытые только из набора")
    check(Set(layout.pinned) == pinned.intersection(want), "закреплённые: \(layout.pinned.map(\.rawValue))")
    check(Set(layout.hidden) == hiddenOnes.intersection(want).subtracting(pinned), "«Скрытые»: \(layout.hidden.map(\.rawValue))")
    check(Set(modules.panelModules).isSubset(of: want), "дашборд идёт по panelModules: только набор")
    check(Set(modules.installedModules) == want, "установленные в панели: только набор")
    check(Set(modules.hiddenModules) == hiddenOnes.intersection(want), "hiddenModules: только набор")
    check(Set(UpdateAll.shared.rows.map(\.module)) == want, "обновления: только набор, \(UpdateAll.shared.rows.map(\.module.rawValue))")
    check(Set(UpdateAll.shared.startable) == want, "«Обновить всё»: только набор")
    check(Set(StoreModel.shared.buildModules) == want, "полоса Стора: только набор")
    check(icons.wanted == want.intersection(pinned).intersection(builtIn), "значки центра: только набор, \(icons.wanted.map(\.rawValue))")
    check(icons.waitingForUpdate.allSatisfy(want.contains), "тихая строка о значках: только набор")
    #if KIT_TEST_DEFAULTS
    // Модель в `sections` своя: настоящие говорили бы с настоящими утилитами, поэтому обычная сборка это не считает.
    let sections = MenuQuickActions.sections(order: modules.order, modules: modules, entries: registry.entries)
    let quick = Set(want.filter { !builtIn.contains($0) })
    check(Set(sections.map(\.module)) == quick, "быстрые действия в меню: только набор, \(sections.map(\.module.rawValue))")
    #endif
    if let first = modules.firstInPanel { check(want.contains(first), "первый в панели из набора") }
    check(modules.resolve(.sound).map(want.contains) ?? want.isEmpty, "выбранный модуль вне набора уступает первому из набора")
    if want.isEmpty { check(modules.firstInPanel == nil, "пустой набор: открывать нечего") }

    print("== \(label): вне набора всё работает как работало")
    let outside = Module.allCases.filter { !want.contains($0) }
    check(outside.allSatisfy(modules.isInstalled), "вне набора модули остаются установленными")
    check(outside.filter { !builtIn.contains($0) }.allSatisfy(modules.isExternal), "вне набора утилиты остаются внешними")
    check(outside.filter { !builtIn.contains($0) }.allSatisfy { registry.entries[$0]?.status != nil }, "опрос ходит и к утилитам вне набора")
    check(outside.filter(builtIn.contains).allSatisfy(modules.runsBuiltIn), "вне набора встроенные остаются включёнными")
    check(outside.filter(hiddenOnes.contains).allSatisfy(modules.isHidden), "скрытые вне набора остаются скрытыми")
    check(calls.all.isEmpty, "утилитам ничего не сказано: \(calls.all)")
    check(told.isEmpty, "значки утилит не трогались: \(told)")

    print("== \(label): запуск и выход встроенных не зависят от набора")
    var started: [Module] = [], stopped: [Module] = []
    let suite = "local.utilitumus.test.kit.dev-scope.hooks"
    let own = UserDefaults(suiteName: suite)!
    own.removePersistentDomain(forName: suite)
    own.set(true, forKey: "ModulesV2"); own.set(true, forKey: "ModulesV3"); own.set(true, forKey: ModuleReset.flagKey)
    for module in Module.allCases { own.set(true, forKey: ModuleManager.onKey(module)) }
    let manager = ModuleManager(defaults: own) { module in
        ModuleHooks(start: { started.append(module) }, stop: { stopped.append(module) })
    }
    manager.startEnabled()
    check(Set(started) == Set(Module.allCases), "стартуют все включённые, не только набор")
    check(Set(manager.enabled) == Set(Module.allCases), "enabled настоящий")
    manager.stopAll()
    check(Set(stopped) == Set(Module.allCases), "останавливаются все")
    own.removePersistentDomain(forName: suite)

    print("== \(label): настройки после запуска")
    check(guardedSettings(.standard) == before, "настройки центра не изменились: \(difference(before, guardedSettings(.standard)))")
    check(guardedSettings(Kit.defaults) == beforeKit, "настройки Kit не изменились: \(difference(beforeKit, guardedSettings(Kit.defaults)))")
}

func difference(_ a: [String: String], _ b: [String: String]) -> [String] {
    Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
}

#if KIT_DEV_SCOPE
@MainActor func scoped(expected: [Module], isAll: Bool, label: String) async {
    let want = Set(expected)
    let before = guardedSettings(.standard)
    for module in Module.allCases where want.contains(module) && builtIn.contains(module) {
        DashboardLive.testBuiltIn[module] = DashState(text: "стенд")
    }
    await common(expected: expected, label: label)
    // Дальше настоящие виды: без фильтра они открыли бы экраны утилит вне набора и пошли бы к настоящим утилитам.
    guard failures == 0, stepName != "model" else { return }

    print("== \(label): разбор строки")
    let mark = "local.utilitumus.dev-" + "scope"
    check(ModuleScope.parse(mark + "=mixer,load") == ["mixer", "load"], "список")
    check(ModuleScope.parse(mark + "=") == [], "пусто: ни одного")
    check(ModuleScope.parse(mark + "=*") == nil, "звёздочка: все")
    check(ModuleScope.parse(mark) == [], "без знака равенства ничего не показывает")

    print("== \(label): страницы")
    let about = await render("\(label)-about", AboutView { _ in })
    let store = await render("\(label)-store", StoreView())
    print("     текст О проекте: \(about.count) знаков, Стор: \(store.count) знаков")
    check(about.contains("О проекте"), "«О проекте» читается")
    check(store.contains("Стор"), "Стор читается")
    let visible = mentioned(about)
    check(visible.subtracting(want).isEmpty, "«О проекте» без чужих: \(visible.subtracting(want).map(\.rawValue))")
    check(want.isSubset(of: visible), "«О проекте» со всеми из набора: \(want.subtracting(visible).map(\.rawValue))")
    check(about.contains("Модулей: \(want.count),"), "счётчик «О проекте»: \(want.count)")
    let shelves = mentioned(store)
    check(shelves.subtracting(want).isEmpty, "Стор без чужих: \(shelves.subtracting(want).map(\.rawValue))")
    check(want.isSubset(of: shelves), "Стор со всеми из набора: \(want.subtracting(shelves).map(\.rawValue))")
    check(isAll || !store.contains("Скоро"), "плитки «скоро» только когда видно всё")
    if want.isEmpty {
        check(store.contains("только центр"), "пустой набор: Стор объясняет, а не пустует")
        check(ModuleScope.emptyNote != nil, "есть подпись для панели")
    }

    // При «все» окно открыло бы экран утилиты, а настоящая модель говорит с настоящей утилитой.
    if !isAll {
        print("== \(label): главное окно")
        let main = await render("\(label)-main", MainView())
        let sidebar = mentioned(main)
        check(sidebar.subtracting(want).isEmpty, "главное окно без чужих: \(sidebar.subtracting(want).map(\.rawValue))")
        check(want.isSubset(of: sidebar), "главное окно со всеми из набора: \(want.subtracting(sidebar).map(\.rawValue))")
        check(guardedSettings(.standard) == before, "главное окно ничего не записало: \(difference(before, guardedSettings(.standard)))")
        check(UserDefaults.standard.string(forKey: "SelectedModule") == Module.sound.rawValue, "SelectedModule остался прежним")
        if want.isEmpty { check(main.contains("только центр"), "пустой набор: окно объясняет, а не пустует") }
    }

    if !want.isEmpty, !isAll {
        print("== \(label): перенос в панели не двигает тех, кто вне набора")
        let moved = expected[0]
        let full = (UserDefaults.standard.stringArray(forKey: "ModuleOrder") ?? []).compactMap(Module.init(rawValue:))
        SidebarModel.shared.nudge(moved, by: 1)
        SidebarModel.shared.send(moved, to: .list)
        let after = (UserDefaults.standard.stringArray(forKey: "ModuleOrder") ?? full.map(\.rawValue)).compactMap(Module.init(rawValue:))
        check(Set(after) == Set(Module.allCases), "в порядке по-прежнему все модули")
        check(zip(full, after).allSatisfy { want.contains($0) || $0 == $1 }, "модули вне набора на своих местах: \(after.map(\.rawValue))")
        check(zip(full, after).allSatisfy { !want.contains($0) || want.contains($1) }, "модули набора меняются местами только между собой")
    }
    // Перенос выше менял настройки нарочно, а до него сверка прошла: следующий запуск начинает с исходных.
    seed()
}
#endif

/// Обычная сборка на настройках после дев-сборки: всё на месте.
@MainActor func plain() async {
    let modules = ModuleManager.shared
    await common(expected: Module.allCases, label: "обычная сборка")
    check(modules.order == arranged, "порядок тот, что был")
    check(SidebarModel.shared.layout().flattened.count == Module.allCases.count, "в панели снова все модули")
    check(UserDefaults.standard.string(forKey: "SelectedModule") == Module.sound.rawValue, "SelectedModule прежний")
    check(ModuleScope.categories == ModuleCategory.all, "все категории")
    check(ModuleScope.emptyNote == nil, "подписи о пустой сборке нет")
    check(ModuleScope.showsSoon, "плитки «скоро» есть")
    print("== настройки на месте: \(guardedSettings(.standard).count) ключей")
}

@MainActor func run() async {
    let apps = workRoot.appendingPathComponent("Apps")
    try? FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    installBundles(apps)
    if stepName == "seed" {
        seed()
        return
    }
    setEnvironment(apps: apps)
    #if KIT_TEST_DEFAULTS
    for module in Module.allCases { RemoteModules.testModels[module] = SilentModel() }
    #endif
    switch stepName {
    case "plain":
        await plain()
    default:
        #if KIT_DEV_SCOPE
        let isAll = expectedArg == "*"
        let ids = isAll ? Module.allCases.map(\.rawValue) : expectedArg.split(separator: ",").map(String.init)
        await scoped(expected: Module.allCases.filter { ids.contains($0.rawValue) }, isAll: isAll, label: isAll ? "all" : (ids.isEmpty ? "hub" : ids.joined(separator: "-")))
        #else
        check(false, "шаг \(stepName) только для сборки с набором")
        #endif
    }
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
