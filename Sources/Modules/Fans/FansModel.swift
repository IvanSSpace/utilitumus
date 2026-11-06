import AppKit
import Combine

/// Всё, что экран «Вентиляторы» берёт у своей модели. Работает ли модуль здесь же
/// (`BuiltInFansModel`) или в утилите, экран не знает.
@MainActor
protocol FansModel: ObservableObject {
    var fans: [FanReading] { get }
    var configs: [FanConfig] { get set }
    var cpuSensors: [SensorReading] { get }
    var gpuSensors: [SensorReading] { get }
    var fullPower: Bool { get set }
    var safetyTripped: Bool { get }
    var conflict: FansConflict? { get }
    var lastError: String? { get }

    var helperStatus: FansHelperStatus { get }
    var helperError: String? { get }

    var gameModeEnabled: Bool { get set }
    var myGames: [GameEntry] { get }
    var gameLaunchers: Set<String> { get }
    var addable: [RunningCandidate] { get }
    /// Во что играем; nil — режим сейчас не действует.
    var gameName: String? { get }
    /// Из игры ушли: когда вентиляторы вернутся к своим режимам.
    var gameLeavingUntil: Date? { get }

    func icon(for entry: GameEntry) -> NSImage?
    func addGame(_ candidate: RunningCandidate)
    func removeGame(_ entry: GameEntry)
    func setLauncherGame(_ key: String, _ isGame: Bool)
    func refreshRunning()

    func setAllAuto()
    func closeConflictingApp(id: String)
    func installHelper()
    func uninstallHelper()
    func setScreenOpen(_ open: Bool)
    /// Вентиляторами ведает отдельная утилита, а не центр: от этого зависят два текста экрана.
    var isExternal: Bool { get }
}

extension FansModel {
    var cpuMax: Double? { cpuSensors.map(\.value).max() }
    var gpuMax: Double? { gpuSensors.map(\.value).max() }
    func isLauncherGame(_ key: String) -> Bool { gameLaunchers.contains(key) }
}

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
    var isExternal: Bool { false }
    func setScreenOpen(_ open: Bool) {
        installer.screenOpen = open
        if open { installer.refresh() }
    }
}
