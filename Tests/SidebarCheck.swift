import AppKit
import Combine
import SwiftUI

// Боковая панель: чистая раскладка (зоны, переносы, сетка плиток), настройки и переход со старого вида,
// снимки панели в двух темах. Запуск: Tests/run-sidebar-check.sh. Аргументы: рабочая папка, папка PNG.

let pngDir = URL(fileURLWithPath: CommandLine.arguments[2])
nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

// MARK: - Снимки

struct Harness: View {
    @State private var dashboard = false
    @State private var store = false
    @State private var about = false
    @State private var peeked: Module?
    @State private var selection = Module.fans

    var body: some View {
        HStack(spacing: 0) {
            DSSidebar(current: selection, showDashboard: $dashboard, showStore: $store, showAbout: $about,
                      peeked: $peeked, selection: $selection)
                .frame(width: DS.sidebarWidth)
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).fill(Color.black.opacity(0.3))
                .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 10))
        }
    }
}

@MainActor func snapshot(_ name: String, theme: DSTheme, width: CGFloat = 980, height: CGFloat = 680) async -> NSBitmapImageRep {
    Kit.defaults.set(theme.rawValue, forKey: DSTheme.storageKey)
    let root = ZStack { DSBackground(module: .fans, neutral: false); Harness() }
        .environment(\.dsTint, theme.accent(.fans))
        .dsThemed()
        .frame(width: width, height: height)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    await pause(0.6)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: pngDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    window.contentView = nil
    print("png  \(name)")
    return rep
}

func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let x = a.bitmapData, let y = b.bitmapData else { return Int.max }
    var count = 0
    for i in 0..<(a.pixelsWide * a.pixelsHigh) where memcmp(x + i * 4, y + i * 4, 4) != 0 { count += 1 }
    return count
}

/// Пиксели правее панели (область страницы) в двух снимках.
func differingInPage(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let x = a.bitmapData, let y = b.bitmapData else { return Int.max }
    let scale = a.pixelsWide / 980
    var count = 0
    for row in 0..<a.pixelsHigh {
        for col in Int(DS.sidebarWidth) * scale..<a.pixelsWide {
            let i = row * a.pixelsWide + col
            if memcmp(x + i * 4, y + i * 4, 4) != 0 { count += 1 }
        }
    }
    return count
}

// MARK: - Чистая раскладка

