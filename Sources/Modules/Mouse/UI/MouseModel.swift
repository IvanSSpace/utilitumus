import Foundation

/// Всё, что экран «Мышь» берёт у своей модели. Кто за ней стоит, контроллер в утилите
/// или `RemoteMouseModel` в центре, экран не знает.
@MainActor
protocol MouseModel: ObservableObject {
    var settings: MouseSettings { get set }
    var axTrusted: Bool { get }
    var tapActive: Bool { get }
    func refreshAccess()
}
