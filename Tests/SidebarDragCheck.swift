import AppKit
import SwiftUI

// Перетаскивание в боковой панели настоящими событиями мыши: окно за экраном (x: -10000), `NSWindow.sendEvent`
// (mouseDown, много мелких mouseDragged, mouseUp, keyDown), без вызова обработчиков вида напрямую.
// Места берутся из того, что вид отрисовал (`SidebarProbe`, `NSScrollView`), а не из расчёта панели.
// Запуск: Tests/run-sidebar-drag-check.sh. Аргументы: рабочая папка, папка PNG.

let pngDir = URL(fileURLWithPath: CommandLine.arguments[2])
/// Последовательности кадров перетаскивания; по умолчанию рядом с остальными PNG.
let seqDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIDEBAR_DRAG_PNG"] ?? CommandLine.arguments[2])
nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
@MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

@MainActor final class Nav: ObservableObject { @Published var selection = Module.fans }

struct Harness: View {
    @ObservedObject var nav: Nav
    @State private var dashboard = false
    @State private var store = false
    @State private var about = false
    @State private var peeked: Module?

    var body: some View {
        HStack(spacing: 0) {
            DSSidebar(current: nav.selection, showDashboard: $dashboard, showStore: $store, showAbout: $about,
                      peeked: $peeked, selection: $nav.selection)
                .frame(width: DS.sidebarWidth)
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).fill(Color.black.opacity(0.3))
                .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 10))
        }
    }
}

// MARK: - Стенд

@MainActor final class Rig {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let height: CGFloat
    let nav: Nav
    var event = 0
    /// Что было нарисовано в покое до перетаскивания.
    var rest: [Module: CGRect] = [:]
    var restGrid = CGRect.zero
    var restHeader = CGRect.zero

    init(height: CGFloat) async {
        self.height = height
        let nav = Nav()
        self.nav = nav
        let width: CGFloat = 980
        SidebarProbe.frames = [:]
        SidebarProbe.copy = nil
        SidebarProbe.line = nil
        let root = ZStack { DSBackground(module: .fans, neutral: false); Harness(nav: nav) }
            .environment(\.dsTint, DSTheme.dusk.accent(.fans))
            .dsThemed()
            .frame(width: width, height: height)
        host = NSHostingView(rootView: AnyView(root))
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        await pause(0.7)
        host.layoutSubtreeIfNeeded()
        remember()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    func remember() {
        rest = SidebarProbe.frames
        restGrid = SidebarProbe.grid
        restHeader = SidebarProbe.header
    }

    // MARK: События

    private func send(_ type: NSEvent.EventType, _ point: CGPoint) {
        event += 1
        let location = NSPoint(x: point.x, y: height - point.y)
        guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: event,
                                         clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { fatalError("нет события") }
        window.sendEvent(e)
    }

    func down(_ p: CGPoint) { send(.leftMouseDown, p) }
    func dragged(_ p: CGPoint) { send(.leftMouseDragged, p) }
    func up(_ p: CGPoint) { send(.leftMouseUp, p) }
    func rightDown(_ p: CGPoint) { send(.rightMouseDown, p) }
    func rightUp(_ p: CGPoint) { send(.rightMouseUp, p) }

    func esc() {
        event += 1
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                 isARepeat: false, keyCode: 53)!
        window.sendEvent(e)
    }

    /// В `dir` — только панель (кадры последовательностей); без `dir` — всё окно.
    func snapshot(_ name: String, to dir: URL? = nil) {
        host.layoutSubtreeIfNeeded()
        let area = dir == nil ? host.bounds : NSRect(x: 0, y: 0, width: 250, height: height)
        let rep = host.bitmapImageRepForCachingDisplay(in: area)!
        host.cacheDisplay(in: area, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: (dir ?? pngDir).appendingPathComponent(name + ".png"))
    }

    // MARK: Места

    var frames: [Module: CGRect] { SidebarProbe.frames }

