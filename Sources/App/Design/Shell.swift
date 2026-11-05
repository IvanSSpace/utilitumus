import SwiftUI

// Каркас окна: фон, боковая панель. Экранам модулей это не нужно — только для `MainView`.

// MARK: - Фон

/// Один градиент текущего модуля (или нейтральный графитовый на дашборде). Цвета интерполируются:
/// смена модуля и темы плавно перетекает за 0,35 с. Анимируется только этот слой, не страница.
/// `neutral` — страница без модуля (дашборд): нейтральный графитовый фон вместо цвета категории.
struct DSBackground: View {
    let module: Module
    var neutral = false
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let colors = neutral && theme.followsModule ? DSTheme.graphite.background(module) : theme.background(module)
        let stops = BackgroundStops(colors)
        ZStack {
            Color(white: 0.05)
            BlendedGradient(stops: stops)
        }
        .animation(.easeInOut(duration: 0.35), value: stops)
    }
}

/// Два цвета градиента как вектор: SwiftUI умеет интерполировать только числа.
private struct BackgroundStops: VectorArithmetic, Equatable {
    var v: [Double]

    init(_ colors: [Color]) {
        v = colors.prefix(2).flatMap { color -> [Double] in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            return [c.redComponent, c.greenComponent, c.blueComponent]
        }
        while v.count < 6 { v.append(0) }
    }
    private init(raw: [Double]) { v = raw }

    static var zero: BackgroundStops { BackgroundStops(raw: Array(repeating: 0, count: 6)) }
    static func + (a: Self, b: Self) -> Self { BackgroundStops(raw: zip(a.v, b.v).map(+)) }
    static func - (a: Self, b: Self) -> Self { BackgroundStops(raw: zip(a.v, b.v).map(-)) }
    mutating func scale(by rhs: Double) { v = v.map { $0 * rhs } }
    var magnitudeSquared: Double { v.reduce(0) { $0 + $1 * $1 } }
}

private struct BlendedGradient: View, Animatable {
    var stops: BackgroundStops
    var animatableData: BackgroundStops {
        get { stops }
        set { stops = newValue }
    }

