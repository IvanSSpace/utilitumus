import SwiftUI

private struct ModuleControlsKey: EnvironmentKey {
    static let defaultValue: (Module) -> AnyView = { _ in AnyView(EmptyView()) }
}

extension EnvironmentValues {
    /// Что рисует шапка страницы модуля над главной кнопкой. Решает приложение: Kit не знает, чем управляется модуль.
    /// Значение ставят на корень окна и на корень каждой страницы, которая живёт в своём NSHostingView.
    var moduleControls: (Module) -> AnyView {
        get { self[ModuleControlsKey.self] }
        set { self[ModuleControlsKey.self] = newValue }
    }
}