    /// Прокрутка списка панели: единственный `NSScrollView` в окне.
    var scroll: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let s = view as? NSScrollView { return s }
            for sub in view.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(host)
    }

    /// Видимая часть списка в координатах окна сверху вниз.
    var viewport: CGRect {
        guard let scroll else { return .zero }
        let r = scroll.convert(scroll.bounds, to: nil)
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }
    var scrollY: CGFloat { scroll?.contentView.bounds.origin.y ?? 0 }
    func scrollTo(_ y: CGFloat) {
        guard let scroll else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    let width = DS.sidebarWidth - 20

    /// Места плиток сетки на `count` плиток, в координатах окна.
    func gridFrames(_ count: Int) -> [CGRect] {
        SidebarMetrics.pinnedFrames(count: count, width: width).map { $0.offsetBy(dx: restGrid.minX, dy: restGrid.minY) }
    }
    /// Центр места `index` в списке, считая от верха первой строки.
    func rowSlot(_ index: Int, top: CGFloat) -> CGPoint {
        CGPoint(x: restGrid.minX + width / 2, y: top + CGFloat(index) * (SidebarMetrics.rowHeight + SidebarMetrics.rowGap) + SidebarMetrics.rowHeight / 2)
    }
    func hiddenSlot(_ index: Int, header: CGRect) -> CGPoint {
        CGPoint(x: header.minX + width / 2, y: header.maxY + SidebarMetrics.rowGap
                + CGFloat(index) * (SidebarMetrics.hiddenRowHeight + SidebarMetrics.rowGap) + SidebarMetrics.hiddenRowHeight / 2)
    }
}

// MARK: - Проход мышью

struct Trace {
    var samples = 0
    var missing = 0
    var maxOutside: CGFloat = 0
    var maxLag: CGFloat = 0
    var sawCopy = false
    /// Сколько раз копия сменила вид (плитка, строка, скрытая строка) за проход.
    var kindSwitches = 0
    /// Посадка: на сколько pt последний кадр копии не совпал с настоящей строкой, которая встала на её место (nil — не мерили).
    var landJump: CGFloat?
    /// Кадров посадки, в которых копия и настоящий вид были видны вместе (двойное изображение).
    var doubleImage = 0
}

/// Вид копии по высоте: плитка 40, строка 46, скрытая строка 28.
func copyKind(_ r: CGRect) -> Int {
    [28.0, 40.0, 46.0].enumerated().min { abs($0.element - r.height) < abs($1.element - r.height) }!.offset
}

/// Для этих проходов кадры сохраняются в папку последовательностей.
let keyScenarios: Set<String> = ["rows-down", "tiles", "list-to-grid", "list-to-grid5", "grid-to-list", "tenth", "esc", "scrolled"]

func points(_ a: CGPoint, _ b: CGPoint, step: CGFloat = 4) -> [CGPoint] {
    let n = max(Int((hypot(b.x - a.x, b.y - a.y) / step).rounded(.up)), 1)
    return (1...n).map { CGPoint(x: a.x + (b.x - a.x) * CGFloat($0) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat($0) / CGFloat(n)) }
}

/// Нажать в `start`, провести по `route` мелкими шагами (4 pt, кадр между шагами), подержать, отпустить.
/// Каждый шаг меряет, где поднятая копия относительно курсора: курсор обязан быть внутри копии,
/// а у копии той же формы, что была взята, центр держится на расстоянии захвата от курсора.
@MainActor func drag(_ rig: Rig, _ name: String, from start: CGPoint, via route: [CGPoint], grabbed: Module? = nil,
                     then: (() -> CGPoint)? = nil, hold: Double = 0.6, midCheck: (() -> Void)? = nil, release: Bool = true,
                     frames saved: Bool = false) async -> Trace {
    var trace = Trace()
    let saved = saved || keyScenarios.contains(name)
    let source = grabbed.flatMap { rig.rest[$0] }
    let grab = source.map { CGPoint(x: start.x - $0.midX, y: start.y - $0.midY) } ?? .zero
    let sourceWidth = source?.width ?? 0
    rig.down(start)
    await pause(0.03)
    var last = start
    var lastWidth: CGFloat = 0
    var morphUntil = Date.distantPast
    var lastKind = -1
    var n = 0
    var legs = route
    var second = then
    while !legs.isEmpty {
        let target = legs.removeFirst()
        for p in points(last, target) {
            rig.dragged(p)
            last = p
            await pause(0.016)
            n += 1
            trace.samples += 1
            guard let copy = SidebarProbe.copy else {
                if trace.sawCopy { trace.missing += 1 }
                continue
            }
            trace.sawCopy = true
            let dx = max(copy.minX - p.x, p.x - copy.maxX, 0), dy = max(copy.minY - p.y, p.y - copy.maxY, 0)
            trace.maxOutside = max(trace.maxOutside, hypot(dx, dy))
            if abs(copy.width - lastWidth) > 1 { morphUntil = Date().addingTimeInterval(0.45) }
            lastWidth = copy.width
            if copyKind(copy) != lastKind { if lastKind >= 0 { trace.kindSwitches += 1 }; lastKind = copyKind(copy) }
            // Копия той же формы (тот же вид, что у взятого): центр = курсор минус захват. Другой вид: центр на курсоре.
            let sameKind = abs(copy.width - sourceWidth) < 6 && abs(copy.height - (source?.height ?? 0)) < 6
            let expected = sameKind ? CGPoint(x: p.x - grab.x, y: p.y - grab.y) : p
            if Date() > morphUntil, source != nil {
                trace.maxLag = max(trace.maxLag, hypot(copy.midX - expected.x, copy.midY - expected.y))
            }
            if saved, n % 3 == 0 { rig.snapshot("\(name)-\(String(format: "%03d", n))", to: seqDir) }
        }
        // Раскладка под курсором успела перестроиться: второй отрезок считаем по тому, что нарисовано теперь.
        if legs.isEmpty, let next = second {
            second = nil
            await pause(0.5)
            legs.append(next())
        }
    }
    await pause(hold)
    midCheck?()
    if saved { rig.snapshot("\(name)-held", to: seqDir) }
    if release {
        rig.up(last)
        // Посадка: смотрим каждый кадр, пока копия не исчезнет, и сверяем её последний кадр с настоящей строкой.
        var lastCopy: CGRect?
        var gone = false
        for i in 1...60 {
            await pause(0.008)
            if let copy = SidebarProbe.copy { lastCopy = copy } else if !gone, let lastCopy, let module = grabbed, let real = SidebarProbe.frames[module] {
                gone = true
                trace.landJump = hypot(lastCopy.minX - real.minX, lastCopy.minY - real.minY)
            }
            if saved, i % 8 == 0 { rig.snapshot("\(name)-drop\(i / 8)", to: seqDir) }
        }
        await pause(0.4)
    }
    return trace
}

