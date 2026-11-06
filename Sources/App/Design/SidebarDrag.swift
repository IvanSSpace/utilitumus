import SwiftUI
import AppKit

// Перетаскивание в боковой панели. Мышь ловит один AppKit-вид на всю панель (`SidebarTrackerView`), а не жесты
// у каждой строки: жест умирает, когда его вид переезжает или пропадает из раскладки, а здесь строки и плитки
// могут двигаться как угодно, пока кнопка зажата. Места считаются по числам (`SidebarMetrics`) и по прокрутке,
// которую читаем у `NSScrollView` в момент события, поэтому ничего не устаревает между кадрами.
// Состояние: `SidebarDrag` меняется, когда меняется цель; `SidebarFloat` — на каждое движение мыши (читает одна копия).

@MainActor
final class SidebarDrag: ObservableObject {
    @Published var module: Module?
    @Published var target: SidebarLayout.Target?
    /// Какой вид у поднятой копии: плитка или строка.
    @Published var kind: SidebarLayout.Zone = .list
    /// Кнопку отпустили: копия летит на место, раскладка уже показывает итог.
    @Published var settling = false
    /// Только что встал на место: короткая подсветка.
    @Published var landed: Module?
}

@MainActor
final class SidebarFloat: ObservableObject {
    /// Курсор в координатах панели. Меняется на каждое движение и никогда не анимируется: копия идёт 1:1.
    @Published var cursor: CGPoint = .zero
    /// Где в копии держит курсор (от её левого верхнего угла). Пружина, когда копия меняет вид.
    @Published var anchor: CGPoint = .zero
    /// Полёт на место после отпускания.
    @Published var landing: CGSize = .zero
    @Published var lifted = false
    @Published var fading = false
}

/// Анимация сдвигов. «Уменьшение движения» убирает пружину: всё встаёт сразу.
enum SidebarMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation? { reduced ? nil : .spring(response: 0.3, dampingFraction: 0.82) }
    /// Посадка копии на место: короткая и без раскачки, чтобы после неё подмена настоящей строкой была незаметна.
    static let landDuration = 0.18
    static var land: Animation? { reduced ? nil : .easeOut(duration: landDuration) }
}

@MainActor
final class SidebarSession: ObservableObject {
    let drag = SidebarDrag()
    let float = SidebarFloat()

    // Входы: обновляются при каждой отрисовке панели.
    var layout = SidebarLayout()
    var expanded = false
    var actions: SidebarActions?
    var openModule: Module?
    weak var scroll: NSScrollView?
    weak var tracker: SidebarTrackerView?

    private struct Press {
        let module: Module
        let zone: SidebarLayout.Zone
        let frame: CGRect
        let start: CGPoint
    }

    struct Counts {
        var pinned: Int
        var list: Int
        var hidden: Int
    }

    private var width: CGFloat { DS.sidebarWidth - 20 }
    private let padX: CGFloat = 10

    private var press: Press?
    /// С чего начали: зона, место и размер взятого.
    private var origin: Press?
    private var ignoring = false
    private var hintBlock: CGFloat = 0
    private var lastPoint = CGPoint.zero
    private var timer: Timer?
    private var commitWork: DispatchWorkItem?
    private var previousResponder: NSResponder?

    // MARK: Что под курсором

    /// Видимая часть списка в координатах панели.
    private func viewport() -> CGRect? {
        guard let scroll, let tracker else { return nil }
        return scroll.convert(scroll.bounds, to: tracker)
    }

    private var scrollY: CGFloat { scroll?.contentView.bounds.origin.y ?? 0 }

    /// Верх списка при `pinned` плитках (с пустым местом) в зоне закреплённых.
    private func viewportTop(pinned: Int) -> CGFloat {
        SidebarMetrics.pinnedHeight(count: pinned) + hintBlock + SidebarMetrics.pinnedBottomGap
    }

    private func counts(target: SidebarLayout.Target?, settling: Bool) -> Counts {
        let module = drag.module
        func n(_ zone: SidebarLayout.Zone) -> Int {
            layout.slots(zone, dragging: module, target: target, settling: settling).count
        }
        return Counts(pinned: n(.pinned), list: n(.list), hidden: n(.hidden))
    }

    private func currentCounts() -> Counts { counts(target: drag.target, settling: drag.settling) }

    /// Левый верх первой строки списка.
    private func listY(top: CGFloat) -> CGFloat { top - scrollY + SidebarMetrics.listTop }

