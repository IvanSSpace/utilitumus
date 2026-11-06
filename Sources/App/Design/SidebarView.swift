import SwiftUI
import AppKit
import Combine

// Содержимое боковой панели: закреплённые плитки сверху, список с живым статусом, свёртка «Скрытые».
// Перетаскивание своё, как в Arc: жест с порогом, поднятая копия едет за курсором, остальные расступаются,
// отпускание ставит копию на место. Места считаются по числам (`SidebarMetrics`), поэтому нет замеров на каждый кадр.
// Состояние перетаскивания лежит в двух объектах: `SidebarDrag` меняется только когда меняется цель,
// `SidebarFloat` — на каждое движение мыши, и его читает одна поднятая копия, а не вся панель.

// MARK: - Состояние перетаскивания

@MainActor
final class SidebarDrag: ObservableObject {
    @Published var module: Module?
    @Published var target: SidebarLayout.Target?
    /// Какой вид у поднятой копии: плитка или строка.
    @Published var kind: SidebarLayout.Zone = .list
}

@MainActor
final class SidebarFloat: ObservableObject {
    @Published var origin: CGPoint = .zero
    @Published var lifted = false
}

/// Измеренное один раз за раскладку; не состояние вида, поэтому вид из-за него не пересобирается.
@MainActor
final class SidebarGeo {
    var viewport: CGRect = .zero
    var pinnedOrigin: CGPoint = .zero
    weak var scroll: NSScrollView?
    var scrollY: CGFloat { scroll?.contentView.bounds.origin.y ?? 0 }
}

private struct ViewportKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct PinnedOriginKey: PreferenceKey {
    static let defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

// MARK: - Окружение вида

struct SidebarActions {
    /// Модуль, чья страница открыта сейчас (nil на дашборде, в Сторе и «О проекте»).
    var selected: Module?
    var isOn: (Module) -> Bool
    var open: (Module) -> Void
    var showInfo: (Module) -> Void
    var remove: (Module) -> Void
}

/// Анимация сдвигов. «Уменьшение движения» убирает пружину: всё встаёт сразу.
enum SidebarMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation? { reduced ? nil : .spring(response: 0.3, dampingFraction: 0.82) }
}

// MARK: - Содержимое