func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 1.5) -> Bool {
    abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
}

// MARK: - Состояние

let all = Module.allCases

@MainActor func prepare(pinned: [Module] = [], hidden: [Module] = [], expanded: Bool = false) async {
    let model = SidebarModel.shared
    let modules = ModuleManager.shared
    for m in all { _ = model.send(m, to: .list); Kit.defaults.removeObject(forKey: MenuBarIcon.key(m)); modules.setOn(m, true) }
    modules.applyOrder(all)
    for m in pinned { _ = model.send(m, to: .pinned) }
    for m in hidden { _ = model.send(m, to: .hidden) }
    UserDefaults.standard.set(expanded, forKey: "HiddenModulesExpanded")
    await pause(0.15)
}

@MainActor func lay() -> SidebarLayout { SidebarModel.shared.layout() }

/// Строки списка стоят столбцом с одним пустым местом `gap` (счёт среди остальных); верх столбца — верх прокрутки (по AppKit).
@MainActor func listGap(_ rig: Rig, others: [Module], gap: Int) -> Bool {
    let top = rig.viewport.minY + 2 - rig.scrollY
    for (i, m) in others.enumerated() {
        guard let f = SidebarProbe.frames[m] else { return false }
        let slot = i < gap ? i : i + 1
        let y = top + CGFloat(slot) * (SidebarMetrics.rowHeight + SidebarMetrics.rowGap)
        if abs(f.minY - y) > 2 || abs(f.height - SidebarMetrics.rowHeight) > 1 { return false }
    }
    return true
}

/// Плитки стоят на местах сетки `slots.count`, пустое место (nil) оставлено.
@MainActor func tilesMatch(_ rig: Rig, slots: [Module?]) -> Bool {
    let grid = rig.gridFrames(slots.count)
    for (i, m) in slots.enumerated() {
        guard let m else { continue }
        guard let f = SidebarProbe.frames[m], near(f, grid[i]) else { return false }
    }
    return true
}

func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

// MARK: - Сценарии

@MainActor func clicks() async {
    print("== клик и правая кнопка")
    await prepare(pinned: Array(all.prefix(3)))
    let rig = await Rig(height: 680)
    let row = lay().list[2]
    var p = center(rig.rest[row]!)
    rig.down(p); await pause(0.03); rig.up(p); await pause(0.3)
    check(rig.nav.selection == row && SidebarProbe.copy == nil, "клик по строке открывает модуль, перетаскивание не началось")
    let before = lay()
    let tile = lay().pinned[1]
    p = center(rig.rest[tile]!)
    rig.down(p); await pause(0.03); rig.dragged(CGPoint(x: p.x + 2, y: p.y + 1)); await pause(0.03)
    rig.up(CGPoint(x: p.x + 2, y: p.y + 1)); await pause(0.3)
    check(rig.nav.selection == tile && SidebarProbe.copy == nil && lay() == before, "клик по плитке с дрожанием руки на 2 pt остаётся кликом")
    // Настоящее меню блокирует цикл событий; панель с собственным меню в проверке кладёт его пункты в `SidebarProbe.menu`.
    if SidebarProbe.interceptsMenu {
        SidebarProbe.menu = nil
        let other = lay().list[0]
        p = center(rig.rest[other]!)
        rig.rightDown(p); await pause(0.05); rig.rightUp(p); await pause(0.2)
        check(SidebarProbe.copy == nil && lay() == before, "правая кнопка не начинает перетаскивание")
        check((SidebarProbe.menu ?? []).contains("Открыть") && (SidebarProbe.menu ?? []).contains("Удалить модуль…"), "правая кнопка по строке открывает меню")
    } else {
        print("skip правая кнопка: меню панели не перехватывается, настоящее блокирует цикл событий")
    }
    rig.close()
}

