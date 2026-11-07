import Foundation

/// Всё, что экран «Не спать» берёт у своей модели. Работает ли модуль здесь же (`AwakeController`)
/// или в утилите (`RemoteAwakeModel`), экран не знает.
@MainActor
protocol AwakeModel: ObservableObject {
    var isActive: Bool { get }
    /// Когда блокировка снимется сама; nil — «пока не выключу».
    var endDate: Date? { get }
    var keepDisplay: Bool { get set }
    var duration: AwakeDuration { get set }
    var canStart: Bool { get }
    func toggle()
}