struct SidebarContent: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    /// Открытая страница, которую могли выключить на ней: строка остаётся до ухода.
    let openModule: Module?

    @StateObject private var drag = SidebarDrag()
    @StateObject private var float = SidebarFloat()
    @State private var geo = SidebarGeo()
    @AppStorage("HiddenModulesExpanded") private var expanded = false

    @State private var grab = CGPoint.zero
    @State private var cancelled = false
    @State private var lastPoint = CGPoint.zero
    @State private var escMonitor: Any?
    @State private var scrollTimer: Timer?
    @State private var expandWork: DispatchWorkItem?
    @Environment(\.dsTheme) private var theme

    #if KIT_TEST_DEFAULTS
    /// Проверка ставит панель в середину перетаскивания: кто, куда целится и где поднятая копия.
    @MainActor static var testDrag: (Module, SidebarLayout.Target, CGPoint)?
    #endif

    private let width = DS.sidebarWidth - 20
    private let listTop: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            PinnedZone(layout: layout, actions: actions, drag: drag, width: width, gesture: gesture, menu: menu)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PinnedOriginKey.self, value: proxy.frame(in: .named("sb")).origin)
                })
                .padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ListZone(layout: layout, actions: actions, drag: drag, width: width, gesture: gesture, menu: menu)
                    HiddenSection(layout: layout, actions: actions, drag: drag, width: width, expanded: $expanded,
                                  gesture: gesture, menu: menu)
                        .padding(.top, SidebarMetrics.sectionGap)
                }
                .padding(.horizontal, 10).padding(.top, listTop).padding(.bottom, 6)
                .background(ScrollProbe { geo.scroll = $0 })
            }
            .scrollIndicators(.never)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ViewportKey.self, value: proxy.frame(in: .named("sb")))
            })
        }
        .coordinateSpace(name: "sb")
        .onPreferenceChange(ViewportKey.self) { geo.viewport = $0 }
        .onPreferenceChange(PinnedOriginKey.self) { geo.pinnedOrigin = $0 }
        .overlay(alignment: .topLeading) { FloatingCopy(layout: layout, drag: drag, float: float, actions: actions, width: width) }
        .onDisappear { finishSession() }
        #if KIT_TEST_DEFAULTS
        .onAppear {
            if let test = Self.testDrag {
                drag.module = test.0
                drag.target = test.1
                drag.kind = test.1.zone
                float.origin = test.2
                float.lifted = true
            }
        }
        #endif
        .focusable()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in key(press) }
    }

    // MARK: Клавиатура

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let delta = press.key == .upArrow ? -1 : 1
        let reorder = press.modifiers.contains(.command) && press.modifiers.contains(.option)
        guard let current = actions.selected ?? layout.flattened.first else { return .ignored }
        if reorder {
            withAnimation(SidebarMotion.spring) { _ = SidebarModel.shared.nudge(current, by: delta, open: openModule) }
            return .handled
        }
        let order = layout.pinned + layout.list + (expanded ? layout.hidden : [])
        guard let at = order.firstIndex(of: current) else {
            if let first = order.first { actions.open(first) }
            return .handled
        }
        let next = min(max(at + delta, 0), order.count - 1)
        if next != at { actions.open(order[next]) }
        return .handled
    }

    // MARK: Меню

    @ViewBuilder
    private func menu(_ module: Module) -> some View {
        let zone = layout.zone(of: module)
        Button("Открыть") { actions.open(module) }
        if zone == .pinned {
            Button("Открепить") { send(module, .list) }
        } else {
            Button("Закрепить") { send(module, .pinned) }
                .disabled(!layout.canMove(module, to: .pinned))
        }
        if zone == .hidden {
            Button("Показать в списке") { send(module, .list) }
        } else {
            Button("Скрыть") { send(module, .hidden) }
        }
        Button("Как это работает") { actions.showInfo(module) }
        Divider()
        Button("Удалить модуль…", role: .destructive) { actions.remove(module) }
    }

    private func send(_ module: Module, _ zone: SidebarLayout.Zone) {
        withAnimation(SidebarMotion.spring) { _ = SidebarModel.shared.send(module, to: zone, open: openModule) }
    }

    // MARK: Жест

    private func gesture(_ module: Module) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("sb"))
            .onChanged { changed(module, $0) }
            .onEnded { _ in ended(module) })
    }

    private func changed(_ module: Module, _ value: DragGesture.Value) {
        if drag.module == nil {
            guard let zone = layout.zone(of: module), let frame = frame(of: module, zone: zone, counts: counts(layout)) else { return }
            grab = CGPoint(x: value.startLocation.x - frame.minX, y: value.startLocation.y - frame.minY)
            cancelled = false
            float.origin = frame.origin
            drag.kind = zone
            drag.module = module
            drag.target = SidebarLayout.Target(zone: zone, index: layout.items(zone).firstIndex(of: module) ?? 0)
            withAnimation(SidebarMotion.spring) { float.lifted = true }
            startSession()
        }
        guard drag.module == module, !cancelled else { return }
        lastPoint = value.location
        follow(value.location)
    }

    /// Поднятая копия за курсором (без анимации), цель по точке (с пружиной).
    private func follow(_ point: CGPoint) {
        guard let module = drag.module else { return }
        let new = target(for: point, module: module)
        let kind = new?.zone ?? drag.kind
        let kindChanged = kind != drag.kind && (kind == .pinned) != (drag.kind == .pinned)
        let pinnedCount = layout.preview(module, target: new)[.pinned]?.count ?? layout.pinned.count
        let size = floatSize(kind, pinnedCount: pinnedCount)
        let sameKind = (kind == .pinned) == (layout.zone(of: module) == .pinned)
        let origin = sameKind ? CGPoint(x: point.x - grab.x, y: point.y - grab.y)
                              : CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if new != drag.target || kindChanged {
            withAnimation(SidebarMotion.spring) {
                drag.target = new
                drag.kind = kind
                if kindChanged { float.origin = origin }
            }
        }
        if !kindChanged { float.origin = origin }
        scheduleExpand(for: new)
    }

    private func floatSize(_ zone: SidebarLayout.Zone, pinnedCount: Int) -> CGSize {
        SidebarMetrics.size(of: zone, pinnedCount: pinnedCount, width: width)
    }

    private func ended(_ module: Module) {
        guard drag.module == module else { return }
        stopSession()
        let target = cancelled ? nil : drag.target
        let counts = counts(layout, drag: drag.module.map { ($0, target) })
        let destination: CGPoint
        if let target, layout.canMove(module, to: target.zone),
           let frame = frame(ofSlot: target.index, zone: target.zone, counts: counts) {
            destination = frame.origin
        } else if let zone = layout.zone(of: module), let frame = frame(of: module, zone: zone, counts: self.counts(layout)) {
            destination = frame.origin
        } else {
            destination = float.origin
        }
        let reduce = SidebarMotion.reduced
        drag.target = target
        withAnimation(SidebarMotion.spring) {
            float.origin = destination
            float.lifted = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : 0.26)) { commit(module, target) }
    }

    /// Копия встала на место: меняем настоящие настройки и убираем копию без анимации (раскладка уже на месте).
    private func commit(_ module: Module, _ target: SidebarLayout.Target?) {
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) {
            if let target {
                var next = SidebarModel.shared.layout(open: openModule)
                if next.move(module, to: target.zone, at: target.index) { SidebarModel.shared.apply(next, moved: module) }
            }
            drag.module = nil
            drag.target = nil
        }
    }

    // MARK: Сессия перетаскивания (Esc, автопрокрутка)

    private func startSession() {
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53, drag.module != nil {
                    cancelled = true
                    withAnimation(SidebarMotion.spring) { drag.target = nil }
                    return nil
                }
                return event
            }
        }
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { autoScroll() }
        }
    }

    private func stopSession() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
        expandWork?.cancel()
        expandWork = nil
    }

    private func finishSession() {
        stopSession()
        if drag.module != nil { drag.module = nil; drag.target = nil }
    }

    private func autoScroll() {
        guard drag.module != nil, !cancelled, let scroll = geo.scroll else { return }
        let view = geo.viewport
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

    /// Наведение на свёрнутые «Скрытые» раскрывает их.
    private func scheduleExpand(for target: SidebarLayout.Target?) {
        guard target?.zone == .hidden, !expanded else {
            expandWork?.cancel()
            expandWork = nil
            return
        }
        guard expandWork == nil else { return }
        let work = DispatchWorkItem { withAnimation(SidebarMotion.spring) { expanded = true }; expandWork = nil }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: Места

    struct Counts {
        var pinned: Int
        var list: Int
        var hidden: Int
    }

    /// Сколько мест в каждой зоне сейчас, с пустотой на месте взятого и на месте вставки.
    private func counts(_ layout: SidebarLayout, drag pair: (Module, SidebarLayout.Target?)? = nil) -> Counts {
        let pair = pair ?? drag.module.map { ($0, drag.target) }
        guard let (module, target) = pair else {
            return Counts(pinned: layout.pinned.count, list: layout.list.count, hidden: layout.hidden.count)
        }
        let preview = layout.preview(module, target: target)
        return Counts(pinned: preview[.pinned]?.count ?? 0, list: preview[.list]?.count ?? 0, hidden: preview[.hidden]?.count ?? 0)
    }

    private func listOrigin() -> CGPoint {
        CGPoint(x: 10, y: geo.viewport.minY - geo.scrollY + listTop)
    }

    private func hiddenRowsOrigin(_ counts: Counts) -> CGPoint {
        let top = listTop + SidebarMetrics.listHeight(count: counts.list) + SidebarMetrics.sectionGap
        return CGPoint(x: 10, y: geo.viewport.minY - geo.scrollY + top + SidebarMetrics.headerHeight + SidebarMetrics.rowGap)
    }

    /// Место с номером `index` в зоне, в координатах панели.
    private func frame(ofSlot index: Int, zone: SidebarLayout.Zone, counts: Counts) -> CGRect? {
        switch zone {
        case .pinned:
            let frames = SidebarMetrics.pinnedFrames(count: counts.pinned, width: width)
            guard frames.indices.contains(index) else { return nil }
            return frames[index].offsetBy(dx: geo.pinnedOrigin.x, dy: geo.pinnedOrigin.y)
        case .list:
            return SidebarMetrics.listFrame(index: index, width: width).offsetBy(dx: listOrigin().x, dy: listOrigin().y)
        case .hidden:
            let origin = hiddenRowsOrigin(counts)
            return SidebarMetrics.hiddenFrame(index: index, width: width).offsetBy(dx: origin.x, dy: origin.y)
        }
    }

    private func frame(of module: Module, zone: SidebarLayout.Zone, counts: Counts) -> CGRect? {
        guard let index = layout.items(zone).firstIndex(of: module) else { return nil }
        return frame(ofSlot: index, zone: zone, counts: counts)
    }

    /// Куда целится точка. nil — вне панели, над подвалом или десятая плитка: вернуть на место.
    private func target(for point: CGPoint, module: Module) -> SidebarLayout.Target? {
        guard point.x > -14, point.x < DS.sidebarWidth + 14 else { return nil }
        let current = counts(layout)
        let view = geo.viewport
        let others = layout.preview(module, target: nil).mapValues { $0.compactMap { $0 }.count }
        if point.y < view.minY - 2 {
            guard layout.canMove(module, to: .pinned) else { return nil }
            let local = CGPoint(x: point.x - geo.pinnedOrigin.x, y: point.y - geo.pinnedOrigin.y)
            return .init(zone: .pinned, index: SidebarMetrics.pinnedInsertion(point: local, others: others[.pinned] ?? 0, width: width))
        }
        guard point.y <= view.maxY else { return nil }
        let content = point.y - view.minY + geo.scrollY
        let hiddenTop = listTop + SidebarMetrics.listHeight(count: current.list) + SidebarMetrics.sectionGap
        if content >= hiddenTop - SidebarMetrics.sectionGap / 2 {
            let rows = others[.hidden] ?? 0
            guard expanded else { return .init(zone: .hidden, index: rows) }
            let y = content - (hiddenTop + SidebarMetrics.headerHeight + SidebarMetrics.rowGap)
            return .init(zone: .hidden, index: SidebarMetrics.columnInsertion(y: y, others: rows, rowHeight: SidebarMetrics.hiddenRowHeight))
        }
        return .init(zone: .list, index: SidebarMetrics.columnInsertion(y: content - listTop, others: others[.list] ?? 0,
                                                                         rowHeight: SidebarMetrics.rowHeight))
    }
}

// MARK: - Зоны

/// Закреплённые плитки. Без рамки: плитки лежат прямо на панели, пустая зона — пунктирная подсказка.
private struct PinnedZone<Menu: View>: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    @ObservedObject var drag: SidebarDrag
    let width: CGFloat
    let gesture: (Module) -> AnyGesture<DragGesture.Value>
    let menu: (Module) -> Menu

    var body: some View {
        let slots = slots()
        let original = SidebarMetrics.pinnedFrames(count: layout.pinned.count, width: width)
        let frames = SidebarMetrics.pinnedFrames(count: slots.count, width: width)
        let height = SidebarMetrics.pinnedHeight(count: slots.count)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if slots.isEmpty { emptyHint }
                if let gap = slots.firstIndex(where: { $0 == nil }), frames.indices.contains(gap) {
                    RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: frames[gap].width, height: frames[gap].height)
                        .offset(x: frames[gap].minX, y: frames[gap].minY)
                }
                ForEach(layout.pinned) { module in
                    let dragged = drag.module == module
                    let index = layout.pinned.firstIndex(of: module) ?? 0
                    let frame = dragged ? (original.indices.contains(index) ? original[index] : .zero)
                                        : (slots.firstIndex(of: module).flatMap { frames.indices.contains($0) ? frames[$0] : nil } ?? .zero)
                    PinnedTile(module: module, actions: actions)
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .onTapGesture { actions.open(module) }
                        .highPriorityGesture(gesture(module))
                        .contextMenu { menu(module) }
                        .opacity(dragged ? 0 : 1)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            if layout.showsNotchHint {
                Text("Значков много: рядом с вырезом MacBook не все поместятся")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func slots() -> [Module?] {
        if let module = drag.module { return layout.preview(module, target: drag.target)[.pinned] ?? [] }
        return layout.pinned
    }

    private var emptyHint: some View {
        Text("Перетащи сюда — значок появится в строке меню")
            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42))
            .multilineTextAlignment(.center).lineLimit(2)
            .padding(.horizontal, 12)
            .frame(width: width, height: SidebarMetrics.emptyHintHeight)
            .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct ListZone<Menu: View>: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    @ObservedObject var drag: SidebarDrag
    let width: CGFloat
    let gesture: (Module) -> AnyGesture<DragGesture.Value>
    let menu: (Module) -> Menu

    var body: some View {
        let slots = drag.module.map { layout.preview($0, target: drag.target)[.list] ?? [] } ?? layout.list
        ZStack(alignment: .topLeading) {
            ForEach(layout.list) { module in
                let dragged = drag.module == module
                let index = dragged ? (layout.list.firstIndex(of: module) ?? 0) : (slots.firstIndex(of: module) ?? 0)
                let frame = SidebarMetrics.listFrame(index: index, width: width)
                SidebarRow(module: module, actions: actions)
                    .frame(width: frame.width, height: frame.height)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.open(module) }
                    .highPriorityGesture(gesture(module))
                    .contextMenu { menu(module) }
                    .opacity(dragged ? 0 : 1)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: width, height: SidebarMetrics.listHeight(count: slots.count), alignment: .topLeading)
    }
}

private struct HiddenSection<Menu: View>: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    @ObservedObject var drag: SidebarDrag
    let width: CGFloat
    @Binding var expanded: Bool
    let gesture: (Module) -> AnyGesture<DragGesture.Value>
    let menu: (Module) -> Menu
    @Environment(\.dsTint) private var tint

    var body: some View {
        let slots = drag.module.map { layout.preview($0, target: drag.target)[.hidden] ?? [] } ?? layout.hidden
        VStack(alignment: .leading, spacing: SidebarMetrics.rowGap) {
            header
            if expanded {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.hidden) { module in
                        let dragged = drag.module == module
                        let index = dragged ? (layout.hidden.firstIndex(of: module) ?? 0) : (slots.firstIndex(of: module) ?? 0)
                        let frame = SidebarMetrics.hiddenFrame(index: index, width: width)
                        HiddenRowView(module: module, selected: actions.selected == module)
                            .frame(width: frame.width, height: frame.height)
                            .contentShape(Rectangle())
                            .onTapGesture { actions.open(module) }
                            .highPriorityGesture(gesture(module))
                            .contextMenu { menu(module) }
                            .opacity(dragged ? 0 : 1)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: width, height: hiddenHeight(slots.count), alignment: .topLeading)
            }
        }
    }

    private func hiddenHeight(_ count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * (SidebarMetrics.hiddenRowHeight + SidebarMetrics.rowGap) - SidebarMetrics.rowGap
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash").font(.system(size: 12.5)).frame(width: 24)
            Text("Скрытые (\(layout.hidden.count))").font(.system(size: 13))
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 10)
        .frame(width: width, height: SidebarMetrics.headerHeight)
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous), normal: .clear, hovered: .white.opacity(0.06))
        .onTapGesture { withAnimation(SidebarMotion.spring) { expanded.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Скрытые, \(layout.hidden.count)")
        .accessibilityValue(expanded ? "развёрнуто" : "свёрнуто")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Строки и плитки

/// Статус модуля, пока вид на экране: подписка живёт, пока окно видно (`DashSlot`), поэтому в покое ничего не считается.
private struct SlotBound<Content: View>: View {
    @ObservedObject private var slot: DashSlot
    let content: (DashState) -> Content

    init(_ module: Module, @ViewBuilder content: @escaping (DashState) -> Content) {
        slot = DashboardLive.slot(module)
        self.content = content
    }

    var body: some View {
        content(slot.state)
            .onAppear { slot.attach() }
            .onDisappear { slot.detach() }
    }
}

private struct PinnedTile: View {
    let module: Module
    let actions: SidebarActions

    var body: some View {
        SlotBound(module) { state in
            TileFace(module: module, on: actions.isOn(module), selected: actions.selected == module, attention: state.attention)
                .help(state.text.isEmpty ? module.title : "\(module.title) — \(state.text)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(module.title)
                .accessibilityValue(state.text)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Открепить") { unpin() }
                .accessibilityAction(named: "Скрыть") { SidebarModel.shared.send(module, to: .hidden) }
        }
    }

    private func unpin() { SidebarModel.shared.send(module, to: .list) }
}

struct TileFace: View {
    let module: Module
    let on: Bool
    let selected: Bool
    let attention: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ModuleIconBadge(module: module, size: 24).opacity(on ? 1 : 0.45)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if attention {
                Circle().fill(Color.orange).frame(width: 7, height: 7).padding(5)
            }
        }
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                   normal: .white.opacity(selected ? 0.22 : 0.08), hovered: .white.opacity(selected ? 0.22 : 0.13))
        .overlay(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
            .strokeBorder(.white.opacity(selected ? 0.5 : 0), lineWidth: 1))
    }
}

