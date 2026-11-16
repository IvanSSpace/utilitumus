import Foundation

/// Всё, что экран «Озвучка» берёт у своей модели. Кто за ней стоит, контроллер в утилите
/// или модель вкладки в центре, экран не знает.
@MainActor
protocol SpeakModel: ObservableObject, HotKeyTarget {
    var speed: Double { get }
    var pinnedVoices: [String: String] { get }
    var voices: [SpeakVoiceRow] { get }
    var phase: SpeakPhase { get }
    var message: String? { get }
    var hotKeyLabel: String { get }
    var hotKeyError: String? { get }
    var accessibilityTrusted: Bool { get }
    var canStart: Bool { get }

    func setSpeed(_ value: Double)
    /// +1 или −1.
    func stepSpeed(_ direction: Int)
    func setVoiceAuto()
    func pinVoice(language: String, id: String)
    func unpin(language: String)
    func pause()
    func resume()
    /// Оборвать чтение; модуль работает дальше.
    func stopSpeaking()
    func refreshPermissions()
    func requestAccessibility()
}