@MainActor func reorder() async {
    print("== порядок строк и плиток")
    await prepare(pinned: Array(all.prefix(3)))
    var rig = await Rig(height: 680)
    var list = lay().list
    var m = list[1]
    var s = center(rig.rest[m]!)
    let top = rig.rest[list[0]]!.minY
    var aim = rig.rowSlot(5, top: top)
    var trace = await drag(rig, "rows-down", from: s, via: [aim], grabbed: m, midCheck: {
        check(listGap(rig, others: list.filter { $0 != m }, gap: 5), "строка вниз: остальные расступились, пустое место на пятом месте")
        check(SidebarProbe.copy != nil, "копия на экране, пока кнопка зажата")
    })
    check(trace.sawCopy, "строка вниз: перетаскивание началось")
    check(trace.maxOutside < 1 && trace.missing == 0, "строка вниз: курсор всё время внутри копии (отрыв \(Int(trace.maxOutside)) pt, пропаж \(trace.missing))")
    check(trace.maxLag < 6, "строка вниз: копия идёт 1:1 за курсором (отставание до \(Int(trace.maxLag)) pt)")
    check((trace.landJump ?? 99) < 2, "строка вниз: посадка без скачка (\(trace.landJump.map { String(format: "%.1f", $0) } ?? "не замерена") pt)")
    var expected = list.filter { $0 != m }; expected.insert(m, at: 5)
    check(lay().list == expected, "строка вниз: легла на пятое место")
    check(SidebarProbe.copy == nil, "строка вниз: копия убрана, ничего не застряло")
    rig.close()

    await prepare(pinned: Array(all.prefix(3)))
    rig = await Rig(height: 680)
    list = lay().list
    m = list[6]
    s = center(rig.rest[m]!)
    aim = rig.rowSlot(1, top: rig.rest[list[0]]!.minY)
    trace = await drag(rig, "rows-up", from: s, via: [aim], grabbed: m, midCheck: {
        check(listGap(rig, others: list.filter { $0 != m }, gap: 1), "строка вверх: пустое место на втором месте")
    })
    expected = list.filter { $0 != m }; expected.insert(m, at: 1)
    check(lay().list == expected, "строка вверх: легла на второе место")
    check(trace.maxOutside < 1 && trace.maxLag < 6, "строка вверх: копия 1:1 (отрыв \(Int(trace.maxOutside)), отставание \(Int(trace.maxLag)))")
    rig.close()

    await prepare(pinned: Array(all.prefix(3)))
    rig = await Rig(height: 680)
    let tiles = lay().pinned
    m = tiles[0]
    s = center(rig.rest[m]!)
    let grid3 = rig.gridFrames(3)
    trace = await drag(rig, "tiles", from: s, via: [center(grid3[2])], grabbed: m, midCheck: {
        check(tilesMatch(rig, slots: [tiles[1], tiles[2], nil]), "плитки: соседи сдвинулись, место открыто в конце")
    })
    check(lay().pinned == [tiles[1], tiles[2], tiles[0]], "плитки: порядок сменился")
    check(trace.maxOutside < 1 && trace.maxLag < 6, "плитки: копия 1:1 (отрыв \(Int(trace.maxOutside)), отставание \(Int(trace.maxLag)))")
    rig.close()
}

