import AppKit
import Combine

/// Встроенный модуль: три контроллера одной моделью. Экран перерисовывается от любого из них, как раньше.
@MainActor
final class BuiltInFansModel: FansModel {
    static let shared = BuiltInFansModel()

    private let controller = FanController.shared
    private let installer = FanHelperInstaller.shared
    private let game = GameModeController.shared
    private var forwarding: Set<AnyCancellable> = []
    let objectWillChange = ObservableObjectPublisher()

    private init() {
        for source in [controller.objectWillChange, installer.objectWillChange, game.objectWillChange] {
            source.sink { [objectWillChange] in objectWillChange.send() }.store(in: &forwarding)
        }
    }

    var fans: [FanReading] { controller.fans }
    var configs: [FanConfig] {
        get { controller.configs }
        set { controller.configs = newValue }
    }
    var cpuSensors: [SensorReading] { controller.cpuSensors }
    var gpuSensors: [SensorReading] { controller.gpuSensors }
    var fullPower: Bool {
        get { controller.fullPower }
        set { controller.fullPower = newValue }
    }
    var safetyTripped: Bool { controller.safetyTripped }
    var conflict: FansConflict? {
        controller.conflictingApp.map { FansConflict(id: controller.conflictID, name: $0.localizedName) }
    }
    var lastError: String? { controller.lastError }

    var helperStatus: FansHelperStatus { FansHelperStatus(installer.status) }
    var helperError: String? { installer.lastError }

    var gameModeEnabled: Bool {
        get { game.isEnabled }
        set { game.isEnabled = newValue }
    }
    var myGames: [GameEntry] { game.myGames }
    var gameLaunchers: Set<String> { game.gameLaunchers }
    var addable: [RunningCandidate] { game.addable }
    var gameName: String? { game.phase.gameName }
    var gameLeavingUntil: Date? {
        if case .leaving(_, let until) = game.phase { return until }
        return nil
    }

    func icon(for entry: GameEntry) -> NSImage? { game.icon(for: entry) }
    func addGame(_ candidate: RunningCandidate) { game.addGame(candidate) }
    func removeGame(_ entry: GameEntry) { game.removeGame(entry) }
    func setLauncherGame(_ key: String, _ isGame: Bool) { game.setLauncherGame(key, isGame) }
    func refreshRunning() { game.refreshRunning() }

    func setAllAuto() { controller.setAllAuto() }
    func closeConflictingApp(id: String) { _ = controller.closeConflictingApp(id: id) }
    func installHelper() { installer.install() }
    func uninstallHelper() {
        controller.restoreAutoBlocking()
        installer.uninstall()
    }
    func setScreenOpen(_ open: Bool) {
        installer.screenOpen = open
        if open { installer.refresh() }
    }
}
