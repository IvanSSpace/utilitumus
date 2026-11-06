import AppKit
import SwiftUI

// Состояние, действия и экран «Вентиляторы». Запуск: Tests/run-fans-wire-check.sh
// Настоящие FanController, GameModeController и экран; SMC, служба и установщик подделаны: настоящих в сборке нет,
// поэтому окна пароля, AppleScript, XPC и записи в SMC здесь быть не может (скрипт проверяет ещё и по nm).
//
// `pixels <папка>` снимает встроенный экран; эта же часть собирается и со старым FansView (FANS_BASELINE).
// `check <папка базы> <своя папка> <домашняя папка>` делает всё остальное и сравнивает снимки с базой.

// MARK: - Подделки

/// Два вентилятора и служба: команды меняют состояние так же, как настоящая служба меняла бы SMC.
final class Bench: @unchecked Sendable {
    static let shared = Bench()
    private let lock = NSLock()
    private var manualNow: Set<Int> = []
    private var targets: [Int: Float] = [:]
    private var commands: [String] = []

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func isManual(_ fan: Int) -> Bool { locked { manualNow.contains(fan) } }
    func target(_ fan: Int) -> Float { locked { targets[fan] ?? 0 } }
    var log: [String] { locked { commands } }
    func clearLog() { locked { commands = [] } }
    func setManual(_ fan: Int) { locked { _ = manualNow.insert(fan) } }

    func deliver(_ command: FanHelperClient.Command) {
        locked {
            commands.append(command.description)
            switch command {
            case .auto(let fan): manualNow.remove(fan)
            case .set(let fan, let rpm): manualNow.insert(fan); targets[fan] = Float(rpm)
            }
        }
    }
}

final class SMC: @unchecked Sendable {
    init?() {}
    func uint8(_ key: String) -> UInt8? {
        switch key {
        case "FNum": return 2
        case "F0Md": return Bench.shared.isManual(0) ? 1 : 0
        case "F1Md": return Bench.shared.isManual(1) ? 1 : 0
        default: return nil
        }
    }
    func float(_ key: String) -> Float? {
        switch key {
        case "F0Ac", "F1Ac": return 2000
        case "F0Mn": return 1200
        case "F0Mx": return 6000
        case "F1Mn": return 1300
        case "F1Mx": return 5500
        case "F0Tg": return Bench.shared.target(0)
        case "F1Tg": return Bench.shared.target(1)
        case "Tp01": return 65
        case "Tg01": return 55
        default: return nil
        }
    }
}

enum FanHelperClient {
    enum Command: CustomStringConvertible {
        case auto(Int)
        case set(Int, Double)
        var description: String {
            switch self {
            case .auto(let fan): return "auto \(fan)"
            case .set(let fan, let rpm): return "set \(fan) \(Int(rpm))"
            }
        }
    }
    static func send(_ command: Command) -> String? { Bench.shared.deliver(command); return nil }
    /// Синхронно, как настоящая в пределах срока: «Забрать доступ» идёт только после возврата «Авто».
    static func sendAll(_ commands: [Command], on queue: DispatchQueue, finished: @escaping @Sendable (Command, String?) -> Void) {
        guard !commands.isEmpty else { return }
        queue.sync { commands.forEach { Bench.shared.deliver($0); finished($0, nil) } }
    }
}

enum LegacyFanHelper {
    static func restoreAuto(fans: [Int], path: String) -> String? { nil }
    static func restoreAutoWithin(fans: [Int], path: String, on queue: DispatchQueue, finished: @escaping @Sendable (String?) -> Void) {}
}

@MainActor
final class FanHelperInstaller: ObservableObject {
    enum Status: Equatable { case notInstalled, installed, outdated, ready }
    static let shared = FanHelperInstaller()
    nonisolated static let installedPath = "/nonexistent"
    @Published var status = Status.ready
    @Published var lastError: String?
    var moduleRunning = false
    var screenOpen = false
    var hasLegacySetuid = false
    var serviceAnswered = true
    var installs = 0, refreshes = 0
    var uninstalledAfter: [String]?
    func refresh(afterInstall: Bool = false) { refreshes += 1 }
    func install() { installs += 1 }
    func uninstall() { uninstalledAfter = Bench.shared.log }
    nonisolated static func outdatedDetail(fanStuckManual: Bool) -> String {
        fanStuckManual ? "Помощник устарел. Вентилятор может оставаться в ручном режиме." : "Помощник устарел."
    }
}

