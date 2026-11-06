import SwiftUI
import AppKit
import Combine

// Содержимое боковой панели: закреплённые плитки сверху, список с живым статусом, свёртка «Скрытые».
// Перетаскивание, клик и меню ведёт один вид-ловец поверх панели (`SidebarDrag.swift`), здесь только отрисовка:
// поднятая копия едет за курсором, остальные расступаются пружиной, у «Скрытых» показывается линия вставки.

#if KIT_TEST_DEFAULTS
/// Для проверки: где поднятая копия на самом деле (рамка в координатах окна, как её отрисовал вид).
@MainActor enum SidebarProbe {
    static var copy: CGRect?
    static var frames: [Module: CGRect] = [:]
    static var grid: CGRect = .zero
    static var header: CGRect = .zero
    static var line: CGRect?
    static var menu: [String]?
    static var interceptsMenu = true
}
#endif

extension View {
    /// Только в проверке: пишет отрисованную рамку вида (в координатах окна, вместе со сдвигами выше по цепочке).
    @ViewBuilder func probe(_ store: @escaping @MainActor (CGRect) -> Void) -> some View {
        #if KIT_TEST_DEFAULTS
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in MainActor.assumeIsolated { store(rect) } }
        #else
        self
        #endif
    }
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

// MARK: - Содержимое

struct SidebarContent: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    /// Открытая страница, которую могли выключить на ней: строка остаётся до ухода.
    let openModule: Module?

    @StateObject private var session = SidebarSession()
    @AppStorage("HiddenModulesExpanded") private var expanded = false
    @Environment(\.dsTheme) private var theme
    @Environment(\.dsTint) private var tint

    #if KIT_TEST_DEFAULTS
    /// Проверка ставит панель в середину перетаскивания: кто, куда целится и где поднятая копия.
    @MainActor static var testDrag: (Module, SidebarLayout.Target, CGPoint)?
    #endif

    private let width = DS.sidebarWidth - 20

    var body: some View {
        // Список лежит во внутреннем виде, мышь ловит вид-ловец над ним (оба в `SidebarHost`), а копия рисуется здесь,
        // снаружи: она может выйти за край панели, пока кнопка зажата.
        SidebarHost(session: session, layout: layout, actions: actions, openModule: openModule, expanded: $expanded, theme: theme, tint: tint)
            .overlay(alignment: .topLeading) { FloatingCopy(layout: layout, drag: session.drag, float: session.float, actions: actions, width: width) }
            .onDisappear { session.finish() }
            #if KIT_TEST_DEFAULTS
            .onAppear {
                if let test = Self.testDrag {
                    session.drag.module = test.0
                    session.drag.target = test.1
                    session.drag.kind = test.1.zone
                    session.float.cursor = test.2
                    session.float.anchor = .zero
                    session.float.lifted = true
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
}

// MARK: - Внутренний вид

/// Закреплённые плитки и прокручиваемый список со «Скрытыми». Живёт в своём `NSHostingView` внутри `SidebarHost`:
/// наведение, подсказки и нажатия по заголовку «Скрытые» работают как у обычного SwiftUI, а вид-ловец лежит над ним.
struct SidebarList: View {
    let session: SidebarSession
    let layout: SidebarLayout
    let actions: SidebarActions
    @Binding var expanded: Bool

    private let width = DS.sidebarWidth - 20

    var body: some View {
        VStack(spacing: 0) {
            PinnedZone(layout: layout, actions: actions, drag: session.drag, width: width)
                .padding(.horizontal, 10).padding(.bottom, SidebarMetrics.pinnedBottomGap)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ListZone(layout: layout, actions: actions, drag: session.drag, width: width)
                    HiddenSection(layout: layout, actions: actions, drag: session.drag, width: width, expanded: $expanded)
                        .padding(.top, SidebarMetrics.sectionGap)
                }
                .padding(.horizontal, 10).padding(.top, SidebarMetrics.listTop).padding(.bottom, 6)
                .background(ScrollProbe { session.scroll = $0 })
            }
            .scrollIndicators(.never)
        }
        .focusEffectDisabled()
    }
}

// MARK: - Зоны

/// Вспышка на только что севшем модуле: тает сама, когда `landed` сбрасывают с анимацией.
private struct LandFlash: View {
    let module: Module
    @ObservedObject var drag: SidebarDrag

    var body: some View {
        RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
            .fill(.white.opacity(drag.landed == module ? 0.28 : 0))
            .allowsHitTesting(false)
    }
}

