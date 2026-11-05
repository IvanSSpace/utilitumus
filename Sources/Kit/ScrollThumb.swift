import SwiftUI

// Своя полоса прокрутки для страниц в карточке со скруглением. Системная прилипает
// к краю и режется скруглением. На macOS 14 (там нет onScrollGeometryChange) остаётся
// системная, но с отступами сверху и снизу.

/// Прокручиваемая область: серая полупрозрачная полоса (белая с прозрачностью, без оттенка страницы),
/// с отступом от края и не ближе `inset` к верху и низу — чтобы не попадать под скругление.
/// Системная полоса при этом скрыта полностью, чтобы две не накладывались.
struct DSScroll<Content: View>: View {
    var inset: CGFloat = DS.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 15, *) {
            DSThumbScroll(inset: inset) { content }
        } else {
            ScrollView { content }
                .contentMargins(.vertical, inset, for: .scrollIndicators)
        }
    }
}

/// Положение прокрутки. Живёт в отдельном объекте, а не в `@State` страницы:
/// перерисовывается только полоса, а не весь экран на каждый пиксель.
@available(macOS 15, *)
@MainActor
private final class ThumbModel: ObservableObject {
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0
    }
    @Published var metrics = Metrics()
    /// Только что крутили: полоса ярче.
    @Published var scrolling = false
    /// Полоса видна (крутили меньше 1,2 с назад).
    @Published var shown = false
    @Published var hovering = false
    @Published var dragging = false
    private var hideTask: Task<Void, Never>?

    func update(_ new: Metrics) {
        let moved = abs(new.offset - metrics.offset) >= 0.5
        if new != metrics { metrics = new }
        guard moved else { return }
        scrolling = true
        shown = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.scrolling = false
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.shown = false
        }
    }
}

@available(macOS 15, *)
private struct DSThumbScroll<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder var content: Content
    @State private var model = ThumbModel()
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView { content.background(SystemScrollerHider()) }
            // .never, а не .hidden: при «Показывать полосы: всегда» (мышь) .hidden оставляет системную
            // полосу, и она съедает ширину справа — контент сдвигался влево.
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ThumbModel.Metrics.self) { g in
                ThumbModel.Metrics(offset: g.contentOffset.y + g.contentInsets.top,
                                   content: g.contentSize.height,
                                   viewport: g.containerSize.height)
            } action: { _, new in
                model.update(new)
            }
            .overlay(alignment: .topTrailing) {
                DSThumb(model: model, inset: inset) { y in position.scrollTo(y: y) }
            }
    }
}

@available(macOS 15, *)
private struct DSThumb: View {
    @ObservedObject var model: ThumbModel
    let inset: CGFloat
    let scrollTo: (CGFloat) -> Void
    /// Смещение страницы в начале перетаскивания.
    @State private var dragStart: CGFloat?

    private let width: CGFloat = 8
    private let hoverWidth: CGFloat = 10
    private let edgeGap: CGFloat = 5
    private let minThumb: CGFloat = 28

    var body: some View {
        let m = model.metrics
        let scrollable = m.content - m.viewport
        let track = max(m.viewport - inset * 2, 0)
        if scrollable > 1, track > minThumb {
            let thumb = max(minThumb, track * m.viewport / m.content)
            let range = max(track - thumb, 1)
            let progress = min(max(m.offset / scrollable, 0), 1)
            let active = model.scrolling || model.hovering || model.dragging
            let visible = model.shown || model.hovering || model.dragging
            Capsule()
                .fill(.white.opacity(active ? 0.32 : 0.18))
                .frame(width: model.hovering || model.dragging ? hoverWidth : width, height: thumb)
                // Зона нажатия шире видимой полосы.
                .padding(.leading, 9)
                .padding(.trailing, edgeGap)
                .contentShape(Rectangle())
                .offset(y: inset + range * progress)
                .opacity(visible ? 1 : 0)
                // Скрытая полоса не перехватывает мышь у содержимого у края.
                .allowsHitTesting(visible)
                .animation(.easeOut(duration: 0.2), value: visible)
                .animation(.easeOut(duration: 0.15), value: active)
                .animation(.easeOut(duration: 0.12), value: model.hovering || model.dragging)
                .onHover { model.hovering = $0 }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = m.offset; model.dragging = true }
                        let y = (dragStart ?? 0) + value.translation.height * scrollable / range
                        scrollTo(min(max(y, 0), scrollable))
                    }
                    .onEnded { _ in dragStart = nil; model.dragging = false })
        }
    }
}

/// Страховка: если системная полоса всё же рисуется (режим «Показывать полосы прокрутки: всегда» при
/// подключённой мыши), выключает её у NSScrollView, внутри которого лежит этот вид.
@available(macOS 15, *)
private struct SystemScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HiderView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class HiderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                // Плавающий стиль: даже если полосу вернут, она не займёт место под контентом.
                scroll.scrollerStyle = .overlay
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
            }
        }
    }
}