enum ActionLog { static func preparePrivate(file: URL) {} }

/// Чужая программа: настоящая `terminate()` в проверке недостижима.
final class FakeApp: NSRunningApplication, @unchecked Sendable {
    private(set) var terminations = 0
    override func terminate() -> Bool { terminations += 1; return true }
    override var localizedName: String? { "Macs Fan Control" }
    override var processIdentifier: pid_t { 424242 }
}

// MARK: - Стенд

@MainActor enum Stand {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 700, width: 738, height: 780),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    static func snapshot(_ screen: some View) async -> NSBitmapImageRep {
        let theme = DSTheme.dusk
        let root = screen
            .environment(\.pageActive, true)
            .environment(\.dsTint, theme.accent(.fans))
            .environment(\.dsTheme, theme)
            .background(ZStack { Color.black; theme.card })
            .dsThemed()
            .ignoresSafeArea()
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 738, height: 780)
        window.contentView = host
        await pause(0.4)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.contentView = nil
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, _ dir: String, _ name: String) {
        try? Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            .write(to: URL(fileURLWithPath: "\(dir)/\(name).rgba"))
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}

func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

// MARK: - Сцены экрана

struct Pinned {
    let name: String
    var status = FanHelperInstaller.Status.ready
    var helperError: String?
    var configs: [FanConfig] = []
    var fans: [FanReading] = twoFans
    var fullPower = false
    var conflict = false
    var hot = false
    var lastError: String?
    var phase = GameModeMachine.Phase.idle
    var gameEnabled = true
}

let twoFans = [
    FanReading(index: 0, actual: 3120, min: 1200, max: 6000, isManual: true, target: 3200),
    FanReading(index: 1, actual: 1500, min: 1300, max: 5500, isManual: false, target: 1500),
]
let constantAndAuto = [FanConfig(mode: .constant, rpm: 3200), FanConfig(mode: .auto)]
let bothSensor = [FanConfig(), FanConfig()]
let aGame = GameEntry(key: "test.fans.game", name: "Пробная игра")

@MainActor func pinnedScenes() -> [Pinned] {
    [
        Pinned(name: "normal", configs: constantAndAuto),
        Pinned(name: "shared-sensor", configs: bothSensor),
        Pinned(name: "own-sensor", configs: [FanConfig(sensor: .gpu, fromTemp: 40, toTemp: 70), FanConfig(mode: .auto)]),
        Pinned(name: "not-installed", status: .notInstalled, configs: bothSensor),
        Pinned(name: "outdated", status: .outdated, helperError: "Не удалось", configs: constantAndAuto),
        Pinned(name: "conflict", configs: constantAndAuto, conflict: true),
        Pinned(name: "hot", configs: bothSensor, hot: true, lastError: "Служба вентиляторов не ответила"),
        Pinned(name: "full-power", configs: constantAndAuto, fullPower: true),
        Pinned(name: "playing", configs: bothSensor, phase: .playing(aGame)),
        Pinned(name: "leaving", configs: bothSensor, phase: .leaving(aGame, until: .distantFuture)),
        Pinned(name: "no-fans", fans: [], gameEnabled: false),
    ]
}

@MainActor func pin(_ scene: Pinned) {
    let controller = FanController.shared, installer = FanHelperInstaller.shared, game = GameModeController.shared
    installer.status = scene.status
    installer.lastError = scene.helperError
    controller.configs = scene.configs
    controller.fullPower = scene.fullPower
    game.isEnabled = scene.gameEnabled
    // Срок считается отсюда: снимки идут дольше секунды, а на экране секунды обратного отсчёта.
    if case .leaving(let entry, _) = scene.phase {
        game.testPin(phase: .leaving(entry, until: Date().addingTimeInterval(60)), running: [])
    } else {
        game.testPin(phase: scene.phase, running: [])
    }
    controller.testPin(
        fans: scene.fans,
        cpu: scene.fans.isEmpty ? [] : [SensorReading(key: "Tp01", value: 64.4), SensorReading(key: "Tp05", value: 71.2)],
        gpu: scene.fans.isEmpty ? [] : [SensorReading(key: "Tg01", value: 53)],
        conflict: scene.conflict ? FakeApp() : nil,
        safetyTripped: scene.hot, lastError: scene.lastError)
}