/// Закреплённые плитки. Без рамки: плитки лежат прямо на панели, пустая зона — пунктирная подсказка.
private struct PinnedZone: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    @ObservedObject var drag: SidebarDrag
    let width: CGFloat

    var body: some View {
        let slots = drag.module == nil ? layout.pinned.map { Optional($0) }
                                       : layout.slots(.pinned, dragging: drag.module, target: drag.target, settling: drag.settling)
        let original = SidebarMetrics.pinnedFrames(count: layout.pinned.count, width: width)
        let frames = SidebarMetrics.pinnedFrames(count: slots.count, width: width)
        let height = SidebarMetrics.pinnedHeight(count: slots.count)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if slots.isEmpty { emptyHint }
                if let gap = slots.firstIndex(where: { $0 == nil }), frames.indices.contains(gap) {
                    RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                        .fill(.white.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
                        .overlay(LandFlash(module: module, drag: drag))
                        .contentShape(Rectangle())
                        .opacity(dragged ? 0 : 1)
                        .probe { SidebarProbe.frames[module] = $0 }
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .probe { SidebarProbe.grid = $0 }
            if layout.showsNotchHint {
                Text("Значков много: рядом с вырезом MacBook не все поместятся")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

private struct ListZone: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    @ObservedObject var drag: SidebarDrag
    let width: CGFloat

    var body: some View {
        let slots = layout.slots(.list, dragging: drag.module, target: drag.target, settling: drag.settling)
        ZStack(alignment: .topLeading) {
            ForEach(layout.list) { module in
                let dragged = drag.module == module
                let index = dragged ? (layout.list.firstIndex(of: module) ?? 0) : (slots.firstIndex(of: module) ?? 0)
                let frame = SidebarMetrics.listFrame(index: index, width: width)
                SidebarRow(module: module, actions: actions)
                    .frame(width: frame.width, height: frame.height)
                    .overlay(LandFlash(module: module, drag: drag))
                    .contentShape(Rectangle())
                    .opacity(dragged ? 0 : 1)
                    .probe { SidebarProbe.frames[module] = $0 }
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: width, height: SidebarMetrics.listHeight(count: slots.count), alignment: .topLeading)
    }
}

private struct HiddenSection: View {
    let layout: SidebarLayout
    let actions: SidebarActions
    @ObservedObject var drag: SidebarDrag
    let width: CGFloat
    @Binding var expanded: Bool
    @Environment(\.dsTint) private var tint

    var body: some View {
        let slots = layout.slots(.hidden, dragging: drag.module, target: drag.target, settling: drag.settling)
        let aimed = drag.module != nil && !drag.settling && drag.target?.zone == .hidden
        VStack(alignment: .leading, spacing: SidebarMetrics.rowGap) {
            header
            if expanded {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.hidden) { module in
                        let dragged = drag.module == module
                        let index = dragged ? (layout.hidden.firstIndex(of: module) ?? 0) : (slots.firstIndex(of: module) ?? 0)
                        let frame = SidebarMetrics.hiddenFrame(index: index, width: width)
                        HiddenRowView(module: module, selected: actions.selected == module, open: { actions.open(module) })
                            .frame(width: frame.width, height: frame.height)
                            .overlay(LandFlash(module: module, drag: drag))
                            .contentShape(Rectangle())
                            .opacity(dragged ? 0 : 1)
                            .probe { SidebarProbe.frames[module] = $0 }
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: width, height: hiddenHeight(slots.count), alignment: .topLeading)
            }
        }
        .overlay(alignment: .topLeading) {
            if aimed, let index = drag.target?.index {
                InsertionLine(width: width)
                    .offset(y: lineY(index: expanded ? min(index, slots.count) : 0) - InsertionLine.height / 2)
            }
        }
    }

    /// Линия между строками `index - 1` и `index`; у свёрнутых — сразу под заголовком.
    private func lineY(index: Int) -> CGFloat {
        let rows = SidebarMetrics.headerHeight + SidebarMetrics.rowGap
        return rows + CGFloat(index) * (SidebarMetrics.hiddenRowHeight + SidebarMetrics.rowGap) - 1
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
        .probe { SidebarProbe.header = $0 }
        .onTapGesture { withAnimation(SidebarMotion.spring) { expanded.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Скрытые, \(layout.hidden.count)")
        .accessibilityValue(expanded ? "развёрнуто" : "свёрнуто")
        .accessibilityAddTraits(.isButton)
    }
}

/// Белая линия с кружком слева: куда сядет модуль в «Скрытых».
private struct InsertionLine: View {
    static let height: CGFloat = 8
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(.white, lineWidth: 2).frame(width: Self.height, height: Self.height)
            Capsule().fill(.white).frame(height: 2)
        }
        .frame(width: width, height: Self.height)
        .shadow(color: .black.opacity(0.4), radius: 2)
        .allowsHitTesting(false)
        .transition(.opacity)
        .probe { SidebarProbe.line = $0 }
        .onDisappear {
            #if KIT_TEST_DEFAULTS
            SidebarProbe.line = nil
            #endif
        }
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
                .accessibilityAction { actions.open(module) }
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
                .accessibilityAction { actions.open(module) }
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
    let open: () -> Void
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
        .accessibilityAction { open() }
        .accessibilityAction(named: "Показать в списке") { SidebarModel.shared.send(module, to: .list) }
    }
}

// MARK: - Поднятая копия

/// Копия за курсором. Положение — три смещения друг в друга, у каждого своя анимация: курсор никогда не анимируется
/// (1:1, без отставания даже в кадре, где пружиной двигаются остальные), опора (где в копии курсор) меняется пружиной,
/// когда копия из строки становится плиткой, посадка после отпускания идёт отдельно.
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
                    HiddenRowView(module: module, selected: false, open: {})
                        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous).fill(.black.opacity(0.35)))
                }
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(float.lifted && !SidebarMotion.reduced ? 1.04 : 1)
            .shadow(color: .black.opacity(float.lifted ? 0.45 : 0), radius: float.lifted ? 10 : 0, y: float.lifted ? 4 : 0)
            .opacity(float.fading ? 0 : 0.92)
            .animation(SidebarMotion.spring, value: float.lifted)
            .animation(SidebarMotion.spring, value: size)
            .animation(SidebarMotion.land, value: float.fading)
            .probe { SidebarProbe.copy = $0 }
            .offset(x: -float.anchor.x, y: -float.anchor.y)
            .animation(SidebarMotion.spring, value: float.anchor)
            .offset(x: float.landing.width, y: float.landing.height)
            .animation(SidebarMotion.land, value: float.landing)
            .offset(x: float.cursor.x, y: float.cursor.y)
            .animation(nil, value: float.cursor)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onDisappear {
                #if KIT_TEST_DEFAULTS
                SidebarProbe.copy = nil
                #endif
            }
        }
    }

    private func size() -> CGSize {
        let count = layout.slots(.pinned, dragging: drag.module, target: drag.target, settling: drag.settling).count
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
