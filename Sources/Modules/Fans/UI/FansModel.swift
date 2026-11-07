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
}

extension FansModel {
    var cpuMax: Double? { cpuSensors.map(\.value).max() }
    var gpuMax: Double? { gpuSensors.map(\.value).max() }
    func isLauncherGame(_ key: String) -> Bool { gameLaunchers.contains(key) }
}