@MainActor func addChips() {
    GameModeController.shared.addGame(RunningCandidate(key: aGame.key, name: aGame.name, icon: nil))
    GameModeController.shared.addGame(RunningCandidate(key: "exe:wine-game", name: "wine-game", icon: nil))
    GameModeController.shared.setLauncherGame("com.valvesoftware.steam", true)
}

// MARK: - Проверки

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

#if !FANS_BASELINE

/// Экран из одного состояния: то, что будет видеть лаунчер. Иконки по связи не идут.
@MainActor final class StateFansModel: FansModel {
    @Published var state: FansState
    var calls: [String] = []
    init(_ state: FansState) { self.state = state }

    var fans: [FanReading] { state.fans }
    var configs: [FanConfig] {
        get { state.configs }
        set { state.configs = newValue; calls.append("configs") }
    }
    var cpuSensors: [SensorReading] { state.cpuSensors }
    var gpuSensors: [SensorReading] { state.gpuSensors }
    var fullPower: Bool {
        get { state.fullPower }
        set { state.fullPower = newValue; calls.append("fullPower") }
    }
    var safetyTripped: Bool { state.safetyTripped }
    var conflict: FansConflict? { state.conflict }
    var lastError: String? { state.lastError }
    var helperStatus: FansHelperStatus { state.helperStatus }
    var helperError: String? { state.helperError }
    var gameModeEnabled: Bool {
        get { state.gameModeEnabled }
        set { state.gameModeEnabled = newValue; calls.append("gameMode") }
    }
    var myGames: [GameEntry] { state.myGames }
    var gameLaunchers: Set<String> { Set(state.gameLaunchers) }
    var addable: [RunningCandidate] { state.addable.map { RunningCandidate(key: $0.key, name: $0.name, icon: nil) } }
    var gameName: String? { state.gameName }
    var gameLeavingUntil: Date? { state.gameLeavingUntil }
    func icon(for entry: GameEntry) -> NSImage? { nil }
    func addGame(_ candidate: RunningCandidate) { calls.append("addGame") }
    func removeGame(_ entry: GameEntry) { calls.append("removeGame") }
    func setLauncherGame(_ key: String, _ isGame: Bool) { calls.append("setLauncher") }
    func refreshRunning() { calls.append("refreshRunning") }
    func setAllAuto() { calls.append("setAllAuto") }
    func closeConflictingApp(id: String) { calls.append("close") }
    func installHelper() { calls.append("install") }
    func uninstallHelper() { calls.append("uninstall") }
    func setScreenOpen(_ open: Bool) { calls.append("screenOpen \(open)") }
}

func wire(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try! encoder.encode(value)
}

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    let first = wire(value)
    guard let back = try? JSONDecoder().decode(T.self, from: first) else { return false }
    return back == value && wire(back) == first
}

