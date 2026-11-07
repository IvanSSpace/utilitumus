import Foundation

/// Модель вкладки «Микшер», когда модуль ведёт утилита. Тапы и опрос HAL у неё, у центра только списки из состояния.
/// Ползунок: значение видно сразу (`optimistic`), по связи уходит последнее (`coalesceKey`), а не каждый шаг.
/// Открыт ли экран, утилита знает по аренде экрана, поэтому `setScreenVisible` ничего не шлёт.
@MainActor
final class RemoteMixerModel: RemoteModuleModel<MixerState, MixerAction>, MixerModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        super.init(id: id,
                   initial: MixerState(apps: [], idleApps: [], presetApps: [], otherApps: [], permissionProblem: false, lastError: nil),
                   dashboardWatch: .changes, link: link, canRead: canRead,
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
                       case .reset(let id): edit(id) { $0.volume = 1; $0.muted = false; if $0.eq != nil { $0.eq = .off } }
                       case .commitVolumes: break
                       // Строка без `eq` — старый Микшер: показывать там нечего.
                       case .setEqualizer(let id, let enabled, let preset, let bands):
                           let setting = MixerEqSetting(enabled: enabled, preset: preset, bands: bands)
                           if setting.isValid { edit(id) { if $0.eq != nil { $0.eq = setting } } }
                       }
                   },
                   coalesceKey: { action in
                       switch action {
                       case .setVolume(let id, _): return "volume:" + id
                       case .setEqualizer(let id, _, _, _): return "equalizer:" + id
                       default: return nil
                       }
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
    func setEqualizer(_ setting: MixerEqSetting, for id: String) {
        send(.setEqualizer(id: id, enabled: setting.enabled, preset: setting.preset, bands: setting.bands))
    }
    func reset(_ id: String) { send(.reset(id: id)) }
    func commitVolumes() { send(.commitVolumes) }
    func setScreenVisible(_ value: Bool) {}

    // Карточка та же, что у встроенного: играющие программы и громкость не помещаются в строку статуса.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        let apps = state.apps
        guard let first = apps.first else { return DashState(text: "сейчас ничего не играет") }
        let volume = first.volume < 0.995 ? " · \(Int((first.volume * 100).rounded())) %" : ""
        if apps.count == 1 { return DashState(text: "играет \(first.name)\(volume)") }
        return DashState(text: "играют \(first.name) и ещё \(apps.count - 1)")
    }
}