    private func headerY(_ counts: Counts, top: CGFloat) -> CGFloat {
        listY(top: top) + SidebarMetrics.listHeight(count: counts.list) + SidebarMetrics.sectionGap
    }

    /// Место с номером `index` в зоне. Для свёрнутых «Скрытых» — сам заголовок.
    private func slotFrame(_ zone: SidebarLayout.Zone, _ index: Int, counts: Counts) -> CGRect {
        let top = viewportTop(pinned: counts.pinned)
        switch zone {
        case .pinned:
            let frames = SidebarMetrics.pinnedFrames(count: counts.pinned, width: width)
            guard frames.indices.contains(index) else { return .zero }
            return frames[index].offsetBy(dx: padX, dy: 0)
        case .list:
            return SidebarMetrics.listFrame(index: index, width: width).offsetBy(dx: padX, dy: listY(top: top))
        case .hidden:
            let header = headerY(counts, top: top)
            guard expanded else { return CGRect(x: padX, y: header, width: width, height: SidebarMetrics.headerHeight) }
            let rows = header + SidebarMetrics.headerHeight + SidebarMetrics.rowGap
            return SidebarMetrics.hiddenFrame(index: index, width: width).offsetBy(dx: padX, dy: rows)
        }
    }

    /// Строка или плитка под точкой (панель в покое).
    private func hit(at point: CGPoint) -> Press? {
        guard drag.module == nil else { return nil }
        let idle = Counts(pinned: layout.pinned.count, list: layout.list.count, hidden: layout.hidden.count)
        // Покой: верх списка прямо из прокрутки, без расчёта; остаток (подсказка про вырез) запоминаем для хода.
        let view = viewport()
        if let view { hintBlock = view.minY - SidebarMetrics.pinnedHeight(count: idle.pinned) - SidebarMetrics.pinnedBottomGap }
        for (i, module) in layout.pinned.enumerated() {
            let frame = slotFrame(.pinned, i, counts: idle)
            if frame.contains(point) { return Press(module: module, zone: .pinned, frame: frame, start: point) }
        }
        guard let view, view.contains(point) else { return nil }
        for (i, module) in layout.list.enumerated() {
            let frame = slotFrame(.list, i, counts: idle)
            if frame.contains(point) { return Press(module: module, zone: .list, frame: frame, start: point) }
        }
        guard expanded else { return nil }
        for (i, module) in layout.hidden.enumerated() {
            let frame = slotFrame(.hidden, i, counts: idle)
            if frame.contains(point) { return Press(module: module, zone: .hidden, frame: frame, start: point) }
        }
        return nil
    }

    /// Настоящий вид должен принять мышь здесь: на строке, плитке или всё время, пока что-то тянут.
    func owns(_ point: CGPoint) -> Bool {
        drag.module != nil || hit(at: point) != nil
    }

    func module(at point: CGPoint) -> Module? { hit(at: point)?.module }

    // MARK: Мышь

    func down(_ point: CGPoint) {
        ignoring = false
        press = hit(at: point)
    }

    func moved(_ point: CGPoint) {
        guard let press, !ignoring else { return }
        if drag.module == nil {
            guard hypot(point.x - press.start.x, point.y - press.start.y) >= 4 else { return }
            lift(press)
        }
        guard drag.module == press.module, !drag.settling else { return }
        lastPoint = point
        follow(point)
    }

    func up(_ point: CGPoint) {
        defer { press = nil }
        guard let press, !ignoring else { return }
        if drag.module == press.module {
            drop(cancelled: false)
        } else if drag.module == nil {
            // Сперва фокус, потом переход: поле на новой странице может забрать фокус себе.
            focusAfterClick(press.module)
            actions?.open(press.module)
        }
    }

    /// Клик ставит фокус на панель, иначе стрелки работали бы только после Tab. Клик по строке открытой страницы
    /// не забирает его у поля, в котором на этой странице набирают текст.
    private func focusAfterClick(_ module: Module) {
        guard let tracker, let window = tracker.window else { return }
        if module == openModule, window.firstResponder is NSText { return }
        tracker.takeFocus()
    }

