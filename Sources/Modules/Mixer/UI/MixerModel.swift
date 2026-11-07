import Foundation

/// Всё, что экран «Микшер» берёт у своей модели. Кто за ней стоит, контроллер в утилите
/// или `RemoteMixerModel` в центре, экран не знает.
@MainActor
protocol MixerModel: ObservableObject {
    var apps: [MixerApp] { get }
    var idleApps: [MixerApp] { get }
    var presetApps: [MixerApp] { get }
    var otherApps: [MixerApp] { get }
    var permissionProblem: Bool { get }
    var lastError: String? { get }
    /// Модуль работает в отдельной утилите: от этого зависят два текста экрана, про разрешение и про выход.
    var runsInUtility: Bool { get }
    func isMuted(_ id: String) -> Bool
    func setVolume(_ value: Double, for id: String)
    func setMuted(_ value: Bool, for id: String)
    func setEqualizer(_ setting: MixerEqSetting, for id: String)
    func reset(_ id: String)
    func commitVolumes()
    func setScreenVisible(_ value: Bool)
}
