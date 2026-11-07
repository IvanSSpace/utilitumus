import Foundation

/// Всё, что экран «Мышь» берёт у своей модели. Работает ли модуль здесь же (`MouseController`)
/// или в утилите, экран не знает.
@MainActor
protocol MouseModel: ObservableObject {
    var settings: MouseSettings { get set }
    var axTrusted: Bool { get }
    var tapActive: Bool { get }
    func refreshAccess()
}