private struct SidebarRow: View {
    let module: Module
    let actions: SidebarActions

    var body: some View {
        SlotBound(module) { state in
            RowFace(module: module, on: actions.isOn(module), selected: actions.selected == module, status: state)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(module.title)
                .accessibilityValue(state.text)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Закрепить") { SidebarModel.shared.send(module, to: .pinned) }
                .accessibilityAction(named: "Скрыть") { SidebarModel.shared.send(module, to: .hidden) }
        }
    }
}

/// Строка списка: значок, название, под ним живая строка («59° · По датчику · 3101 об/мин»). Выбранная залита оттенком темы.
struct RowFace: View {
    let module: Module
    let on: Bool
    let selected: Bool
    let status: DashState
    @Environment(\.dsTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 24).opacity(on ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(on ? (selected ? 1 : 0.85) : 0.5))
                    .lineLimit(1).truncationMode(.tail)
                Text(status.text.isEmpty ? " " : status.text).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(status.attention ? AnyShapeStyle(Color.orange)
                                                      : AnyShapeStyle(.white.opacity(on ? (selected ? 0.6 : 0.42) : 0.3)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                   normal: selected ? theme.selection(module) : .clear,
                   hovered: selected ? theme.selection(module) : .white.opacity(0.06))
    }
}

private struct HiddenRowView: View {
    let module: Module
    let selected: Bool
    @Environment(\.dsTint) private var tint

