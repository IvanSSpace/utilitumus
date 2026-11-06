import CoreGraphics
import Foundation

/// Модель вкладки «Клавиатура», когда модуль ведёт утилита. Tap, журнал и системные настройки у утилиты,
/// здесь только последнее известное состояние. Своего контроллера у центра при этом не запускается.
@MainActor
final class RemoteKeyboardModel: RemoteModuleModel<KeyboardState, KeyboardAction>, KeyboardModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        let defaults = Kit.defaults
        // До первого ответа — сохранённые настройки: домен настроек у центра и утилиты один.
        super.init(id: id,
                   initial: KeyboardState(
                       features: KeyboardFeature.enabled.map(\.rawValue),
                       trigger: FnTrigger(rawValue: defaults.string(forKey: "Keyboard.Trigger") ?? "") ?? .onRelease,
                       mode: LayoutMode(rawValue: defaults.string(forKey: "Keyboard.Mode") ?? "") ?? .lastTwo,
                       currentName: "—", tapActive: false, inputAccess: CGPreflightListenEventAccess(),
                       systemUsage: nil, secureInputApp: nil, logTail: [], logCount: 0, repairResult: nil, layouts: [],
                       newAppLayout: defaults.string(forKey: "Keyboard.AppLayout.NewStart"),
                       excludedApps: defaults.stringArray(forKey: "Keyboard.AppLayout.Excluded") ?? []),
                   dashboardWatch: .changes, link: link, canRead: canRead,
                   optimistic: { state, action in
                       switch action {
                       case .setFeature(let feature, let on):
                           var kept = Set(state.features)
                           if on { kept.insert(feature.rawValue) } else { kept.remove(feature.rawValue) }
                           state.features = KeyboardFeature.allCases.map(\.rawValue).filter(kept.contains)
                       case .setTrigger(let value): state.trigger = value
                       case .setMode(let value): state.mode = value
                       case .setNewAppLayout(let id): state.newAppLayout = id
                       case .addExcluded(let id):
                           if !state.excludedApps.contains(id) { state.excludedApps.append(id) }
                       case .removeExcluded(let id): state.excludedApps.removeAll { $0 == id }
                       // Итог этих действий знает только утилита: показывается её ответ.
                       default: break
                       }
                   })
    }

    var trigger: FnTrigger {
        get { state.trigger }
        set { send(.setTrigger(newValue)) }
    }
    var mode: LayoutMode {
        get { state.mode }
        set { send(.setMode(newValue)) }
    }
    var newAppLayout: String? {
        get { state.newAppLayout }
        set { send(.setNewAppLayout(newValue)) }
    }
    var currentName: String { state.currentName }
    var tapActive: Bool { state.tapActive }
    var inputAccess: Bool { state.inputAccess }
    var systemUsage: Int? { state.systemUsage }
    var secureInputApp: String? { state.secureInputApp }
    var logTail: [KeyboardLog.Entry] { state.logTail }
    var logCount: Int { state.logCount }
    var repairResult: String? { state.repairResult }
    var layouts: [KeyboardLayoutItem] { state.layouts }
    var excludedApps: [String] { state.excludedApps }

    func isOn(_ feature: KeyboardFeature) -> Bool { state.features.contains(feature.rawValue) }
    func setFeature(_ feature: KeyboardFeature, on: Bool) { send(.setFeature(feature: feature, on: on)) }
    func addExcluded(_ id: String) { send(.addExcluded(id)) }
    func removeExcluded(_ id: String) { send(.removeExcluded(id)) }
    func repair() { send(.repair) }
    func copyLog() { send(.copyLog) }
    func refreshAccess() { send(.refreshAccess) }
    func refreshSystem() { send(.refreshSystem) }

    // Карточка та же, что у встроенного: текущий язык и защищённый ввод не помещаются в строку статуса.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        let fn = isOn(.fnLanguage), perApp = isOn(.perAppLayout)
        guard fn || perApp else { return DashState(text: "нет включённых фишек", attention: true) }
        if fn {
            guard tapActive else { return DashState(text: "не слушаю клавиатуру", attention: true) }
            if let app = secureInputApp {
                return DashState(text: "Сейчас Fn не слышно: защищённый ввод в \(app)", attention: true)
            }
            if (systemUsage ?? 0) != 0 { return DashState(text: "системное действие 🌐 мешает", attention: true) }
        }
        if fn && perApp { return DashState(text: "\(KeyboardFeature.fnLanguage.shortName) · \(KeyboardFeature.perAppLayout.shortName)") }
        return DashState(text: fn ? currentName : "\(KeyboardFeature.perAppLayout.shortName) · \(currentName)")
    }
}