@MainActor func between() async {
    print("== между сеткой и списком")
    // Список -> сетка: из трёх плиток выходит четыре в одну строку.
    await prepare(pinned: Array(all.prefix(3)))
    var rig = await Rig(height: 680)
    var list = lay().list
    var tiles = lay().pinned
    var m = list[2]
    var s = center(rig.rest[m]!)
    let grid4 = rig.gridFrames(4)
    var trace = await drag(rig, "list-to-grid", from: s, via: [center(grid4[1])], grabbed: m, midCheck: {
        check(tilesMatch(rig, slots: [tiles[0], nil, tiles[1], tiles[2]]), "список -> сетка: плитки перестроились на четыре столбца, место открыто")
        check(listGap(rig, others: list.filter { $0 != m }, gap: 100), "список -> сетка: список сомкнулся")
        if let copy = SidebarProbe.copy { check(abs(copy.width - grid4[0].width) < 3, "список -> сетка: копия стала плиткой") }
    })
    check(lay().pinned == [tiles[0], m, tiles[1], tiles[2]], "список -> сетка: встала вторым номером")
    check(trace.kindSwitches <= 1, "список -> сетка: копия сменила вид один раз, без мерцания (\(trace.kindSwitches))")
    check(trace.maxOutside < 1, "список -> сетка: курсор внутри копии (отрыв \(Int(trace.maxOutside)))")
    check(SidebarProbe.copy == nil, "список -> сетка: копия убрана")
    rig.close()

    // Список -> сетка: из четырёх выходит пять (три столбца, две строки).
    await prepare(pinned: Array(all.prefix(4)))
    rig = await Rig(height: 680)
    list = lay().list
    tiles = lay().pinned
    m = list[0]
    s = center(rig.rest[m]!)
    let grid5 = rig.gridFrames(5)
    trace = await drag(rig, "list-to-grid5", from: s, via: [CGPoint(x: grid5[4].midX, y: rig.restGrid.midY - 6)], grabbed: m,
                       then: { center(grid5[4]) }, midCheck: {
        check(tilesMatch(rig, slots: [tiles[0], tiles[1], tiles[2], tiles[3], nil]), "четыре -> пять: три столбца, две строки, место в конце")
        check(abs(SidebarProbe.grid.height - SidebarMetrics.pinnedHeight(count: 5)) < 1.5, "четыре -> пять: сетка стала выше на строку")
        check(listGap(rig, others: list.filter { $0 != m }, gap: 100), "четыре -> пять: список сомкнулся и сдвинулся под сетку")
    })
    check(lay().pinned == tiles + [m], "четыре -> пять: плитка пятая")
    rig.close()

    // Сетка -> список: из пяти плиток остаётся четыре, строка открывает пустое место под курсором.
    await prepare(pinned: Array(all.prefix(5)))
    rig = await Rig(height: 680)
    list = lay().list
    tiles = lay().pinned
    m = tiles[4]
    s = center(rig.rest[m]!)
    let rowTop = SidebarMetrics.pinnedHeight(count: 4) + rig.restGrid.minY + 8 + 2
    let aim = rig.rowSlot(2, top: rowTop)
    trace = await drag(rig, "grid-to-list", from: s, via: [CGPoint(x: s.x, y: s.y + 30), aim], grabbed: m, midCheck: {
        check(tilesMatch(rig, slots: Array(tiles.prefix(4))), "сетка -> список: сетка сомкнулась на четыре плитки в одну строку")
        check(listGap(rig, others: list, gap: 2), "сетка -> список: пустое место открылось под курсором")
        if let copy = SidebarProbe.copy { check(abs(copy.width - rig.width) < 4, "сетка -> список: копия стала строкой") }
    })
    var expected = list; expected.insert(m, at: 2)
    check(lay().list == expected && lay().pinned == Array(tiles.prefix(4)), "сетка -> список: встала третьей строкой")
    check(trace.kindSwitches <= 1, "сетка -> список: копия сменила вид один раз, без мерцания (\(trace.kindSwitches))")
    check(trace.maxOutside < 1, "сетка -> список: курсор внутри копии (отрыв \(Int(trace.maxOutside)))")
    rig.close()

    // Семь плиток (под ними подсказка про вырез): девятая плитка встаёт в конец, строки списка считаются от нового верха.
    await prepare(pinned: Array(all.prefix(7)))
    rig = await Rig(height: 680)
    list = lay().list
    tiles = lay().pinned
    m = list[2]
    s = center(rig.rest[m]!)
    check(SidebarProbe.grid.maxY + 8 < rig.viewport.minY, "семь плиток: под сеткой подсказка про вырез, список ниже неё")
    let grid8 = rig.gridFrames(8)
    trace = await drag(rig, "seven-pins", from: s, via: [center(rig.rest[tiles[0]]!)], grabbed: m, then: { center(grid8[7]) }, midCheck: {
        check(tilesMatch(rig, slots: tiles.map { Optional($0) } + [nil]), "семь плиток: восемь мест, плитки на своих местах, место открыто в конце")
        check(listGap(rig, others: list.filter { $0 != m }, gap: 100), "семь плиток: список сомкнулся под сеткой с подсказкой")
    })
    check(lay().pinned == tiles + [m], "семь плиток: восьмая плитка в конце")
    check(trace.maxOutside < 1, "семь плиток: курсор внутри копии (отрыв \(Int(trace.maxOutside)))")
    rig.close()

    // Десятая плитка: отказ, копия возвращается.
    await prepare(pinned: Array(all.prefix(9)))
    rig = await Rig(height: 680)
    list = lay().list
    tiles = lay().pinned
    m = list[0]
    s = center(rig.rest[m]!)
    let grid9 = rig.gridFrames(9)
    let original = rig.rest[m]!
    trace = await drag(rig, "tenth", from: s, via: [center(grid9[4])], grabbed: m, midCheck: {
        check(tilesMatch(rig, slots: tiles.map { Optional($0) }), "десятая: плитки остались на местах, место не открылось")
    })
    check(lay().pinned == tiles && lay().list == list, "десятая: отказ, раскладка прежняя")
    check(rig.frames[m].map { near($0, original) } ?? false, "десятая: строка вернулась на своё место")
    check(SidebarProbe.copy == nil, "десятая: копия убрана")
    rig.close()
}