func pure() {
    print("== раскладка: зоны и переносы")
    let all = Module.allCases
    let layout = SidebarLayout.resolve(order: all, present: Set(all), pins: [.fans, .sound], hidden: [.mouse, .fans])
    check(layout.pinned == [.sound, .fans].sorted { all.firstIndex(of: $0)! < all.firstIndex(of: $1)! }, "закреплённые идут в общем порядке")
    check(layout.hidden == [.mouse], "скрытый, но закреплённый — в закреплённых (закрепление сильнее)")
    check(layout.list.count == all.count - 3 && !layout.list.contains(.mouse), "в списке остальные")
    let absent = SidebarLayout.resolve(order: all, present: [.sound], pins: [.fans], hidden: [])
    check(absent.flattened == [.sound], "модуль, которого нет среди установленных, в раскладку не входит, вместе с закреплением")

    var l = SidebarLayout(pinned: [.sound], list: [.fans, .load, .stash], hidden: [.mouse])
    check(l.move(.stash, to: .list, at: 0) && l.list == [.stash, .fans, .load], "внутри зоны: на первое место")
    check(l.move(.stash, to: .list, at: 99) && l.list == [.fans, .load, .stash], "индекс за краем — в конец")
    check(l.move(.load, to: .pinned, at: 0) && l.pinned == [.load, .sound] && l.list == [.fans, .stash], "список -> закреплённые, между соседями")
    check(l.move(.sound, to: .hidden, at: 1) && l.hidden == [.mouse, .sound] && l.pinned == [.load], "закреплённые -> скрытые")
    check(l.move(.mouse, to: .list, at: 1) && l.list == [.fans, .mouse, .stash] && l.hidden == [.sound], "скрытые -> список")
    check(l.move(.fans, to: .list, at: -5) && l.list.first == .fans, "отрицательный индекс — в начало")
    check(l.nudge(.mouse, by: 1) && l.list == [.fans, .stash, .mouse], "⌘⌥↓ сдвигает на одно место")
    check(!l.nudge(.mouse, by: 1), "на краю сдвигать некуда")
    check(l.nudge(.mouse, by: -1) && l.list == [.fans, .mouse, .stash], "⌘⌥↑")
    let before = l
    check(!l.move(.awake, to: .list, at: 0) && l == before, "модуль не из раскладки — отказ без изменений")
    check(l.mergedOrder([.awake, .sound]) == l.flattened + [.awake], "общий порядок: зоны подряд, не установленные следом")

    print("== не больше девяти закреплённых")
    var full = SidebarLayout(pinned: Array(all.prefix(9)), list: Array(all.suffix(2)))
    let snapshot = full
    check(!full.canMove(all[10], to: .pinned) && !full.move(all[10], to: .pinned, at: 0) && full == snapshot, "десятый отклонён, раскладка прежняя")
    check(full.move(all[0], to: .pinned, at: 8) && full.pinned.last == all[0], "переставлять среди девяти можно")
    check(SidebarLayout.resolve(order: all, present: Set(all), pins: Set(all), hidden: []).pinned.count == 9, "из десяти закреплённых настроек в плитки идут девять")
    check(!SidebarLayout(pinned: Array(all.prefix(6))).showsNotchHint && SidebarLayout(pinned: Array(all.prefix(7))).showsNotchHint,
          "подсказка про вырез — с семи значков")

    print("== сетка плиток")
    let width: CGFloat = DS.sidebarWidth - 20
    let expectedColumns = [1: 1, 2: 2, 3: 3, 4: 4, 5: 3, 6: 3, 7: 4, 8: 4, 9: 3]
    for n in 1...9 {
        let frames = SidebarMetrics.pinnedFrames(count: n, width: width)
        let cols = expectedColumns[n]!
        check(SidebarMetrics.columns(n) == cols, "\(n) плиток: \(cols) столбца(ов)")
        check(frames.count == n && Set(frames.map(\.width)).count == 1 && frames.allSatisfy { $0.height == SidebarMetrics.tileHeight },
              "\(n): плитки одного размера, высота постоянна")
        check(frames.map(\.maxX).max()! <= width + 0.001 && abs(frames[0].width * CGFloat(min(n, cols)) + SidebarMetrics.tileGap * CGFloat(min(n, cols) - 1) - frames.prefix(cols).last!.maxX) < 0.01,
              "\(n): строка занимает всю ширину")
        check(frames.enumerated().allSatisfy { i, f in abs(f.minX - CGFloat(i % cols) * (f.width + SidebarMetrics.tileGap)) < 0.01 }, "\(n): неполная строка прижата влево")
        for i in 0..<n { for j in (i + 1)..<max(n, i + 1) { check(!frames[i].intersects(frames[j]), "\(n): плитки \(i) и \(j) не пересекаются") } }
    }
    check(SidebarMetrics.pinnedFrames(count: 7, width: width)[0].width == SidebarMetrics.pinnedFrames(count: 8, width: width)[0].width, "7 и 8: плитки одного размера")
    check(SidebarMetrics.pinnedFrames(count: 5, width: width)[0].width == SidebarMetrics.pinnedFrames(count: 6, width: width)[0].width, "5 и 6: плитки одного размера")
    let three = SidebarMetrics.pinnedFrames(count: 3, width: width)[0]
    check(abs(SidebarMetrics.tileHeight / three.width - 0.6) < 0.02, "высота плитки — около 60% ширины при трёх столбцах")
    check(SidebarMetrics.pinnedHeight(count: 9) == 3 * SidebarMetrics.tileHeight + 2 * SidebarMetrics.tileGap, "высота сетки 3 x 3")
    check(SidebarMetrics.pinnedHeight(count: 0) == SidebarMetrics.emptyHintHeight, "пустая зона — высота подсказки")

    print("== точка -> место вставки")
    let tiles = SidebarMetrics.pinnedFrames(count: 4, width: width)
    check(SidebarMetrics.pinnedInsertion(point: CGPoint(x: tiles[2].midX, y: 20), others: 3, width: width) == 2, "плитки: ближайшее место")
    check(SidebarMetrics.pinnedInsertion(point: CGPoint(x: 5000, y: 5000), others: 3, width: width) == 3, "плитки: далеко — последнее место")
    check(SidebarMetrics.columnInsertion(y: -30, others: 4, rowHeight: 46) == 0, "список: выше верха — первое место")
    check(SidebarMetrics.columnInsertion(y: 1000, others: 4, rowHeight: 46) == 4, "список: ниже низа — последнее")
    check(SidebarMetrics.columnInsertion(y: 48 + 23, others: 4, rowHeight: 46) == 1, "список: середина второй строки — место 1")

    print("== предпросмотр")
    let p = SidebarLayout(pinned: [.sound], list: [.fans, .load], hidden: [])
    let moving = p.preview(.fans, target: .init(zone: .pinned, index: 0))
    check(moving[.pinned]! == [nil, .sound] && moving[.list]! == [.load], "перетаскивание в закреплённые: пустота на месте вставки, список сомкнулся")
    let back = p.preview(.fans, target: nil)
    check(back[.list]! == [nil, .load] && back[.pinned]! == [.sound], "без цели: пустота на прежнем месте")
    let fullDrag = SidebarLayout(pinned: Array(all.prefix(9)), list: [.awake]).preview(.awake, target: .init(zone: .pinned, index: 0))
    check(fullDrag[.pinned]!.compactMap { $0 }.count == 9 && !fullDrag[.pinned]!.contains { $0 == nil }, "десятая плитка: места не открывается")
}