    var body: some View {
        let v = stops.v
        LinearGradient(colors: [Color(.sRGB, red: v[0], green: v[1], blue: v[2]),
                                Color(.sRGB, red: v[3], green: v[4], blue: v[5])],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension DSTheme {
    /// Меняется ли фон от модуля к модулю (иначе кроссфейд не нужен).
    var followsModule: Bool { self == .calm || self == .vivid }
}

// MARK: - Минимальный размер окна

/// `NSHostingView` умеет сообщать окну размеры содержимого, не зная его типа, только через протокол.
private protocol HostingSizing: AnyObject { func stopReportingSizes() }
extension NSHostingView: HostingSizing {
    fileprivate func stopReportingSizes() { sizingOptions = [] }
}

/// Минимальный размер окна задаётся окну, а не `.frame(minWidth:minHeight:)` на корне: из-за рамки
/// `NSHostingView` на каждое изменение содержимого заново мерил бы всё дерево. Размеры содержимого
/// окну больше не сообщаются, поэтому и предел задаём явно.
struct WindowMinSize: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> MinSizeView { MinSizeView(size: NSSize(width: width, height: height)) }
    func updateNSView(_ nsView: MinSizeView, context: Context) {}

    final class MinSizeView: NSView {
        let size: NSSize
        init(size: NSSize) {
            self.size = size
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            (window.contentView as? HostingSizing)?.stopReportingSizes()
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(apply), name: name, object: window)
            }
            // Сразу после остановки измерения хостинг-вью сбрасывает предел: выставляем на следующем витке.
            DispatchQueue.main.async { [weak self] in
                self?.apply()
                self?.growToMinimum()
            }
        }

        /// Дешёвая сверка: если кто-то сбросил предел, возвращаем.
        @objc private func apply() {
            guard let window, window.contentMinSize != size else { return }
            window.contentMinSize = size
        }

        /// Если окно уже меньше предела (запомненный размер), растягиваем до него.
        private func growToMinimum() {
            guard let window else { return }
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < size.width || content.height < size.height {
                window.setContentSize(NSSize(width: max(content.width, size.width), height: max(content.height, size.height)))
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

// MARK: - Боковая панель

struct DSSidebar: View {
    let current: Module?
    @Binding var showDashboard: Bool
    @Binding var showStore: Bool
    @Binding var showAbout: Bool
    @Binding var peeked: Module?
    @Binding var selection: Module
    @ObservedObject private var modules = ModuleManager.shared
    /// Последний открытый модуль каждой категории: вкладка возвращает на него.
    @State private var last: [String: Module] = [:]
    /// Модуль, который тянут, и место, куда он ляжет, если отпустить.
    @State private var dragging: Module?
    @State private var drop: DropMark?
    /// Сдвиг и прозрачность списка модулей при смене вкладки: только слой, layout не трогают.
    @State private var listShift: CGFloat = 0
    @State private var listOpacity: Double = 1
    @AppStorage(PageMode.storageKey) private var pageModeRaw = PageMode.fast.rawValue

    /// Категория выбранной вкладки. На дашборде вкладки не выбраны, в списке — все модули.
    private var activeCategory: ModuleCategory? {
        (showDashboard && !showAbout) || showStore ? nil : (peeked ?? current ?? selection).category
    }

    var body: some View {
        // Список модулей панели считаем один раз за body.
        let shown = modules.shownModules
        let enabledCategories = Set(shown.map { $0.category.id })
        return VStack(alignment: .leading, spacing: 0) {
            // Место под светофоры и кнопку скрытия панели.
            Spacer().frame(height: 46)
            // Строка «Дашборд» пока скрыта: страница и код на месте, включается `DS.dashboardInSidebar`.
            if DS.dashboardInSidebar {
                DSDashboardRow(icon: "square.grid.2x2", title: "Дашборд", help: "Дашборд (⌘0)",
                               selected: showDashboard && !showAbout && !showStore) {
                    peeked = nil
                    showAbout = false
                    showStore = false
                    showDashboard = true
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            DSCategoryTabs(active: activeCategory, enabled: { enabledCategories.contains($0.id) }, pick: pick)
                .padding(.horizontal, 10).padding(.bottom, 6)
            list(shown)
            DSSidebarFooter(showAbout: $showAbout, showStore: $showStore, peeked: $peeked)
        }
        .onChange(of: current, initial: true) { _, module in
            if let module { last[module.category.id] = module }
        }
        .onChange(of: activeCategory) { old, new in slideList(from: old, to: new) }
        // Рамку фокуса клавиатуры в панели не рисуем: после клика кнопка получала фокус, и вокруг неё
        // появлялась синяя рамка. Строки и ссылки подвала кликаются мышью, Tab по ним не нужен.
        .focusEffectDisabled()
    }

    /// Список модулей коротко сдвигается в ту же сторону, что и страница: вкладка правее — приезжает справа.
    /// В «Экономном» режиме анимаций нет.
    private func slideList(from old: ModuleCategory?, to new: ModuleCategory?) {
        guard (PageMode(rawValue: pageModeRaw) ?? .fast) == .fast,
              let old, let new, old != new,
              let from = ModuleCategory.all.firstIndex(of: old), let to = ModuleCategory.all.firstIndex(of: new)
        else { return }
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) {
            listShift = to > from ? 24 : -24
            listOpacity = 0
        }
        // Конечное значение — на следующем витке, иначе SwiftUI склеит оба изменения и начало не отрисует.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                listShift = 0
                listOpacity = 1
            }
        }
    }

    private func list(_ shown: [Module]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let category = activeCategory {
                    rows(category, shown: shown)
                } else {
                    // На дашборде и в сторе — все модули подряд (без статусов, чтобы влезли над футером),
                    // перетаскивать здесь нечего: порядок меняют внутри вкладки.
                    DSAllModulesHeading()
                    ForEach(ModuleCategory.all.flatMap { category in shown.filter { $0.category == category } }) {
                        row($0, withStatus: false)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .offset(x: listShift)
        .opacity(listOpacity)
    }

    private func shownModules(in category: ModuleCategory) -> [Module] {
        modules.shownModules.filter { $0.category == category }
    }

    @ViewBuilder
    private func rows(_ category: ModuleCategory, shown: [Module]) -> some View {
        let items = shown.filter { $0.category == category }
        ForEach(items) { module in
            let status = category.showsStatus
            row(module, withStatus: status)
                .overlay(alignment: drop?.below == true ? .bottom : .top) {
                    // Линия вставки: сверху или снизу строки, куда ляжет модуль.
                    if drop?.module == module { DSDropLine() }
                }
                .onDrag {
                    dragging = module
                    return NSItemProvider(object: module.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: SidebarDrop(module: module, height: status ? 46 : 38, items: items,
                                                           dragging: dragging, mark: $drop) { from, to in
                    dragging = nil
                    move(items, from: IndexSet(integer: from), to: to)
                })
        }
    }

    /// Вкладка: на последний открытый модуль категории (или первый в панели). На той же вкладке — ничего.
    private func pick(_ category: ModuleCategory) {
        if category == activeCategory && !showAbout && !showStore && peeked == nil { return }
        let shown = shownModules(in: category)
        guard let target = last[category.id].flatMap({ shown.contains($0) ? $0 : nil }) ?? shown.first else { return }
        selection = target
        peeked = nil
        showAbout = false
        showStore = false
        showDashboard = false
    }

    private func row(_ module: Module, withStatus: Bool) -> some View {
        let on = modules.isOn(module)
        let selected = !showDashboard && !showAbout && !showStore && peeked == nil && current == module
        let open = {
            selection = module
            peeked = nil
            showAbout = false
            showStore = false
            showDashboard = false
        }
        return Group {
            if withStatus {
                DSStatusRow(module: module, on: on, selected: selected, action: open)
            } else {
                DSSidebarRow(module: module, on: on, status: nil, selected: selected, action: open)
            }
        }
        .contextMenu {
            let on = modules.isOn(module)
            Button(on ? "Выключить модуль" : "Включить модуль") { modules.setOn(module, !on) }
            Button("Скрыть из панели") { modules.setHidden(module, true) }
            Divider()
            Button("Настройки…") { modules.settingsShown = true }
        }
    }

    /// Перетаскивание только внутри категории: индексы категории переводим в индексы общего списка панели.
    private func move(_ items: [Module], from source: IndexSet, to destination: Int) {
        let shown = modules.shownModules
        let global = items.compactMap { shown.firstIndex(of: $0) }
        let to = destination < global.count ? global[destination] : (global.last ?? 0) + 1
        modules.moveShown(from: IndexSet(source.map { global[$0] }), to: to)
    }
}

/// Строка «Дашборд» / «Стор» над вкладками.
private struct DSDashboardRow: View {
    let icon: String
    let title: String
    let help: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .semibold)).frame(width: 24)
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.6))
            Text(title).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                   normal: selected ? .white.opacity(0.13) : .clear,
                   hovered: selected ? .white.opacity(0.13) : .white.opacity(0.06))
        .onTapGesture(perform: action)
        .help(help)
        .accessibilityAddTraits(.isButton)
    }
}