@MainActor func hiddenSection() async {
    print("== «Скрытые»")
    let hide = Array(all.suffix(2))
    // Окно повыше: заголовок «Скрытые» виден без прокрутки.
    let tall: CGFloat = 820
    // Список -> «Скрытые», раздел свёрнут и пуст. Список смыкается под курсором, заголовок уезжает вверх.
    await prepare(pinned: Array(all.prefix(3)))
    var rig = await Rig(height: tall)
    var list = lay().list
    var m = list[3]
    var s = center(rig.rest[m]!)
    var header = rig.restHeader
    check(header.maxY < rig.viewport.maxY, "заголовок «Скрытые» виден в окне (\(Int(header.maxY)) против \(Int(rig.viewport.maxY)))")
    var trace = await drag(rig, "list-to-hidden", from: s, via: [center(header)], grabbed: m,
                           midCheck: {
        check(SidebarProbe.line != nil, "в пустые свёрнутые «Скрытые»: видна линия вставки")
        if let line = SidebarProbe.line {
            let header = SidebarProbe.header
            check(abs(line.midY - header.maxY) < 8 && line.minX < header.minX + 20, "линия стоит под заголовком «Скрытые», слева")
        }
    }, frames: true)
    check(lay().hidden == [m] && ModuleManager.shared.isHidden(m), "в пустые свёрнутые «Скрытые»: модуль скрыт")
    check(SidebarProbe.copy == nil && SidebarProbe.line == nil, "после отпускания копия и линия убраны")
    check(trace.maxOutside < 1 && trace.missing == 0, "в «Скрытые»: курсор внутри копии (отрыв \(Int(trace.maxOutside)))")
    check(trace.kindSwitches <= 1, "в «Скрытые»: копия сменила вид один раз, без мерцания (\(trace.kindSwitches))")
    rig.close()

    // Список -> «Скрытые», раскрыты, два модуля; между ними.
    await prepare(pinned: Array(all.prefix(3)), hidden: hide, expanded: true)
    rig = await Rig(height: tall)
    list = lay().list
    var hidden = lay().hidden
    m = list[1]
    s = center(rig.rest[m]!)
    header = rig.restHeader
    trace = await drag(rig, "list-to-hidden-open", from: s, via: [center(header)], grabbed: m,
                       then: { rig.hiddenSlot(1, header: SidebarProbe.header) }, midCheck: {
        check(SidebarProbe.line != nil, "в раскрытые «Скрытые»: видна линия вставки")
        if let line = SidebarProbe.line {
            let boundary = SidebarProbe.header.maxY + SidebarMetrics.rowGap + SidebarMetrics.hiddenRowHeight + 1
            check(abs(line.midY - boundary) < 6, "линия стоит между первым и вторым скрытым (\(Int(line.midY)) против \(Int(boundary)))")
        }
    }, frames: true)
    check(lay().hidden == [hidden[0], m, hidden[1]], "в раскрытые «Скрытые»: встал между ними")
    rig.close()

    // «Скрытые» -> список.
    await prepare(pinned: Array(all.prefix(3)), hidden: hide, expanded: true)
    rig = await Rig(height: tall)
    list = lay().list
    hidden = lay().hidden
    m = hidden[1]
    s = center(rig.rest[m]!)
    var aim = rig.rowSlot(3, top: rig.rest[list[0]]!.minY)
    trace = await drag(rig, "hidden-to-list", from: s, via: [CGPoint(x: s.x, y: s.y - 40), aim], grabbed: m, midCheck: {
        check(listGap(rig, others: list, gap: 3), "скрытые -> список: пустое место на четвёртом месте")
    }, frames: true)
    var expected = list; expected.insert(m, at: 3)
    check(lay().list == expected && lay().hidden == [hidden[0]] && !ModuleManager.shared.isHidden(m), "скрытые -> список: модуль в списке и больше не скрыт")
    check(trace.maxOutside < 1 && trace.maxLag < 6, "скрытые -> список: копия 1:1 (отрыв \(Int(trace.maxOutside)), отставание \(Int(trace.maxLag)))")
    rig.close()

    // «Скрытые» -> сетка.
    await prepare(pinned: Array(all.prefix(3)), hidden: hide, expanded: true)
    rig = await Rig(height: tall)
    hidden = lay().hidden
    let tiles = lay().pinned
    m = hidden[0]
    s = center(rig.rest[m]!)
    let grid4 = rig.gridFrames(4)
    trace = await drag(rig, "hidden-to-grid", from: s, via: [center(grid4[3])], grabbed: m, midCheck: {
        check(tilesMatch(rig, slots: tiles.map { Optional($0) } + [nil]), "скрытые -> сетка: плитки перестроились, место открыто")
    })
    check(lay().pinned == tiles + [m] && !ModuleManager.shared.isHidden(m), "скрытые -> сетка: плитка в конце, модуль не скрыт")
    rig.close()

    // Сетка -> «Скрытые» (свёрнуты, там уже есть два).
    await prepare(pinned: Array(all.prefix(3)), hidden: hide, expanded: false)
    rig = await Rig(height: tall)
    let pins = lay().pinned
    m = pins[1]
    s = center(rig.rest[m]!)
    header = rig.restHeader
    // Над списком открывается пустое место, и заголовок уезжает вниз: целимся в то место, где он стоит теперь.
    trace = await drag(rig, "grid-to-hidden", from: s, via: [CGPoint(x: header.midX, y: header.minY - 20)], grabbed: m,
                       then: { center(SidebarProbe.header) }, midCheck: {
        check(SidebarProbe.line != nil, "сетка -> «Скрытые»: видна линия вставки")
    }, frames: true)
    check(lay().hidden.contains(m) && !lay().pinned.contains(m), "сетка -> «Скрытые»: модуль скрыт и откреплён")
    check(trace.maxOutside < 1, "сетка -> «Скрытые»: курсор внутри копии (отрыв \(Int(trace.maxOutside)))")
    check(trace.kindSwitches <= 2, "сетка -> «Скрытые»: копия не мерцает (\(trace.kindSwitches) смен вида)")
    rig.close()
}