    /// Стрелки: переход по панели, с ⌘⌥ — сдвиг открытого модуля в его зоне. false — панели нечего делать.
    func arrow(by delta: Int, reorder: Bool) -> Bool {
        guard let current = actions?.selected ?? layout.flattened.first else { return false }
        if reorder {
            withAnimation(SidebarMotion.spring) { _ = SidebarModel.shared.nudge(current, by: delta, open: openModule) }
            return true
        }
        let order = layout.pinned + layout.list + (expanded ? layout.hidden : [])
        guard let at = order.firstIndex(of: current) else {
            if let first = order.first { actions?.open(first) }
            return true
        }
        let next = min(max(at + delta, 0), order.count - 1)
        if next != at { actions?.open(order[next]) }
        return true
    }

    /// Esc: копия возвращается, остаток нажатия игнорируется.
    func cancel() {
        guard drag.module != nil, !drag.settling else { return }
        ignoring = true
        drop(cancelled: true)
    }

    // MARK: Подъём и ход

    private func lift(_ press: Press) {
        commitWork?.cancel()
        origin = press
        let grab = CGPoint(x: press.start.x - press.frame.minX, y: press.start.y - press.frame.minY)
        float.cursor = press.start
        float.anchor = grab
        float.landing = .zero
        float.fading = false
        float.lifted = true
        lastPoint = press.start
        drag.kind = press.zone
        drag.target = SidebarLayout.Target(zone: press.zone, index: layout.items(press.zone).firstIndex(of: press.module) ?? 0)
        drag.settling = false
        drag.landed = nil
        drag.module = press.module
        capture(true)
        startTimer()
    }

    /// Где курсор в копии такого вида и размера: та же доля, что при взятии, поэтому курсор всегда внутри копии.
    private func anchor(kind: SidebarLayout.Zone, pinned: Int) -> CGPoint {
        guard let origin else { return .zero }
        let size = SidebarMetrics.size(of: kind, pinnedCount: pinned, width: width)
        let grabX = (origin.start.x - origin.frame.minX) / max(origin.frame.width, 1)
        let grabY = (origin.start.y - origin.frame.minY) / max(origin.frame.height, 1)
        return CGPoint(x: min(max(grabX, 0), 1) * size.width, y: min(max(grabY, 0), 1) * size.height)
    }

    /// Копия за курсором без анимации, цель по точке с пружиной.
    private func follow(_ point: CGPoint) {
        guard let module = drag.module else { return }
        float.cursor = point
        let new = target(for: point, module: module)
        let kind = new?.zone ?? drag.kind
        let pinned = layout.slots(.pinned, dragging: module, target: new, settling: false).count
        let anchor = anchor(kind: kind, pinned: pinned)
        guard new != drag.target || kind != drag.kind || anchor != float.anchor else { return }
        withAnimation(SidebarMotion.spring) {
            drag.target = new
            drag.kind = kind
        }
        float.anchor = anchor
    }

    /// Куда целится точка. nil — вне панели, над подвалом или десятая плитка: вернуть на место.
    private func target(for point: CGPoint, module: Module) -> SidebarLayout.Target? {
        guard point.x > -14, point.x < DS.sidebarWidth + 14, let view = viewport() else { return nil }
        let now = currentCounts()
        let top = viewportTop(pinned: now.pinned)
        let others = layout.preview(module, target: nil).mapValues { $0.compactMap { $0 }.count }
        if point.y < top - 2 {
            guard layout.canMove(module, to: .pinned) else { return nil }
            let local = CGPoint(x: point.x - padX, y: point.y)
            return .init(zone: .pinned, index: SidebarMetrics.pinnedInsertion(point: local, others: others[.pinned] ?? 0, width: width))
        }
        guard point.y <= view.maxY else { return nil }
        let header = headerY(now, top: top)
        if point.y >= header - SidebarMetrics.sectionGap / 2 {
            let rows = layout.slots(.hidden, dragging: module, target: nil, settling: false).count
            guard expanded else { return .init(zone: .hidden, index: rows) }
            let y = point.y - (header + SidebarMetrics.headerHeight + SidebarMetrics.rowGap)
            return .init(zone: .hidden, index: SidebarMetrics.columnInsertion(y: y, others: rows, rowHeight: SidebarMetrics.hiddenRowHeight))
        }
        return .init(zone: .list, index: SidebarMetrics.columnInsertion(y: point.y - listY(top: top), others: others[.list] ?? 0,
                                                                         rowHeight: SidebarMetrics.rowHeight))
    }

    // MARK: Посадка