/// Три вкладки-пилюли: Фоном, Под рукой, С ИИ. Выбранная залита цветом категории.
private struct DSCategoryTabs: View {
    let active: ModuleCategory?
    let enabled: (ModuleCategory) -> Bool
    let pick: (ModuleCategory) -> Void
    @Environment(\.dsTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ModuleCategory.all) { category in
                let selected = category == active
                let tint = theme.categoryColor(category)
                let available = enabled(category)
                VStack(spacing: 4) {
                    Image(systemName: category.icon).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint.opacity(selected ? 1 : 0.65))
                    Text(category.title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.5))
                        .lineLimit(1).fixedSize()
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 0.6))
                        .opacity(selected ? 1 : 0)
                )
                .opacity(available ? 1 : 0.4)
                .contentShape(Rectangle())
                .onTapGesture { if available { pick(category) } }
                .help(category.subtitle)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
    }
}

/// Заголовок общего списка на дашборде: вкладки не выбраны, модули идут подряд.
private struct DSAllModulesHeading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Все модули").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text("Вкладка выберется сама").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.leading, 10).padding(.top, 4).padding(.bottom, 6)
    }
}

// MARK: - Перетаскивание

/// Куда ляжет перетаскиваемый модуль: перед строкой `module` или после неё.
struct DropMark: Equatable {
    let module: Module
    let below: Bool
}

/// Линия вставки между строками.
private struct DSDropLine: View {
    @Environment(\.dsTint) private var tint

    var body: some View {
        Capsule().fill(tint).frame(height: 2).padding(.horizontal, 4).offset(y: 0)
            .allowsHitTesting(false)
    }
}

/// Приём перетаскивания на строку: только из своей категории; верхняя половина строки — «перед ней»,
/// нижняя — «после». Сам перенос делает `done(откуда, куда)` в индексах категории.
private struct SidebarDrop: DropDelegate {
    let module: Module
    let height: CGFloat
    let items: [Module]
    let dragging: Module?
    @Binding var mark: DropMark?
    let done: (Int, Int) -> Void

    private var allowed: Bool { dragging.map { $0.category == module.category } ?? false }

    func validateDrop(info: DropInfo) -> Bool { allowed }