@MainActor func cancelling() async {
    print("== Esc, выход за панель, залипание")
    await prepare(pinned: Array(all.prefix(3)))
    var rig = await Rig(height: 680)
    var before = lay()
    var list = lay().list
    var m = list[1]
    var s = center(rig.rest[m]!)
    var aim = rig.rowSlot(5, top: rig.rest[list[0]]!.minY)
    _ = await drag(rig, "esc", from: s, via: [aim], grabbed: m, hold: 0.3, midCheck: {
        rig.esc()
    }, release: false)
    await pause(0.5)
    check(listGap(rig, others: list.filter { $0 != m }, gap: 1), "Esc: остальные вернулись, пустое место на прежнем месте")
    rig.up(aim)
    await pause(0.6)
    check(lay() == before && SidebarProbe.copy == nil, "Esc: раскладка прежняя, копия убрана")
    check(rig.frames[m].map { near($0, rig.rest[m]!) } ?? false, "Esc: строка на своём месте")
    s = center(rig.rest[list[4]]!)
    rig.down(s); await pause(0.03); rig.up(s); await pause(0.2)
    check(rig.nav.selection == list[4], "после Esc клик снова открывает модуль")
    rig.close()

    await prepare(pinned: Array(all.prefix(3)))
    rig = await Rig(height: 680)
    before = lay()
    list = lay().list
    m = list[2]
    s = center(rig.rest[m]!)
    aim = CGPoint(x: 640, y: s.y + 40)
    let trace = await drag(rig, "outside", from: s, via: [CGPoint(x: s.x + 120, y: s.y + 20), aim], grabbed: m, midCheck: {
        check(listGap(rig, others: list.filter { $0 != m }, gap: 2), "вне панели: пустое место вернулось на прежнее место")
    })
    check(lay() == before && SidebarProbe.copy == nil, "отпустили вне панели: всё на месте, копия убрана")
    check(trace.maxOutside < 1, "вне панели: курсор внутри копии (отрыв \(Int(trace.maxOutside)))")
    check(rig.frames[m].map { near($0, rig.rest[m]!) } ?? false, "отпустили вне панели: строка вернулась")
    rig.close()
}