    private func drop(cancelled: Bool) {
        guard let module = drag.module, !drag.settling, let origin else { return }
        stopTimer()
        let wanted = cancelled ? nil : drag.target
        let target = wanted.flatMap { layout.canMove(module, to: $0.zone) ? $0 : nil }
        let kind = target?.zone ?? origin.zone
        let final = counts(target: target, settling: true)
        let index = target?.index ?? layout.items(origin.zone).firstIndex(of: module) ?? 0
        let slot = slotFrame(kind, index, counts: final)
        let fade = kind == .hidden && !expanded
        let anchor = anchor(kind: kind, pinned: final.pinned)
        withAnimation(SidebarMotion.spring) {
            drag.settling = true
            drag.target = target
            drag.kind = kind
        }
        float.anchor = anchor
        float.landing = CGSize(width: slot.minX - (float.cursor.x - anchor.x), height: slot.minY - (float.cursor.y - anchor.y))
        float.lifted = false
        float.fading = fade
        let work = DispatchWorkItem { [weak self] in self?.commit(module, target) }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (SidebarMotion.reduced ? 0 : SidebarMotion.landDuration + 0.02), execute: work)
    }

    /// Копия встала на место: меняем настоящие настройки и убираем копию без анимации (раскладка уже на месте).
    private func commit(_ module: Module, _ target: SidebarLayout.Target?) {
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) {
            if let target {
                var next = SidebarModel.shared.layout(open: openModule)
                if next.move(module, to: target.zone, at: target.index) { SidebarModel.shared.apply(next, moved: module, open: openModule) }
            }
            drag.module = nil
            drag.target = nil
            drag.settling = false
            float.lifted = false
            float.fading = false
            float.landing = .zero
            drag.landed = target == nil ? nil : module
        }
        origin = nil
        capture(false)
        if target != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                withAnimation(.easeOut(duration: 0.7)) { self?.drag.landed = nil }
            }
        }
    }

    func finish() {
        stopTimer()
        commitWork?.cancel()
        press = nil
        origin = nil
        if drag.module != nil {
            drag.module = nil
            drag.target = nil
            drag.settling = false
            float.lifted = false
        }
        capture(false)
    }

    // MARK: Клавиатура и автопрокрутка

    /// Пока что-то тянут, Esc приходит в вид-ловец: он на это время первый ответчик.
    private func capture(_ on: Bool) {
        guard let tracker, let window = tracker.window else { return }
        if on {
            previousResponder = window.firstResponder
            tracker.capturing = true
            window.makeFirstResponder(tracker)
        } else {
            tracker.capturing = false
            // Фокус был на панели после клика: там и остаётся, стрелки работают и после перетаскивания.
            if window.firstResponder === tracker, previousResponder !== tracker { window.makeFirstResponder(previousResponder) }
            previousResponder = nil
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoScroll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func autoScroll() {
        guard drag.module != nil, !drag.settling, let scroll, let view = viewport() else { return }
        let edge: CGFloat = 36
        var step: CGFloat = 0
        if lastPoint.y < view.minY + edge { step = -(edge - max(lastPoint.y - view.minY, 0)) / edge * 12 }
        if lastPoint.y > view.maxY - edge { step = (edge - max(view.maxY - lastPoint.y, 0)) / edge * 12 }
        guard step != 0, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let limit = max(document.frame.height - clip.bounds.height, 0)
        let y = min(max(clip.bounds.origin.y + step, 0), limit)
        guard y != clip.bounds.origin.y else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        follow(lastPoint)
    }

    // MARK: Меню

    func menu(for module: Module) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let zone = layout.zone(of: module)
        func add(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            item.isEnabled = enabled
            menu.addItem(item)
        }
        func send(_ zone: SidebarLayout.Zone) {
            withAnimation(SidebarMotion.spring) { _ = SidebarModel.shared.send(module, to: zone, open: openModule) }
        }
        add("Открыть") { [weak self] in self?.actions?.open(module) }
        if zone == .pinned {
            add("Открепить") { send(.list) }
        } else {
            add("Закрепить", enabled: layout.canMove(module, to: .pinned)) { send(.pinned) }
        }
        if zone == .hidden {
            add("Показать в списке") { send(.list) }
        } else {
            add("Скрыть") { send(.hidden) }
        }
        add("Как это работает") { [weak self] in self?.actions?.showInfo(module) }
        menu.addItem(.separator())
        add("Удалить модуль…") { [weak self] in self?.actions?.remove(module) }
        return menu
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

// MARK: - Вид-ловец

/// Лежит поверх панели и берёт мышь только над строками и плитками (`hitTest`): заголовок «Скрытые», подвал,
/// наведение и подсказки работают как раньше. Нажатие без движения — клик, движение от 4 pt — перетаскивание.
final class SidebarTrackerView: NSView {
    var session: SidebarSession?
    /// Пока тянут, вид принимает клавиши (Esc), иначе не отбирает фокус у панели.
    var capturing = false
    /// Сам вид фокус не берёт: окно отдало бы его при любом нажатии, и поле на странице теряло бы фокус. Только по `takeFocus`.
    private var focusing = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { capturing || focusing }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let session, !isHidden else { return nil }
        return MainActor.assumeIsolated { session.owns(convert(point, from: superview)) ? self : nil }
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    func takeFocus() {
        focusing = true
        window?.makeFirstResponder(self)
        focusing = false
    }

    override func mouseDown(with event: NSEvent) {
        // Ctrl-клик — та же правая кнопка, если окно само не показало меню через `menu(for:)`.
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        MainActor.assumeIsolated { session?.down(local(event)) }
    }
    override func mouseDragged(with event: NSEvent) { MainActor.assumeIsolated { session?.moved(local(event)) } }
    override func mouseUp(with event: NSEvent) { MainActor.assumeIsolated { session?.up(local(event)) } }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let session, let module = session.module(at: local(event)) else { return }
            let menu = session.menu(for: module)
            #if KIT_TEST_DEFAULTS
            // Настоящее меню держит цикл событий; в проверке его пункты кладём в пробу.
            SidebarProbe.menu = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            #else
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            #endif
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        #if KIT_TEST_DEFAULTS
        return nil
        #else
        return MainActor.assumeIsolated {
            guard let session, let module = session.module(at: local(event)) else { return nil }
            return session.menu(for: module)
        }
        #endif
    }

    override func scrollWheel(with event: NSEvent) {
        MainActor.assumeIsolated {
            if let scroll = session?.scroll { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, capturing {
            MainActor.assumeIsolated { session?.cancel() }
        } else if !capturing, event.keyCode == 125 || event.keyCode == 126,
                  MainActor.assumeIsolated({ session?.arrow(by: event.keyCode == 126 ? -1 : 1,
                                                            reorder: event.modifierFlags.isSuperset(of: [.command, .option])) == true }) {
            return
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Внутренний вид со списком под видом-ловцом, в одном контейнере. Ловец — соседний вид над списком, а не слой SwiftUI:
/// иначе SwiftUI считал бы строки закрытыми и наведение с подсказками на них пропало бы.
final class SidebarContainer: NSView {
    let hosting: NSHostingView<SidebarListRoot>
    let tracker = SidebarTrackerView()

    init(root: SidebarListRoot) {
        hosting = NSHostingView(rootView: root)
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        addSubview(tracker)
        tracker.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        tracker.frame = bounds
    }
}

/// Корень внутреннего вида: окружение окна не переходит во вложенный `NSHostingView`, поэтому тема и акцент передаются явно.
struct SidebarListRoot: View {
    let session: SidebarSession
    let layout: SidebarLayout
    let actions: SidebarActions
    let expanded: Binding<Bool>
    let theme: DSTheme
    let tint: Color

    var body: some View {
        SidebarList(session: session, layout: layout, actions: actions, expanded: expanded)
            .environment(\.dsTheme, theme)
            .environment(\.dsTint, tint)
            .environment(\.colorScheme, .dark)
    }
}

struct SidebarHost: NSViewRepresentable {
    let session: SidebarSession
    let layout: SidebarLayout
    let actions: SidebarActions
    let openModule: Module?
    let expanded: Binding<Bool>
    let theme: DSTheme
    let tint: Color

    private var root: SidebarListRoot {
        SidebarListRoot(session: session, layout: layout, actions: actions, expanded: expanded, theme: theme, tint: tint)
    }

    func makeNSView(context: Context) -> SidebarContainer {
        let view = SidebarContainer(root: root)
        view.tracker.session = session
        session.tracker = view.tracker
        return view
    }

    func updateNSView(_ view: SidebarContainer, context: Context) {
        view.tracker.session = session
        session.tracker = view.tracker
        session.layout = layout
        session.actions = actions
        session.openModule = openModule
        session.expanded = expanded.wrappedValue
        view.hosting.rootView = root
    }
}