// MARK: - Настройки и переход

@MainActor func settingsFlow() async {
    print("== настройки: закрепление, скрытие, порядок")
    let defaults = Kit.defaults
    let modules = ModuleManager.shared
    let icons = ModuleMenuIcons.shared
    var told: [String] = []
    icons.tellUtility = { m, on in told.append("\(m.rawValue) \(on)") }
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)); modules.setOn(m, true); modules.setHidden(m, false) }
    modules.applyOrder(Module.allCases)
    icons.start()

    print("== запуск: порядок не трогается первым опросом")
    let registry = SatelliteRegistry.shared
    let apps = registry.environment.paths.appsDir
    func putBundle(_ name: String, version: String) {
        let contents = apps.appendingPathComponent(name + ".app/Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        (["CFBundleShortVersionString": version] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }
    func removeBundle(_ name: String) { try? FileManager.default.removeItem(at: apps.appendingPathComponent(name + ".app")) }
    /// Настоящий опрос, как при запуске и после установки.
    func poll(_ module: Module, until done: @escaping () -> Bool) async {
        for _ in 0..<100 {
            registry.refresh(module)
            await pause(0.02)
            if done() { break }
        }
    }
    let arranged: [Module] = Module.allCases.reversed()
    modules.applyOrder(arranged)
    putBundle("Clipboard", version: "1.1.0")
    modules.setOn(.clipboard, false)
    let launched = SidebarModel(modules: modules, icons: icons, satellites: registry)
    await poll(.clipboard) { modules.isExternal(.clipboard) }
    launched.reconcile()
    check(modules.isExternal(.clipboard), "опрос: утилита стоит, модуль был выключен — модуль ведёт она")
    check(modules.order == arranged, "первый опрос при запуске не меняет порядок, который расставил человек")
    launched.reconcile()
    check(modules.order == arranged, "и следующие пересчёты его не меняют")
    modules.setOn(.voice, false)
    await poll(.voice) { !modules.isExternal(.voice) }
    let running = SidebarModel(modules: modules, icons: icons, satellites: registry)
    putBundle("Voice", version: "1.1.0")
    await poll(.voice) { modules.isExternal(.voice) }
    running.reconcile()
    check(modules.order.last == .voice, "настоящая установка, пока центр работает, ставит модуль в конец")
    removeBundle("Clipboard"); removeBundle("Voice")
    modules.setExternal(.clipboard, false); modules.setExternal(.voice, false)
    modules.setOn(.clipboard, true); modules.setOn(.voice, true)
    modules.applyOrder(Module.allCases)
    await pause(0.05)

    SidebarModel.shared.start()
    await pause(0.1)
    let model = SidebarModel.shared

    check(model.layout().pinned.isEmpty && model.layout().list.count == Module.allCases.count, "первый запуск: ничего не закреплено, все в списке")
    modules.setHidden(.mouse, true)
    check(model.layout().hidden == [.mouse], "уже скрытые модули — в «Скрытых»")
    defaults.set(false, forKey: MenuBarIcon.key(.fans))
    defaults.set(true, forKey: MenuBarIcon.key(.sound))
    icons.set(.sound, true)
    check(!model.layout().pinned.contains(.fans) && model.layout().pinned == [.sound], "false остаётся не закреплённым, true — закреплённый")

    // Значок рисует утилита: закрепление доходит до неё сразу.
    modules.setExternal(.awake, true)
    told = []
    check(model.send(.awake, to: .pinned) && defaults.bool(forKey: MenuBarIcon.key(.awake)) && icons.isOn(.awake), "закрепление включает MenuBarIcon.<id> сразу")
    check(told == ["awake true"], "утилите сказано о значке без перезапуска: \(told)")
    check(model.send(.awake, to: .list) && defaults.object(forKey: MenuBarIcon.key(.awake)) == nil, "открепление снимает ключ")
    check(told == ["awake true", "awake false"], "и утилите сказано сразу: \(told)")
    modules.setExternal(.awake, false)
    // Без утилиты говорить некому: плитка закрепляется, ключ прочитает будущая утилита.
    told = []
    check(model.send(.awake, to: .pinned) && icons.isOn(.awake) && told.isEmpty, "модуль без утилиты: закреплён, сказать некому: \(told)")
    check(model.send(.awake, to: .list), "и откреплён")
    check(!MenuBarIcon.utilityShows(setting: MenuBarIcon.setting(.awake), hubRunning: false, active: true), "после открепления значка утилиты нет и без центра")
    check(model.send(.sound, to: .hidden) && modules.isHidden(.sound) && defaults.object(forKey: MenuBarIcon.key(.sound)) == nil, "перенос закреплённого в скрытые снимает ключ")
    icons.set(.awake, false)
    check(defaults.object(forKey: MenuBarIcon.key(.awake)) as? Bool == false, "явное «Скрыть значок» пишет false")
    check(!MenuBarIcon.utilityShows(setting: MenuBarIcon.setting(.awake), hubRunning: false, active: true), "и значка нет и без центра")
    defaults.removeObject(forKey: MenuBarIcon.key(.awake))
    await pause(0.05)
    check(model.layout().hidden.contains(.sound) && modules.isOn(.sound), "скрытый продолжает работать")
    check(model.send(.sound, to: .list) && !modules.isHidden(.sound), "«показать» возвращает в список")

    print("== порядок сохраняется")
    modules.applyOrder(Module.allCases)
    model.send(.keyboard, to: .pinned); model.send(.stash, to: .pinned)
    var l = model.layout()
    check(l.pinned == [.keyboard, .stash], "новое закрепление встаёт в конец закреплённых")
    check(model.nudge(.stash, by: -1) && model.layout().pinned == [.stash, .keyboard], "⌘⌥↑ меняет порядок закреплённых")
    let stored = ModuleManager.normalizedOrder(UserDefaults.standard.stringArray(forKey: "ModuleOrder") ?? [])
    check(stored == modules.order && stored.firstIndex(of: .stash)! < stored.firstIndex(of: .keyboard)!, "порядок записан в настройки")
    l = model.layout()
    var moved = l
    check(moved.move(.load, to: .list, at: 0) && moved.list.first == .load, "перенос внутри списка")
    model.apply(moved, moved: .load)
    check(model.layout().list.first == .load, "порядок списка применён")

    print("== убрали и вернули")
    model.send(.awake, to: .pinned)
    await pause(0.05)
    modules.setOn(.awake, false)
    await pause(0.1)
    check(defaults.object(forKey: MenuBarIcon.key(.awake)) == nil, "выключили модуль — ключ снят")
    check(!model.layout().flattened.contains(.awake), "и из раскладки он ушёл")
    modules.setOn(.awake, true)
    await pause(0.1)
    check(model.layout().list.last == .awake && !model.layout().pinned.contains(.awake), "вернули — в конце списка, не закреплённый")
    modules.setOn(.voice, false)
    await pause(0.1)
    modules.setOn(.voice, true)
    await pause(0.1)
    check(model.layout().list.last == .voice, "новый модуль из Стора — в конце списка")
    check(model.layout(open: .mixer).flattened.contains(.mixer), "открытая страница остаётся в раскладке")
    modules.setOn(.mixer, false)
    await pause(0.1)
    icons.set(.mixer, true)
    check(model.send(.mixer, to: .list, open: .mixer) && !icons.isOn(.mixer) && !model.layout(open: .mixer).pinned.contains(.mixer), "выключенный модуль на открытой странице открепляется")
    modules.setOn(.mixer, true)
    await pause(0.1)
    icons.set(.voice, false)
    modules.setOn(.voice, false)
    await pause(0.1)
    check(defaults.object(forKey: MenuBarIcon.key(.voice)) == nil, "убрали модуль со скрытым значком: новая установка начнёт с чистого")
    modules.setOn(.voice, true)
    await pause(0.1)

    print("== значок сменили в утилите")
    let suite = ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? ""
    /// Другой процесс, как утилита: запись в общий домен, и сигнал статуса.
    func writeFromOutside(_ module: Module, _ on: Bool) async {
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        write.arguments = ["write", suite, MenuBarIcon.key(module), "-bool", on ? "true" : "false"]
        try? write.run()
        write.waitUntilExit()
        registry.statusPinged.send(module)
        await pause(0.1)
    }
    await writeFromOutside(.mouse, true)
    check(icons.isOn(.mouse) && model.layout().pinned.contains(.mouse), "закрепили из окна утилиты: плитка появилась в центре")
    await writeFromOutside(.mouse, false)
    check(!icons.isOn(.mouse) && !model.layout().pinned.contains(.mouse), "«Скрыть значок» в утилите: плитка ушла из закреплённых")
    defaults.removeObject(forKey: MenuBarIcon.key(.mouse))
    await pause(0.05)

    print("== старая утилита: значок появится после обновления")
    modules.setOn(.fans, false)
    putBundle("Fans", version: "1.0.0")
    await poll(.fans) { modules.isExternal(.fans) && registry.entries[.fans]?.installedVersion != nil }
    await pause(0.1)
    told = []
    check(model.send(.fans, to: .pinned) && model.layout().pinned.contains(.fans), "старой утилите закрепить можно: плитка встаёт")
    check(icons.notice?.contains(Module.fans.title) == true && icons.notice?.contains("после обновления") == true, "и тихая строка говорит про обновление: \(icons.notice ?? "нет")")
    check(told.isEmpty, "старой утилите вызова нет: она его не знает")
    putBundle("Fans", version: "1.1.0")
    await poll(.fans) { registry.entries[.fans]?.installedVersion == "1.1.0" }
    check(icons.notice == nil, "обновили — строка ушла")
    check(model.send(.fans, to: .list) && told == ["fans false"] && defaults.object(forKey: MenuBarIcon.key(.fans)) == nil, "открепление: новой утилите сказано, ключ снят (\(told))")
    removeBundle("Fans")
    await poll(.fans) { !modules.isExternal(.fans) }
    modules.setOn(.fans, true)
    await pause(0.1)
    check(SatelliteRegistry.isOutdated(.sound, installed: "1.0.0") && SatelliteRegistry.isOutdated(.sound, installed: "0") && !SatelliteRegistry.isOutdated(.sound, installed: "1.1.0")
          && !SatelliteRegistry.isOutdated(.sound, installed: "1.10.0") && !SatelliteRegistry.isOutdated(.sound, installed: nil) && !SatelliteRegistry.isOutdated(.bots, installed: "1.0.0"), "кто считается старым")

    print("== десятый не закрепляется")
    for m in Module.allCases { _ = model.send(m, to: .list) }
    let nine = Array(Module.allCases.prefix(9))
    for m in nine { check(model.send(m, to: .pinned), "закреплён \(m.rawValue)") }
    let tenth = Module.allCases[9]
    check(!model.send(tenth, to: .pinned) && !icons.isOn(tenth) && model.layout().pinned.count == 9, "десятый отклонён, значок не включён")
    check(model.layout().showsNotchHint, "подсказка про вырез показана")
    icons.set(tenth, true)
    check(defaults.object(forKey: MenuBarIcon.key(tenth)) == nil && !icons.isOn(tenth), "десятый из переключателя на странице, настроек и меню не встаёт")
    check(icons.isFull && icons.notice == MenuBarIcon.limitNotice, "и тихая строка говорит почему")
    defaults.set(true, forKey: MenuBarIcon.key(tenth))
    await pause(0.05)
    check(icons.isOn(tenth) && model.layout().list.contains(tenth), "десятый со значком из старых настроек лежит в списке")
    var within = model.layout()
    check(within.move(tenth, to: .list, at: 1), "перенос по списку")
    model.apply(within, moved: tenth)
    check(icons.isOn(tenth) && defaults.bool(forKey: MenuBarIcon.key(tenth)), "перенос по списку значка не снимает")
    defaults.removeObject(forKey: MenuBarIcon.key(tenth))
    await pause(0.05)
    told = []
    for m in Module.allCases { _ = model.send(m, to: .list) }
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
}

// MARK: - Снимки панели

/// Отвечают ли утилиты на опрос: на снимках отвечают, в настройках и переходе модули без утилит.
final class AnswerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }
}
let utilitiesAnswer = AnswerFlag()

