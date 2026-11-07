import AppKit

/// Модель вкладки «Вентиляторы», когда модуль ведёт утилита. SMC и службы у центра нет: всё через связь.
/// Ползунки шлют настройки целиком и склеиваются до последнего значения.
@MainActor
final class RemoteFansModel: RemoteModuleModel<FansState, FansAction>, FansModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        super.init(id: id,
                   initial: FansState(fans: [], configs: [], cpuSensors: [], gpuSensors: [], fullPower: false, safetyTripped: false,
                                      conflict: nil, lastError: nil, helperStatus: .notInstalled, helperError: nil,
                                      gameModeEnabled: false, myGames: [], gameLaunchers: [], addable: [],
                                      gameName: nil, gameLeavingUntil: nil),
                   baseWatch: .none, dashboardWatch: .screen, link: link, canRead: canRead,
                   optimistic: { state, action in
                       switch action {
                       case .setFullPower(let on): state.fullPower = on
                       case .setConfigs(let new): state.configs = new
                       case .setGameModeEnabled(let on): state.gameModeEnabled = on
                       default: break
                       }
                   },
                   coalesceKey: { action in
                       if case .setConfigs = action { return "configs" }
                       return nil
                   })
    }

    var fans: [FanReading] { state.fans }
    var configs: [FanConfig] {
        get { state.configs }
        set { send(.setConfigs(newValue)) }
    }
    var cpuSensors: [SensorReading] { state.cpuSensors }
    var gpuSensors: [SensorReading] { state.gpuSensors }
    var fullPower: Bool {
        get { state.fullPower }
        set { send(.setFullPower(newValue)) }
    }
    var safetyTripped: Bool { state.safetyTripped }
    var conflict: FansConflict? { state.conflict }
    var lastError: String? { state.lastError }
    var helperStatus: FansHelperStatus { state.helperStatus }
    var helperError: String? { state.helperError }
    var gameModeEnabled: Bool {
        get { state.gameModeEnabled }
        set { send(.setGameModeEnabled(newValue)) }
    }
    var myGames: [GameEntry] { state.myGames }
    var gameLaunchers: Set<String> { Set(state.gameLaunchers) }
    /// Иконки по связи не идут: центр берёт их у системы по ключу, как встроенный модуль для сохранённых игр.
    var addable: [RunningCandidate] { state.addable.map { RunningCandidate(key: $0.key, name: $0.name, icon: Self.icon(forKey: $0.key)) } }
    var gameName: String? { state.gameName }
    var gameLeavingUntil: Date? { state.gameLeavingUntil }

    func icon(for entry: GameEntry) -> NSImage? { Self.icon(forKey: entry.key) }
    func addGame(_ candidate: RunningCandidate) { send(.addGame(key: candidate.key)) }
    func removeGame(_ entry: GameEntry) { send(.removeGame(key: entry.key)) }
    func setLauncherGame(_ key: String, _ isGame: Bool) { send(.setLauncherGame(key: key, isGame: isGame)) }
    func refreshRunning() { send(.refreshRunning) }

    func setAllAuto() { send(.setAllAuto) }
    func closeConflictingApp(id: String) { send(.closeConflictingApp(id: id)) }
    func installHelper() { send(.installHelper) }
    func uninstallHelper() { send(.uninstallHelper) }

    private static func icon(forKey key: String) -> NSImage? {
        guard !key.hasPrefix("exe:"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else { return nil }
        return FansText.smallIcon(NSWorkspace.shared.icon(forFile: url.path))
    }

    // MARK: Дашборд

    // Карточка и меню те же, что у встроенного: градусы, обороты и режим не помещаются в строку статуса.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        if safetyTripped { return DashState(text: "перегрев · вентиляторами управляет система", attention: true) }
        var parts: [String] = []
        if let t = cpuMax { parts.append("\(Int(t.rounded()))°") }
        if fullPower {
            parts.append("Макс")
        } else {
            let modes = Set(configs.map(\.mode))
            parts.append(modes.count > 1 ? "Разные режимы" : (modes.first ?? .auto).title)
        }
        if let rpm = fans.map(\.actual).max() { parts.append("\(Int(rpm.rounded())) об/мин") }
        var state = DashState(text: parts.joined(separator: " · "))
        // Без доступа помощника кнопка ничего бы не сделала.
        if helperStatus == .ready && conflict == nil {
            state.actionTitle = fullPower ? "Авто" : "Максимум"
            state.actionIcon = fullPower ? "arrow.uturn.backward" : "wind"
        }
        return state
    }

    override func performDashboardAction() -> Bool {
        if helperStatus == .ready && conflict == nil { fullPower.toggle() }
        return true
    }

    override var menuUsesQuickActions: Bool { false }
}