@MainActor func wireChecks() {
    print("== связь")
    pin(Pinned(name: "wire", helperError: "ошибка", configs: constantAndAuto, conflict: true, lastError: "сбой",
               phase: .leaving(aGame, until: Date(timeIntervalSinceReferenceDate: 800_000_000.25))))
    GameModeController.shared.testPin(
        phase: .leaving(aGame, until: Date(timeIntervalSinceReferenceDate: 800_000_000.25)),
        running: [RunningCandidate(key: "test.fans.other", name: "Другая", icon: NSImage(size: NSSize(width: 1, height: 1)))])
    let state = FanController.shared.wireState
    check(roundTrips(state), "состояние со всеми полями: туда-обратно, те же байты")
    let json = String(decoding: wire(state), as: UTF8.self)
    check(state.conflict?.name == "Macs Fan Control" && !json.contains("424242"), "конфликт: только id и имя, pid наружу не выходит")
    check(state.addable == [GameEntry(key: "test.fans.other", name: "Другая")], "кандидат в игры: ключ и имя, без иконки")
    check(state.gameLaunchers == ["com.valvesoftware.steam"], "лаунчеры: только известные, по порядку")

    let actions: [FansAction] = [
        .setFullPower(true), .setAllAuto, .setConfigs(constantAndAuto), .setConfigs([FanConfig(mode: .constant, rpm: 2345.5)]),
        .closeConflictingApp(id: "x"), .installHelper, .uninstallHelper, .setScreenOpen(false), .setGameModeEnabled(true),
        .addGame(key: "k"), .removeGame(key: "k"), .setLauncherGame(key: "k", isGame: false), .refreshRunning,
    ]
    check(actions.allSatisfy(roundTrips), "\(actions.count) действий: туда-обратно, те же байты")
    let foreign = ["{\"terminate\":{\"pid\":1}}", "{\"setPath\":{\"_0\":\"/bin/sh\"}}", "{}"]
    check(foreign.allSatisfy { (try? JSONDecoder().decode(FansAction.self, from: Data($0.utf8))) == nil }, "чужие действия не разбираются")
    let overflow = "{\"setConfigs\":{\"_0\":[{\"fromTemp\":50,\"mode\":\"constant\",\"rpm\":1e999,\"sensor\":\"cpu\",\"toTemp\":80}]}}"
    check((try? JSONDecoder().decode(FansAction.self, from: Data(overflow.utf8))) == nil, "обороты 1e999 не разбираются")
    pin(Pinned(name: "clean", configs: bothSensor))
}

/// Отказ: есть текст, состояние прежнее, ни команды службе, ни установщика.
@MainActor func refused(_ action: FansAction, _ name: String) {
    let controller = FanController.shared, installer = FanHelperInstaller.shared
    let before = controller.wireState
    let installs = installer.installs
    let uninstalled = installer.uninstalledAfter
    Bench.shared.clearLog()
    let error = controller.handle(action)
    let same = controller.wireState == before && installer.installs == installs && installer.uninstalledAfter == uninstalled
        && Bench.shared.log.isEmpty
    check(error != nil && same, "отказ: \(name)" + (error == nil ? " — принято" : same ? "" : " — состояние изменилось"))
}

@MainActor func accepted(_ action: FansAction, _ name: String, _ result: () -> Bool = { true }) {
    let error = FanController.shared.handle(action)
    check(error == nil && result(), "принято: \(name)" + (error.map { " — отказ: \($0)" } ?? ""))
}

func config(_ change: (inout FanConfig) -> Void) -> [FanConfig] {
    var bad = FanConfig()
    change(&bad)
    return [bad, FanConfig()]
}

