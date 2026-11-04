import SwiftUI

// Живой кэш страниц окна: открытые страницы остаются в иерархии, неактивные прозрачны и не принимают
// ввод. Возврат на страницу — это смена opacity/offset готового слоя, без построения и без layout.
// Неактивная страница не должна работать вхолостую: таймеры, опросы и подписки экрана привязаны к
// `\.pageActive` через `onPageActive` (а не к onAppear/onDisappear, которые теперь срабатывают один раз).

// MARK: - Ключ страницы

enum PageKey: Hashable {
    case dashboard
    case module(Module)
    /// В панели нет модулей.
    case empty
    case about

    /// Порядок как в боковой панели: дашборд, модули по категориям, «О проекте» внизу.
    var order: Int {
        switch self {
        case .dashboard, .empty: return 0
        case .module(let m): return 1 + (Self.moduleOrder.firstIndex(of: m) ?? 0)
        case .about: return 1000
        }
    }

    private static let moduleOrder: [Module] = ModuleCategory.all.flatMap(\.modules)
        + Module.allCases.filter { m in !ModuleCategory.all.contains { $0.modules.contains(m) } }

    /// Все страницы в стабильном порядке — по нему идёт ForEach, чтобы слои не переставлялись.
    static let all: [PageKey] = [.dashboard, .empty] + Module.allCases.map { .module($0) } + [.about]
}

// MARK: - Активность страницы

private struct PageActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// Страница сейчас показана. Неактивная страница живёт в кэше: ничего не опрашивает и не слушает.
    /// Вне кэша (листы, превью) всегда `true`.
    var pageActive: Bool {
        get { self[PageActiveKey.self] }
        set { self[PageActiveKey.self] = newValue }
    }
}

private struct OnPageActive: ViewModifier {
    let perform: (Bool) -> Void
    @Environment(\.pageActive) private var active
    @State private var appeared = false
    @State private var running = false

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true; sync() }
            .onDisappear { appeared = false; sync() }
            .onChange(of: active) { sync() }
    }

    /// Работа идёт, пока экран в иерархии и страница активна. Вызывается строго на смену.
    private func sync() {
        let want = appeared && active
        guard want != running else { return }
        running = want
        perform(want)
    }
}

extension View {
    /// Аналог onAppear/onDisappear для экрана в кэше страниц: `true` — страницу открыли, `false` — ушли
    /// с неё (или экран убрали). Подписки, таймеры и опросы экрана заводят и гасят здесь.
    func onPageActive(_ perform: @escaping (Bool) -> Void) -> some View {
        modifier(OnPageActive(perform: perform))
    }
}

// MARK: - Стопка страниц

/// Запоминает размер слоя, пока тот активен: неактивной странице отдаётся он, и она не пересчитывает
/// layout при изменении размера окна (иначе живой ресайз платил бы за все открытые страницы).
private final class SizeBox { var size: CGSize = .zero }

private final class LatestBox { var key: PageKey? }

private struct PageLayer<Content: View>: View {
    let isActive: Bool
    /// Куда отъезжает неактивная страница: +24 — она ниже активной в панели (выезжает снизу), −24 — выше.
    let rest: CGFloat
    @ViewBuilder let content: Content
    @State private var box = SizeBox()

    var body: some View {
        let frozen: CGSize? = isActive || box.size == .zero ? nil : box.size
        content
            .environment(\.pageActive, isActive)
            .disabled(!isActive)
            // Анимации слоя не должны захватывать содержимое страницы.
            .animation(nil, value: isActive)
            .frame(width: frozen?.width, height: frozen?.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { geo in
                Color.clear.onChange(of: geo.size, initial: true) { _, size in
                    if isActive || box.size == .zero { box.size = size }
                }
            })
            // Новая страница въезжает за 0,22 с; старая гаснет за 0,12 с и только после этого уходит в сторону.
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: isActive ? 0.22 : 0.12), value: isActive)
            .offset(y: isActive ? 0 : rest)
            .animation(isActive ? .easeOut(duration: 0.22) : .linear(duration: 0.001).delay(0.12), value: isActive)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }
}

struct PageStack<Content: View>: View {
    let target: PageKey
    @ViewBuilder let content: (PageKey) -> Content
    /// Построенные страницы.
    @State private var opened: Set<PageKey>
    /// Страница, которая показана сейчас. Для ещё не построенной отстаёт от `target` на построение.
    @State private var shown: PageKey
    /// Последняя запрошенная страница: отложенные показы устаревших запросов отбрасываются.
    @State private var latest = LatestBox()

    init(target: PageKey, @ViewBuilder content: @escaping (PageKey) -> Content) {
        self.target = target
        self.content = content
        _opened = State(initialValue: [target])
        _shown = State(initialValue: target)
    }

    var body: some View {
        ZStack {
            ForEach(PageKey.all.filter(opened.contains), id: \.self) { key in
                PageLayer(isActive: key == shown, rest: key.order > shown.order ? 24 : -24) {
                    content(key)
                }
            }
        }
        .onChange(of: target) { _, new in
            latest.key = new
            if opened.contains(new) {
                shown = new
            } else {
                // Построение занимает 100–200 мс: даём боковой панели переключить выделение, затем строим
                // скрытый слой и только потом показываем, чтобы въезд шёл по готовой странице.
                DispatchQueue.main.async {
                    opened.insert(new)
                    DispatchQueue.main.async { if latest.key == new { shown = new } }
                }
            }
        }
    }
}