/// Модель с готовой строкой: настоящим нужна живая утилита.
final class FixtureCard: RemoteModuleSurface {
    let card: DashState
    init(_ card: DashState) { self.card = card }
    var responding: Bool { true }
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func refresh() {}
    func dashboardState(base: DashState, status: LinkStatus?) -> DashState { card }
    func performDashboardAction() -> Bool { false }
    func performDashboardAction(ask: (DashConfirmation) -> Void) -> Bool { false }
    func setDashboardVisible(_ visible: Bool) {}
    var menuUsesQuickActions: Bool { true }
}

@MainActor func scenes() async {
    let model = SidebarModel.shared
    let modules = ModuleManager.shared
    let defaults = Kit.defaults
    // Строки как у настоящих утилит: бандл, ответ на опрос, карточка из модели.
    let fixtures: [Module: DashState] = [
        .fans: DashState(text: "59° · По датчику · 3101 об/мин"),
        .keyboard: DashState(text: "ABC"),
        .sound: DashState(text: "Микрофон: MacBook Pro"),
        .mouse: DashState(text: "Скорость 1,2 · Прокрутка как у мыши"),
        .browser: DashState(text: "нужен доступ", attention: true),
        .stash: DashState(text: "5 программ в списке"),
        .voice: DashState(text: "Готов · ⌥ Пробел"),
        .clipboard: DashState(text: "34 записи"),
        .awake: DashState(text: "Не спит ещё 1 ч 20 мин"),
        .mixer: DashState(text: "Музыка 60%"),
        .load: DashState(text: "Память 11 из 16 ГБ · очень длинная строка, которая обязана обрезаться"),
    ]
    let registry = SatelliteRegistry.shared
    let apps = registry.environment.paths.appsDir
    for module in Module.allCases {
        let contents = apps.appendingPathComponent(SatelliteRegistry.bundleName(module) + ".app/Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        (["CFBundleShortVersionString": "1.1.0"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        RemoteModules.testModels[module] = FixtureCard(fixtures[module] ?? DashState())
    }
    utilitiesAnswer.value = true
    await registry.update()
    check(Module.allCases.allSatisfy(modules.isExternal), "снимки панели: все модули ведут утилиты")
    check(fixtures.allSatisfy { DashboardLive.snapshot($0.key) == $0.value }, "снимки панели: строки идут из модели утилиты")
    var rows: [String: NSBitmapImageRep] = [:]
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        func reset() {
            for m in Module.allCases { _ = model.send(m, to: .list); defaults.removeObject(forKey: MenuBarIcon.key(m)) }
            modules.applyOrder(Module.allCases)
            UserDefaults.standard.set(false, forKey: "HiddenModulesExpanded")
        }
        reset()
        await pause(0.1)
        rows["\(themeName)-normal"] = await snapshot("\(themeName)-normal", theme: theme)
        check(rows["\(themeName)-normal"]!.pixelsWide > 0, "снят обычный вид (\(themeName))")
        for n in 1...9 {
            reset()
            for m in Module.allCases.prefix(n) { _ = model.send(m, to: .pinned) }
            await pause(0.1)
            rows["\(themeName)-pins\(n)"] = await snapshot("\(themeName)-pins\(n)", theme: theme)
        }
        check(differing(rows["\(themeName)-pins3"]!, rows["\(themeName)-pins4"]!) > 0, "\(themeName): 3 и 4 плитки отличаются на снимке")
        check(differing(rows["\(themeName)-normal"]!, rows["\(themeName)-pins1"]!) > 0, "\(themeName): плитка видна")
        check(differingInPage(rows["\(themeName)-normal"]!, rows["\(themeName)-pins9"]!) == 0, "\(themeName): область страницы не изменилась (0 пикселей)")
        reset()
        for m in [Module.mouse, .mixer] { _ = model.send(m, to: .hidden) }
        _ = model.send(.sound, to: .pinned); _ = model.send(.fans, to: .pinned)
        UserDefaults.standard.set(true, forKey: "HiddenModulesExpanded")
        await pause(0.1)
        rows["\(themeName)-hidden-open"] = await snapshot("\(themeName)-hidden-open", theme: theme)
        check(differing(rows["\(themeName)-hidden-open"]!, rows["\(themeName)-pins2"]!) > 0, "\(themeName): раскрытые «Скрытые» видны")
        UserDefaults.standard.set(false, forKey: "HiddenModulesExpanded")
        await pause(0.1)
        rows["\(themeName)-hidden-closed"] = await snapshot("\(themeName)-hidden-closed", theme: theme)
        _ = await snapshot("\(themeName)-narrow", theme: theme, width: 840, height: 540)
        UserDefaults.standard.set(true, forKey: "HiddenModulesExpanded")
        _ = await snapshot("\(themeName)-narrow-hidden-open", theme: theme, width: 840, height: 540)
        UserDefaults.standard.set(false, forKey: "HiddenModulesExpanded")
        // Перетаскивание на середине: плитка поднята, в закреплённых открыт зазор.
        reset()
        for m in [Module.sound, .fans, .stash] { _ = model.send(m, to: .pinned) }
        await pause(0.1)
        SidebarContent.testDrag = (.load, .init(zone: .pinned, index: 1), CGPoint(x: 80, y: 90))
        rows["\(themeName)-mid-drag"] = await snapshot("\(themeName)-mid-drag", theme: theme)
        SidebarContent.testDrag = nil
        check(differing(rows["\(themeName)-mid-drag"]!, rows["\(themeName)-pins3"]!) > 0, "\(themeName): снимок с перетаскиванием отличается")
        reset()
    }
    utilitiesAnswer.value = false
    RemoteModules.testModels = [:]
}

@MainActor func run() async {
    let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let appsDir = workRoot.appendingPathComponent("Apps")
    try? FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
    let paths = SatellitePaths(appsDir: appsDir, agentsDir: workRoot.appendingPathComponent("Agents"))
    SatelliteRegistry.standEnvironment = SatelliteEnvironment(
        paths: paths, defaults: Kit.defaults,
        installer: SatelliteInstaller(paths: paths, launchctl: { _ in }, download: { $0 }, verify: { _, _ in }),
        commands: SatelliteCommands(status: { _ in
            guard utilitiesAnswer.value else { throw LinkError.timeout }
            return LinkStatus(enabled: true, line: "", needsSetup: 0)
        }, setEnabled: { _, _ in }, openWindow: { _ in }),
        loadCatalog: { Data(#"{"schema":1,"apps":[]}"#.utf8) },
        hubVersion: "0.6.0", modules: .shared)
    pure()
    await settingsFlow()
    await scenes()
    Kit.defaults.removeObject(forKey: DSTheme.storageKey)
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