@MainActor func scrolled() async {
    print("== короткое окно: прокрутка и автопрокрутка")
    await prepare()
    var rig = await Rig(height: 540)
    let list = lay().list
    check(rig.scroll != nil && rig.viewport.height > 0, "список лежит в прокрутке")
    let contentHeight = rig.scroll?.documentView?.frame.height ?? 0
    check(contentHeight > rig.viewport.height + 100, "список длиннее окна (\(Int(contentHeight)) против \(Int(rig.viewport.height)))")
    // Перетаскивание в прокрученном списке.
    rig.scrollTo(100)
    await pause(0.3)
    rig.remember()
    check(abs(rig.scrollY - 100) < 1, "список прокручен на 100")
    let visible = list.filter { (rig.rest[$0]?.minY ?? -1) > rig.viewport.minY + 4 && (rig.rest[$0]?.maxY ?? 9999) < rig.viewport.maxY - 4 }
    check(visible.count >= 4, "в окне видно не меньше четырёх строк")
    guard visible.count >= 4 else { rig.close(); return }
    let m = visible[1]
    let target = visible[3]
    let s = center(rig.rest[m]!)
    let aim = center(rig.rest[target]!)
    let trace = await drag(rig, "scrolled", from: s, via: [aim], grabbed: m)
    var expected = list.filter { $0 != m }
    expected.insert(m, at: list.firstIndex(of: target)!)
    check(lay().list == expected, "прокрученный список: строка легла на нужное место")
    check(trace.maxOutside < 1 && trace.maxLag < 6, "прокрученный список: копия 1:1 (отрыв \(Int(trace.maxOutside)), отставание \(Int(trace.maxLag)))")
    rig.close()

    // Автопрокрутка до «Скрытые».
    await prepare()
    rig = await Rig(height: 540)
    let first = lay().list[0]
    let start = center(rig.rest[first]!)
    let view = rig.viewport
    check(rig.restHeader.minY > view.maxY, "заголовок «Скрытые» вне окна до прокрутки")
    let edge = CGPoint(x: start.x, y: view.maxY - 6)
    var maxScroll: CGFloat = 0
    let t = await drag(rig, "autoscroll", from: start, via: [edge], grabbed: first, hold: 0, release: false, frames: false)
    for i in 0..<40 {
        await pause(0.05)
        maxScroll = max(maxScroll, rig.scrollY)
        if i % 8 == 0 { rig.snapshot("autoscroll-hold-\(i)", to: seqDir) }
    }
    check(maxScroll > 60, "у нижнего края список сам прокручивается (на \(Int(maxScroll)) pt)")
    let header = SidebarProbe.header
    check(header.minY >= view.minY && header.maxY <= view.maxY + 1, "после автопрокрутки заголовок «Скрытые» в окне")
    let drop = CGPoint(x: header.midX, y: header.midY)
    rig.dragged(drop)
    await pause(0.3)
    rig.up(drop)
    await pause(0.7)
    check(lay().hidden == [first], "доехали до «Скрытые» и бросили: модуль скрыт")
    check(t.maxOutside < 1, "автопрокрутка: курсор внутри копии (отрыв \(Int(t.maxOutside)))")
    check(SidebarProbe.copy == nil, "автопрокрутка: копия убрана, таймер не крутится")
    rig.close()
}

@MainActor func run() async {
    let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let appsDir = workRoot.appendingPathComponent("Apps")
    try? FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: seqDir, withIntermediateDirectories: true)
    let paths = SatellitePaths(appsDir: appsDir, agentsDir: workRoot.appendingPathComponent("Agents"))
    SatelliteRegistry.standEnvironment = SatelliteEnvironment(
        paths: paths, defaults: Kit.defaults,
        installer: SatelliteInstaller(paths: paths, launchctl: { _ in }, download: { $0 }, verify: { _, _ in }),
        commands: SatelliteCommands(status: { _ in throw LinkError.timeout }, setEnabled: { _, _ in }, openWindow: { _ in }),
        loadCatalog: { Data(#"{"schema":1,"apps":[]}"#.utf8) },
        hubVersion: "0.6.0", modules: .shared)
    let icons = ModuleMenuIcons.shared
    icons.makeItem = { _ in nil }
    icons.tellUtility = { _, _ in }
    icons.start()
    SidebarModel.shared.start()
    DashboardLive.testBuiltIn = [:]
    // SIDEBAR_DRAG_ONLY=clicks,hidden — только эти сценарии (отладка).
    let only = ProcessInfo.processInfo.environment["SIDEBAR_DRAG_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    let scenarios: [(String, () async -> Void)] = [("clicks", clicks), ("reorder", reorder), ("between", between),
                                                   ("hidden", hiddenSection), ("cancelling", cancelling), ("scrolled", scrolled)]
    for (name, scenario) in scenarios where only?.contains(name) ?? true { await scenario() }
    for m in all { _ = SidebarModel.shared.send(m, to: .list); Kit.defaults.removeObject(forKey: MenuBarIcon.key(m)) }
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
