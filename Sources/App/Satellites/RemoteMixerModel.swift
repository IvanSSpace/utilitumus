import Foundation

/// Модель вкладки «Микшер», когда модуль ведёт утилита. Тапы и опрос HAL у неё, у центра только списки из состояния.
/// Ползунок: значение видно сразу (`optimistic`), по связи уходит последнее (`coalesceKey`), а не каждый шаг.
/// Открыт ли экран, утилита знает по аренде экрана, поэтому `setScreenVisible` ничего не шлёт.
@MainActor
final class RemoteMixerModel: RemoteModuleModel<MixerState, MixerAction>, MixerModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        super.init(id: id,
                   initial: MixerState(apps: [], idleApps: [], presetApps: [], otherApps: [], permissionProblem: false, lastError: nil),
                   link: link, canRead: canRead,
                   optimistic: { state, action in
                       func edit(_ id: String, _ change: (inout MixerAppState) -> Void) {
                           for list in [\MixerState.apps, \.idleApps, \.presetApps, \.otherApps] {
                               for i in state[keyPath: list].indices where state[keyPath: list][i].id == id {
                                   change(&state[keyPath: list][i])
                               }
                           }
                       }
                       switch action {
                       case .setVolume(let id, let value): if value.isFinite { edit(id) { $0.volume = min(max(value, 0), 1) } }
                       case .setMuted(let id, let on): edit(id) { $0.muted = on }
                       case .reset(let id): edit(id) { $0.volume = 1; $0.muted = false }
                       case .commitVolumes: break
                       }
                   },
                   coalesceKey: { action in
                       if case .setVolume(let id, _) = action { return "volume:" + id }
                       return nil
                   })
    }

    var apps: [MixerApp] { state.apps.map(MixerApp.init) }
    var idleApps: [MixerApp] { state.idleApps.map(MixerApp.init) }
    var presetApps: [MixerApp] { state.presetApps.map(MixerApp.init) }
    var otherApps: [MixerApp] { state.otherApps.map(MixerApp.init) }
    var permissionProblem: Bool { state.permissionProblem }
    var lastError: String? { state.lastError }
    var runsInUtility: Bool { true }

    func isMuted(_ id: String) -> Bool {
        (state.apps + state.idleApps + state.presetApps + state.otherApps).contains { $0.id == id && $0.muted }
    }
    func setVolume(_ value: Double, for id: String) { send(.setVolume(id: id, value: value)) }
    func setMuted(_ value: Bool, for id: String) { send(.setMuted(id: id, muted: value)) }
    func reset(_ id: String) { send(.reset(id: id)) }
    func commitVolumes() { send(.commitVolumes) }
    func setScreenVisible(_ value: Bool) {}
}