@MainActor func validationChecks() {
    let controller = FanController.shared, installer = FanHelperInstaller.shared, game = GameModeController.shared

    print("== обороты и кривая")
    pin(Pinned(name: "ready", configs: [FanConfig(mode: .constant, rpm: 3000), FanConfig(mode: .auto)]))
    for (bad, name) in [(Double.nan, "NaN"), (.infinity, "+inf"), (-.infinity, "-inf"), (-1, "минус"), (20_001, "выше потолка"), (1e300, "1e300")] {
        refused(.setConfigs(config { $0.rpm = bad }), "обороты \(name)")
    }
    for (from, to, name) in [(Double.nan, 80.0, "начало NaN"), (50, .nan, "конец NaN"), (-.infinity, 80, "начало -inf"), (50, .infinity, "конец +inf"),
                             (29, 80, "начало ниже 30"), (50, 101, "конец выше 100"), (80, 50, "кривая наоборот"), (50, 54, "кривая уже 5 °C"), (60, 60, "кривая нулевая")] {
        refused(.setConfigs(config { $0.fromTemp = from; $0.toTemp = to }), name)
    }
    refused(.setConfigs([FanConfig()]), "вентиляторов меньше")
    refused(.setConfigs([FanConfig(), FanConfig(), FanConfig()]), "вентиляторов больше")
    refused(.setConfigs([FanConfig(mode: .constant, rpm: 4000), FanConfig(rpm: .nan)]), "хороший первый и плохой второй: не меняется ни один")

    accepted(.setConfigs([FanConfig(mode: .constant, rpm: 9000), FanConfig(mode: .constant, rpm: 100)]), "обороты зажаты диапазоном каждого вентилятора") {
        controller.configs.map(\.rpm) == [6000, 1300]
    }
    accepted(.setConfigs([FanConfig(mode: .constant, rpm: 0), FanConfig(mode: .constant, rpm: 2500.5)]), "0 и значение внутри диапазона не меняются") {
        controller.configs.map(\.rpm) == [0, 2500.5]
    }
    accepted(.setConfigs(config { $0.fromTemp = 30; $0.toTemp = 35 }), "крайние границы ползунков снизу") { controller.configs[0].toTemp == 35 }
    accepted(.setConfigs(config { $0.fromTemp = 95; $0.toTemp = 100 }), "крайние границы ползунков сверху") { controller.configs[0].fromTemp == 95 }

    pin(Pinned(name: "no-reading", configs: bothSensor, fans: Array(twoFans.prefix(1))))
    accepted(.setConfigs([FanConfig(), FanConfig(rpm: 19_000)]), "у непрочитанного вентилятора остаётся потолок") { controller.configs[1].rpm == 19_000 }
    refused(.setConfigs([FanConfig(), FanConfig(rpm: 20_001)]), "непрочитанный вентилятор выше потолка")

    print("== управление только когда экран его даёт")
    for (name, scene) in [("помощник устарел", Pinned(name: "", status: .outdated, configs: bothSensor)),
                          ("помощника нет", Pinned(name: "", status: .notInstalled, configs: bothSensor)),
                          ("чужая программа", Pinned(name: "", configs: bothSensor, conflict: true))] {
        pin(scene)
        refused(.setFullPower(true), "\(name): полная мощность")
        refused(.setAllAuto, "\(name): всё авто")
        refused(.setConfigs([FanConfig(mode: .auto), FanConfig()]), "\(name): настройки")
    }
    pin(Pinned(name: "", status: .outdated, configs: bothSensor, fullPower: true))
    accepted(.setFullPower(false), "выключить полную мощность можно всегда") { !controller.fullPower }
    pin(Pinned(name: "", configs: constantAndAuto))
    accepted(.setFullPower(true), "полная мощность") { controller.fullPower }
    accepted(.setAllAuto, "всё авто: и полную мощность снимает") { !controller.fullPower && controller.configs.allSatisfy { $0.mode == .auto } }

    print("== чужая программа: только выданный id")
    let app = FakeApp()
    pin(Pinned(name: "", configs: bothSensor))
    refused(.closeConflictingApp(id: ""), "конфликта нет, пустой id")
    controller.testPin(fans: twoFans, cpu: [], gpu: [], conflict: app, safetyTripped: false, lastError: nil)
    guard let issued = controller.wireState.conflict?.id, !issued.isEmpty else { return check(false, "id выдан") }
    refused(.closeConflictingApp(id: "424242"), "pid вместо id")
    refused(.closeConflictingApp(id: "com.crystalidea.macsfancontrol"), "bundle id вместо id")
    refused(.closeConflictingApp(id: ""), "пустой id")
    check(app.terminations == 0, "после отказов программа не закрывалась")
    let next = FakeApp()
    controller.testPin(fans: twoFans, cpu: [], gpu: [], conflict: next, safetyTripped: false, lastError: nil)
    check(controller.wireState.conflict?.id != issued, "другая программа — другой id")
    refused(.closeConflictingApp(id: issued), "id прежней программы")
    check(app.terminations == 0 && next.terminations == 0, "устаревший id не закрыл никого")
    accepted(.closeConflictingApp(id: controller.wireState.conflict!.id), "свой id закрывает свою программу") { next.terminations == 1 && app.terminations == 0 }

    print("== установка и удаление: только действия, окна пароля в сборке нет")
    pin(Pinned(name: "", configs: bothSensor))
    refused(.installHelper, "доступ в порядке: окно пароля не нужно")
    installer.status = .installed
    refused(.installHelper, "служба ещё не спрошена: окно пароля не нужно")
    installer.status = .outdated
    accepted(.installHelper, "устаревший помощник") { installer.installs == 1 }
    installer.status = .notInstalled
    accepted(.installHelper, "помощника нет") { installer.installs == 2 }
    refused(.uninstallHelper, "удалять нечего")
    installer.status = .ready
    Bench.shared.setManual(0)
    Bench.shared.clearLog()
    accepted(.uninstallHelper, "удаление: сначала вентилятор в «Авто», потом файлы") { installer.uninstalledAfter == ["auto 0"] }

    print("== игры: только ключи из своих списков")
    pin(Pinned(name: "", configs: bothSensor))
    game.testPin(phase: .idle, running: [RunningCandidate(key: "test.fans.new", name: "Новая игра", icon: nil),
                                         RunningCandidate(key: aGame.key, name: "Другое имя", icon: nil)])
    refused(.addGame(key: "/Applications/Evil.app"), "путь вместо ключа")
    refused(.addGame(key: String(repeating: "x", count: 100_000)), "длинная строка")
    refused(.addGame(key: aGame.key), "уже в списке")
    accepted(.addGame(key: "test.fans.new"), "ключ из списка, имя своё") { game.myGames.last == GameEntry(key: "test.fans.new", name: "Новая игра") }
    refused(.removeGame(key: "test.fans.нет"), "убрать то, чего нет")
    accepted(.removeGame(key: "test.fans.new"), "убрать своё") { !game.myGames.contains { $0.key == "test.fans.new" } }
    refused(.setLauncherGame(key: "test.fans.evil", isGame: true), "неизвестный лаунчер")
    check(!game.gameLaunchers.contains("test.fans.evil"), "неизвестный лаунчер в настройки не попал")
    accepted(.setLauncherGame(key: "com.gog.galaxy", isGame: true), "известный лаунчер") { game.isLauncherGame("com.gog.galaxy") }
    accepted(.setLauncherGame(key: "com.gog.galaxy", isGame: false), "снять лаунчер") { !game.isLauncherGame("com.gog.galaxy") }
    accepted(.setGameModeEnabled(false), "режим игр выключен") { !game.isEnabled }
    accepted(.setGameModeEnabled(true), "режим игр включён") { game.isEnabled }
    let refreshes = installer.refreshes
    accepted(.setScreenOpen(true), "экран открыт: служба спрошена") { installer.screenOpen && installer.refreshes == refreshes + 1 }
    accepted(.setScreenOpen(false), "экран закрыт") { !installer.screenOpen && installer.refreshes == refreshes + 1 }
}