    func dropEntered(info: DropInfo) { mark = allowed ? DropMark(module: module, below: info.location.y > height / 2) : nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard allowed else { return DropProposal(operation: .forbidden) }
        let new = DropMark(module: module, below: info.location.y > height / 2)
        if new != mark { mark = new }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { if mark?.module == module { mark = nil } }

    func performDrop(info: DropInfo) -> Bool {
        defer { mark = nil }
        guard allowed, let dragging, let from = items.firstIndex(of: dragging), let at = items.firstIndex(of: module)
        else { return false }
        done(from, info.location.y > height / 2 ? at + 1 : at)
        return true
    }
}
// MARK: - Скрытие панели

extension DS {
    /// Показывать ли в панели строку «Дашборд». Пока скрыта: страница остаётся, стартовая — первый модуль.
    static let dashboardInSidebar = false
    /// Ключ `@AppStorage`: скрыта ли боковая панель.
    static let sidebarHiddenKey = "Design.SidebarHidden"
}

/// Кнопка скрытия/показа панели рядом со светофорами. Остаётся видна и при скрытой панели.
/// Положение берём у настоящей кнопки «зелёный» окна, чтобы не гадать с отступами системы.
/// Ставится как `.overlay(alignment: .topLeading)`: сама кнопка размером с себя, а не на всё окно.
struct DSSidebarToggle: View {
    @Binding var hidden: Bool
    @State private var anchor = CGPoint(x: 86, y: 20)
    @State private var hover = false

    var body: some View {
        Button { hidden.toggle() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.65))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? .white.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .help(hidden ? "Показать боковую панель (⌃⌘S)" : "Скрыть боковую панель (⌃⌘S)")
        .background(TrafficLightProbe(anchor: $anchor))
        // Левый край кнопки — правее «зелёной» на 8 pt, центр по вертикали — на её середине.
        .padding(.leading, anchor.x).padding(.top, anchor.y - 12)
    }
}

