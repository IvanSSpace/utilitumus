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
    var followsModule: Bool {
        switch self {
        case .dusk, .calm, .vivid, .custom: return true
        case .graphite, .midnight: return false
        }
    }
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
    @ObservedObject private var satellites = SatelliteRegistry.shared
    @ObservedObject private var icons = ModuleMenuIcons.shared

    /// Модуль, чья страница открыта прямо сейчас. Его могли выключить тумблером на этой странице:
    /// строка остаётся до ухода со страницы.
    private var openModule: Module? {
        showDashboard || showAbout || showStore || peeked != nil ? nil : current
    }

    /// Выбранная строка: открытая страница модуля (в том числе разовый показ скрытого).
    private var selected: Module? {
        showDashboard || showAbout || showStore ? nil : (peeked ?? current)
    }

    var body: some View {
        let layout = SidebarModel.layout(modules: modules, pins: Set(Module.allCases.filter { icons.isOn($0) }), open: openModule)
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
            // Ничего не установлено: подсказка ведёт в Стор.
            if layout.flattened.isEmpty {
                Text(ModuleScope.emptyNote ?? "Выбери модули в Сторе")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            SidebarContent(layout: layout, actions: actions, openModule: openModule)
            DSSidebarFooter(showAbout: $showAbout, showStore: $showStore, peeked: $peeked)
        }
        // Рамку фокуса клавиатуры в панели не рисуем: после клика кнопка получала фокус, и вокруг неё
        // появлялась синяя рамка. Строки и ссылки подвала кликаются мышью, Tab по ним не нужен.
        .focusEffectDisabled()
    }

    private var actions: SidebarActions {
        SidebarActions(
            selected: selected,
            // Точка и «выкл» в строке говорят о работе самого модуля; утилита выключается отдельно от установки.
            isOn: { modules.isExternal($0) ? satellites.isEnabled($0) : modules.isOn($0) },
            open: { module in
                // Скрытый открывается разовым показом: состояние не меняем.
                if modules.isHidden(module) {
                    peeked = module
                } else {
                    selection = module
                    peeked = nil
                }
                showAbout = false
                showStore = false
                showDashboard = false
            },
            showInfo: { modules.infoModule = $0 },
            remove: { StoreModel.shared.requestRemoval($0) })
    }
}

/// Строка «Дашборд» над панелью.
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

/// Внизу панели: обновление, «Стор», «Что нового», «Настройки», «О проекте», версия.
struct DSSidebarFooter: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var updates = UpdateAll.shared
    @Binding var showAbout: Bool
    @Binding var showStore: Bool
    @Binding var peeked: Module?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch updater.state {
            case let .available(version, _, _):
                DSButton("Обновить до \(version)", icon: "arrow.down.circle.fill", style: .primary, small: true) {
                    updater.install()
                }
                .frame(maxWidth: .infinity)
                // Перезапуск центра оборвал бы очередь обновлений утилит.
                .disabled(updates.running)
                .help(updates.running ? "Сначала закончится обновление утилит" : "")
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
            UpdateAllNotice()
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
        // Таймера нет: каталог перечитывается, когда человек вернулся в центр.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updates.checkIfStale()
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
