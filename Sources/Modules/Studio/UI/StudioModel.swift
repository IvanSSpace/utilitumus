import Combine
import Foundation

/// Всё, что экран «Студия» берёт у своей модели. Кто за ней стоит, контроллер в утилите или модель вкладки в центре,
/// экран не знает.
@MainActor
protocol StudioModel: ObservableObject {
    var state: StudioState { get }
    func setFolder(_ path: String)
    /// «Открыть в браузере»: утилита берёт свежий одноразовый код и сама открывает адрес. Экран кода не видит.
    func openInBrowser()
    /// Последний отказ действия (короткая строка): утилита не приняла или не выполнила его.
    var actionError: String? { get }
    /// Действие по утилите, выбор, подключение заново. Допустимые действия известны утилите, остальные она не примет.
    func send(_ action: StudioAction)
}