    var body: some View {
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 18).opacity(0.6).frame(width: 24)
            Text(module.title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                   normal: selected ? tint.opacity(0.26) : .clear,
                   hovered: selected ? tint.opacity(0.26) : .white.opacity(0.06))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Показать в списке") { SidebarModel.shared.send(module, to: .list) }
    }
}

// MARK: - Поднятая копия

private struct FloatingCopy: View {
    let layout: SidebarLayout
    @ObservedObject var drag: SidebarDrag
    @ObservedObject var float: SidebarFloat
    let actions: SidebarActions
    let width: CGFloat

    var body: some View {
        if let module = drag.module {
            let size = size()
            Group {
                switch drag.kind {
                case .pinned:
                    TileFace(module: module, on: actions.isOn(module), selected: true, attention: false)
                case .list:
                    RowFace(module: module, on: actions.isOn(module), selected: actions.selected == module,
                            status: DashboardLive.snapshot(module))
                        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous).fill(.black.opacity(0.35)))
                case .hidden:
                    HiddenRowView(module: module, selected: false)
                        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous).fill(.black.opacity(0.35)))
                }
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(float.lifted && !SidebarMotion.reduced ? 1.04 : 1)
            .shadow(color: .black.opacity(float.lifted ? 0.45 : 0), radius: float.lifted ? 10 : 0, y: float.lifted ? 4 : 0)
            .offset(x: float.origin.x, y: float.origin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func size() -> CGSize {
        let count = drag.module.flatMap { layout.preview($0, target: drag.target)[.pinned]?.count } ?? layout.pinned.count
        return SidebarMetrics.size(of: drag.kind, pinnedCount: count, width: width)
    }
}

// MARK: - Прокрутка

/// Находит `NSScrollView`, в котором лежит: нужен смещению и автопрокрутке. Своих подписок нет.
private struct ScrollProbe: NSViewRepresentable {
    let found: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.found = found
        return view
    }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.found = found }

    final class Probe: NSView {
        var found: ((NSScrollView?) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.found?(self?.enclosingScrollView) }
        }
    }
}