/// Такт настоящий, служба поддельная: что из действий доходит до службы.
@MainActor func serviceChecks() async {
    print("== до службы доходит только проверенное")
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty else {
        return print("skip Macs Fan Control запущен: такт уступает ему, эту часть не проверить")
    }
    let controller = FanController.shared
    pin(Pinned(name: "", configs: [FanConfig(mode: .auto), FanConfig(mode: .auto)]))
    Bench.shared.clearLog()
    controller.start()
    func logged(_ expected: String) async -> Bool {
        for _ in 0..<150 {
            if Bench.shared.log.contains(expected) { return true }
            await pause(0.02)
        }
        return false
    }
    accepted(.setConfigs([FanConfig(mode: .constant, rpm: 9000), FanConfig(mode: .auto)]), "обороты выше диапазона")
    check(await logged("set 0 6000"), "служба получила зажатые 6000")
    Bench.shared.clearLog()
    refused(.setConfigs([FanConfig(mode: .constant, rpm: .nan), FanConfig(mode: .auto)]), "NaN: такт не падает на Int(rpm)")
    await pause(0.5)
    check(Bench.shared.log.isEmpty, "после отказа команд нет")
    controller.stop()
    check(Bench.shared.log.contains("auto 0") && !Bench.shared.isManual(0), "остановка: вентилятор вернулся в «Авто»")
}

@MainActor func forwardingChecks() {
    print("== встроенная модель")
    let model = BuiltInFansModel.shared
    var fired = 0
    let sink = model.objectWillChange.sink { fired += 1 }
    FanHelperInstaller.shared.lastError = "изменилось"
    let afterInstaller = fired
    GameModeController.shared.isEnabled.toggle()
    let afterGame = fired
    FanController.shared.fullPower.toggle()
    check(afterInstaller == 1 && afterGame == 2 && fired == 3, "экран узнаёт об изменении каждого из трёх контроллеров")
    FanController.shared.fullPower = false
    FanHelperInstaller.shared.lastError = nil
    sink.cancel()
}

