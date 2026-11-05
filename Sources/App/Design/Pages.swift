import SwiftUI

// Живой кэш страниц окна: каждая открытая страница живёт в своём NSHostingView. Видимая вставлена в
// контейнер, скрытые сняты с иерархии: они не участвуют в layout и не задают размер окна (в первой версии
// их держал общий ZStack, и окно росло по самой высокой скрытой странице). Возврат на страницу — вставка
// готового вида плюс короткая анимация слоя, без построения.
// Скрытая страница не должна работать вхолостую: таймеры, опросы и подписки экрана привязаны к
// `\.pageActive` через `onPageActive` (а не к onAppear/onDisappear).

// MARK: - Режим страниц

/// «Быстрый» держит открытые страницы в кэше и анимирует смену, «Экономный» создаёт страницу при открытии.
enum PageMode: String, CaseIterable, Identifiable {
    case fast, economy

    static let storageKey = "UI.PageMode"
    var id: String { rawValue }
    var title: String { self == .fast ? "Быстрый" : "Экономный" }
}

// MARK: - Ключ страницы

enum PageKey: Hashable {
    case dashboard
    case module(Module)
    /// В панели нет модулей.
    case empty
    case about
    /// Стор: витрина модулей и наборов контента.
    case store

    /// Порядок как в боковой панели: дашборд, модули по категориям, «О проекте» внизу.
    var order: Int {
        switch self {
        case .dashboard, .empty: return 0
        case .store: return 1
        case .module(let m): return 2 + (Self.moduleOrder.firstIndex(of: m) ?? 0)
        case .about: return 1000
        }
    }

    private static let moduleOrder: [Module] = ModuleCategory.all.flatMap(\.modules)
        + Module.allCases.filter { m in !ModuleCategory.all.contains { $0.modules.contains(m) } }

    /// Все страницы в стабильном порядке — по нему идёт ForEach, чтобы слои не переставлялись.
    static let all: [PageKey] = [.dashboard, .empty, .store] + Module.allCases.map { .module($0) } + [.about]
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

/// Контейнер страниц. Видимая страница — единственный подвид; скрытые хранятся в словаре снятыми с окна.
final class PageContainer: NSView {
    private var hosts: [PageKey: NSHostingView<AnyView>] = [:]
    private var shown: PageKey?
    /// Последняя запрошенная страница: отложенные показы устаревших запросов отбрасываются.
    private var latest: PageKey?
    private var wrap: ((PageKey, Bool) -> AnyView)?

    /// Показать страницу; `make` собирает корень страницы с учётом её активности.
    func show(_ key: PageKey, animated: Bool, make: @escaping (PageKey, Bool) -> AnyView) {
        wrap = make
        latest = key
        if key == shown {
            hosts[key]?.rootView = make(key, true)
            return
        }
        if hosts[key] != nil {
            switchTo(key, animated: animated)
        } else {
            // Построение занимает 100–200 мс: даём боковой панели переключить выделение, потом строим.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.latest == key, self.hosts[key] == nil else { return }
                let host = NSHostingView(rootView: make(key, false))
                // Размер содержимого окну не сообщаем: страница занимает ровно то, что дал контейнер.
                host.sizingOptions = []
                if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
                host.autoresizingMask = [.width, .height]
                host.wantsLayer = true
                self.hosts[key] = host
                self.switchTo(key, animated: animated)
            }
        }
    }

    private func switchTo(_ key: PageKey, animated: Bool) {
        guard let new = hosts[key], let wrap else { return }
        let oldKey = shown
        let old = oldKey.flatMap { hosts[$0] }
        shown = key
        new.layer?.removeAllAnimations()
        new.layer?.opacity = 1
        new.frame = bounds
        new.rootView = wrap(key, true)
        addSubview(new)
        guard let oldKey, let old else { return }
        old.rootView = wrap(oldKey, false)
        guard animated, let layer = new.layer, let oldLayer = old.layer else {
            old.removeFromSuperview()
            return
        }
        // Куда сдвинуть: пункт ниже в панели — въезжает снизу (в слое AppKit ось y вверх), выше — сверху.
        let offset: CGFloat = key.order > oldKey.order ? -24 : 24
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = offset
        slide.toValue = 0
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fadeIn]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "pageIn")
        // Старая страница гаснет и после этого снимается: пока идёт анимация, она ещё в иерархии.
        addSubview(old, positioned: .below, relativeTo: new)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = 0.12
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak old] in
            guard let self, let old else { return }
            // Успели вернуться на эту страницу — не трогаем.
            if self.shown == oldKey { return }
            old.layer?.removeAllAnimations()
            old.removeFromSuperview()
        }
        oldLayer.add(fadeOut, forKey: "pageOut")
        CATransaction.commit()
    }
}

struct PageStack: NSViewRepresentable {
    let target: PageKey
    let animated: Bool
    let make: (PageKey, Bool) -> AnyView

    func makeNSView(context: Context) -> PageContainer { PageContainer() }

    func updateNSView(_ view: PageContainer, context: Context) {
        view.show(target, animated: animated, make: make)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}