/// Читает положение кнопки «zoom» окна: справа от неё ставим переключатель панели.
private struct TrafficLightProbe: NSViewRepresentable {
    @Binding var anchor: CGPoint

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { point in
            if point != anchor { DispatchQueue.main.async { anchor = point } }
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: ((CGPoint) -> Void)?

        // Замерщик лежит под кнопкой и кликов не берёт.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            // Светофоры не двигаются при изменении размера окна — слушаем только выход из полного экрана.
            NotificationCenter.default.addObserver(self, selector: #selector(measure),
                                                   name: NSWindow.didExitFullScreenNotification, object: window)
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        @objc private func measure() {
            guard let window, let zoom = window.standardWindowButton(.zoomButton),
                  let superview = zoom.superview, let content = window.contentView else { return }
            let frame = superview.convert(zoom.frame, to: content)
            // Координаты содержимого — от нижнего края; SwiftUI считает от верхнего.
            let y = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
            guard frame.maxX > 0, y > 0 else { return }
            onChange?(CGPoint(x: frame.maxX + 8, y: y))
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// Строка со статусом из дашборда: наблюдает только статус своего модуля.
private struct DSStatusRow: View {
    let module: Module
    let on: Bool
    let selected: Bool
    let action: () -> Void
    @ObservedObject private var slot: DashSlot

    init(module: Module, on: Bool, selected: Bool, action: @escaping () -> Void) {
        self.module = module
        self.on = on
        self.selected = selected
        self.action = action
        slot = DashboardLive.slot(module)
    }

    var body: some View {
        DSSidebarRow(module: module, on: on, status: (slot.state.text, slot.state.attention),
                     selected: selected, action: action)
            .onAppear { slot.attach() }
            .onDisappear { slot.detach() }
    }
}

/// Строка модуля: значок, название, справа точка «включён» или «выкл». Выбранная залита оттенком.
/// В категории со статусами вторая строка — живой статус вместо «выкл».
private struct DSSidebarRow: View {
    let module: Module
    let on: Bool
    var status: (text: String, attention: Bool)?
    let selected: Bool
    let action: () -> Void
    @Environment(\.dsTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 24).opacity(on ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(on ? (selected ? 1 : 0.85) : 0.5))
                    .lineLimit(1).minimumScaleFactor(0.85)
                if let status {
                    Text(status.text).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(status.attention ? AnyShapeStyle(Color.orange)
                                                          : AnyShapeStyle(.white.opacity(on ? (selected ? 0.6 : 0.42) : 0.3)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // У строки со статусом точки нет: статус сам говорит, включён модуль, а ширины ему и так мало.
            if status == nil {
                if on {
                    Circle().fill(theme.tone(module)).frame(width: 6, height: 6)
                } else {
                    Text("выкл").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: status == nil ? 38 : 46)
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                   normal: selected ? theme.selection(module) : .clear,
                   hovered: selected ? theme.selection(module) : .white.opacity(0.06))
        .onTapGesture(perform: action)
        .help(on ? "" : "Выключен — открой, чтобы включить")
        .accessibilityAddTraits(.isButton)
    }
}

/// Внизу панели: обновление, «Скрытые», «Стор», «Что нового», «Настройки», «О проекте», версия.
struct DSSidebarFooter: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject private var modules = ModuleManager.shared
    @Binding var showAbout: Bool
    @Binding var showStore: Bool
    @Binding var peeked: Module?
    /// Свёрнутость списка помним между запусками: скрытые открывают редко, но привычка остаётся.
    @AppStorage("HiddenModulesExpanded") private var hiddenExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch updater.state {
            case let .available(version, _, _):
                DSButton("Обновить до \(version)", icon: "arrow.down.circle.fill", style: .primary, small: true) {
                    updater.install()
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Устанавливаю…").font(.caption)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            case .upToDate:
                Text("Обновлений нет")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 10).padding(.bottom, 4)
            default:
                EmptyView()
            }
            hiddenSection
            // Стор внизу, рядом с настройками: открывают его редко, а наверху он занимал много места.
            FooterLink(icon: "bag", title: "Стор", selected: showStore) {
                peeked = nil
                showAbout = false
                showStore = true
            }
            FooterLink(icon: "sparkles", title: "Что нового") { WhatsNew.shared.isShown = true }
            // Оформление, Dock и режим страниц; без этой строки туда попадали только через Cmd+, или контекстное меню.
            FooterLink(icon: "gearshape", title: "Настройки") { modules.settingsShown = true }
            FooterLink(icon: "info.circle", title: "О проекте", selected: showAbout) { showStore = false; showAbout = true }
            HStack {
                // Клик по версии — «Обновление стороннего программного обеспечения»: что нового.
                Button("Версия \(updater.currentVersion)") { WhatsNew.shared.isShown = true }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Что изменилось в последних версиях")
                Spacer()
                Button {
                    updater.check()
                } label: {
                    if updater.state == .checking {
                        ProgressView().controlSize(.mini)
                    } else if updater.state == .upToDate {
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(updater.state == .upToDate ? "Установлена последняя версия" : "Проверить обновления")
                .disabled(updater.state == .checking || updater.state == .installing)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 10).padding(.top, 6)
        }
        .padding(.horizontal, 10)
        // Воздух снизу и слева такой же, как у карточки страницы (10 pt).
        .padding(.bottom, 10)
    }

    /// «Скрытые · N» над «Что нового»: без скрытых модулей строки нет совсем.
    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = modules.hiddenModules
        if !hidden.isEmpty {
            FooterLink(icon: "eye.slash", title: "Скрытые · \(hidden.count)", dim: true,
                       chevron: hiddenExpanded) { hiddenExpanded.toggle() }
            if hiddenExpanded {
                ForEach(hidden) { module in
                    HiddenRow(module: module, selected: peeked == module && !showAbout) {
                        // Разовый показ: состояние не меняем, выделение в основном списке снимается через peeked.
                        peeked = module
                        showAbout = false
                    }
                    .contextMenu {
                        Button("Показать в панели") { modules.setHidden(module, false) }
                        Button(modules.isOn(module) ? "Выключить модуль" : "Включить модуль") {
                            modules.setOn(module, !modules.isOn(module))
                        }
                    }
                }
            }
        }
    }
}

/// Пункт внизу панели: значок и подпись, подсветка при наведении.
private struct FooterLink: View {
    let icon: String
    let title: String
    var selected = false
    var dim = false
    /// nil — шеврона нет; true/false — раскрыто/свёрнуто.
    var chevron: Bool?
    let action: () -> Void
    @Environment(\.dsTheme) private var theme
    @Environment(\.dsTint) private var tint

    init(icon: String, title: String, selected: Bool = false, dim: Bool = false, chevron: Bool? = nil,
         action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.selected = selected
        self.dim = dim
        self.chevron = chevron
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12.5)).frame(width: 24)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
            if let chevron {
                Image(systemName: chevron ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(.white.opacity(selected ? 1 : (dim ? 0.5 : 0.72)))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                   normal: selected ? tint.opacity(0.26) : .clear,
                   hovered: selected ? tint.opacity(0.26) : .white.opacity(0.06))
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }
}

private struct HiddenRow: View {
    let module: Module
    let selected: Bool
    let action: () -> Void
    @Environment(\.dsTint) private var tint

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 18).opacity(0.6).frame(width: 24)
            Text(module.title).font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                   normal: selected ? tint.opacity(0.26) : .clear,
                   hovered: selected ? tint.opacity(0.26) : .white.opacity(0.06))
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }
}
