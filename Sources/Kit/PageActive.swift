import SwiftUI

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