func differingPixels(_ a: Data?, _ b: Data, bytesPerPixel: Int) -> Int? {
    guard let a, a.count == b.count else { return nil }
    return stride(from: 0, to: a.count, by: bytesPerPixel).reduce(0) { sum, i in
        sum + (a[i..<(i + bytesPerPixel)] == b[i..<(i + bytesPerPixel)] ? 0 : 1)
    }
}

func raw(_ bitmap: NSBitmapImageRep) -> Data { Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }

@MainActor func pixelChecks(baseline: String, own: String) async {
    print("== экран")
    var normal: Data?
    for scene in pinnedScenes() {
        pin(scene)
        let shot = await Stand.snapshot(FansView())
        Stand.save(shot, own, scene.name)
        let data = raw(shot), bytes = shot.bitsPerPixel / 8, total = shot.pixelsWide * shot.pixelsHigh
        let base = try? Data(contentsOf: URL(fileURLWithPath: "\(baseline)/\(scene.name).rgba"))
        let before = differingPixels(base, data, bytesPerPixel: bytes)
        check(before == 0, "\(scene.name): старый и новый экран, разных пикселей \(before.map(String.init) ?? "размер не совпал") из \(total)")

        // Состояние прошло через JSON: лаунчеру этого хватает, чтобы нарисовать то же самое.
        let state = try! JSONDecoder().decode(FansState.self, from: wire(FanController.shared.wireState))
        let model = StateFansModel(state)
        if state.gameLeavingUntil != nil { model.state.gameLeavingUntil = Date().addingTimeInterval(60) }
        let remote = raw(await Stand.snapshot(FansView(model: model)))
        let viaState = differingPixels(remote, data, bytesPerPixel: bytes)
        check(viaState == 0, "\(scene.name): экран из одного состояния, разных пикселей \(viaState.map(String.init) ?? "размер не совпал")")
        check(model.calls.contains("screenOpen true") && model.calls.contains("refreshRunning"), "\(scene.name): поддельная модель получила открытие экрана")

        if let normal {
            check((differingPixels(normal, data, bytesPerPixel: bytes) ?? 1) > 0, "\(scene.name): отличается от обычного экрана, снимок не пустой")
        } else {
            normal = data
        }
    }
}

#endif

// MARK: - Запуск

let arguments = CommandLine.arguments
guard arguments.count >= 3, ["pixels", "check"].contains(arguments[1]) else {
    print("FAIL pixels <папка> | check <папка базы> <своя папка> <домашняя папка>")
    exit(2)
}

// Журнал контроллера пишется в домашнюю папку: под настоящей проверка не идёт.
let home = arguments[arguments[1] == "pixels" ? 3 : 4]
guard FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path else {
    print("FAIL домашняя папка не подменена: \(FileManager.default.homeDirectoryForCurrentUser.path)")
    exit(1)
}

// Настройки контроллеров идут либо в домен этого бинарника, либо в тестовый suite: убираем только свои ключи.
let settingsKeys = ["FanConfigs", "GameModeEnabled", "GameModeMyGames", "GameModeGameLaunchers", "GameModeLiftedLaunchers"]
func cleanSettings() {
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
    settingsKeys.forEach { Kit.defaults.removeObject(forKey: $0) }
    UserDefaults.standard.synchronize()
    Kit.defaults.synchronize()
}
cleanSettings()

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

Task { @MainActor in
    addChips()
    if arguments[1] == "pixels" {
        let dir = arguments[2]
        for scene in pinnedScenes() {
            pin(scene)
            Stand.save(await Stand.snapshot(FansView()), dir, scene.name)
        }
        print("снимки старого экрана готовы")
    } else {
        #if !FANS_BASELINE
        wireChecks()
        validationChecks()
        forwardingChecks()
        await pixelChecks(baseline: arguments[2], own: arguments[3])
        await serviceChecks()
        #endif
        print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    }
    cleanSettings()
    exit(failures == 0 ? 0 : 1)
}
application.run()
