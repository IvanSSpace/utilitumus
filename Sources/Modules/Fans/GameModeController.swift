import Foundation
import AppKit

struct RunningCandidate: Identifiable {
    let key: String
    let name: String
    let icon: NSImage?
    var id: String { key }
}

/// «Максимум в играх»: следит, какая программа на переднем плане, и решает,
/// нужны ли вентиляторам максимум. Сами вентиляторы двигает `FanController`.
@MainActor
final class GameModeController: ObservableObject {
    static let shared = GameModeController()

    private static let enabledKey = "GameModeEnabled"
    private static let gamesKey = "GameModeMyGames"
    private static let liftedKey = "GameModeLiftedLaunchers"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            guard isRunning, isEnabled != oldValue else { return }
            if isEnabled {
                FanController.log("«Максимум в играх» включён")
                evaluateFrontmost()
            } else {
                FanController.log("«Максимум в играх» выключен")
                cancelCurrent()
            }
        }
    }
    @Published private(set) var myGames: [GameEntry]
    /// Лаунчеры, у которых пользователь снял исключение.
    @Published private(set) var liftedLaunchers: Set<String>
    @Published private(set) var running: [RunningCandidate] = []
    @Published private(set) var phase: GameModeMachine.Phase = .idle

    var isActive: Bool { phase != .idle }

    private var machine = GameModeMachine()
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    /// Процесс текущей игры: у завершённого процесса путь к файлу уже не прочесть.
    private var gamePID: pid_t?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        myGames = defaults.data(forKey: Self.gamesKey)
            .flatMap { try? JSONDecoder().decode([GameEntry].self, from: $0) } ?? []
        liftedLaunchers = Set(defaults.stringArray(forKey: Self.liftedKey) ?? [])
    }

    private var rules: GameRules {
        GameRules(myGames: Set(myGames.map(\.key)),
                  excludedLaunchers: Set(GameRules.defaultLaunchers.map(\.key)).subtracting(liftedLaunchers))
    }

    // MARK: - Запуск и остановка

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { GameModeController.shared.activated(app) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { GameModeController.shared.terminated(app) }
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { GameModeController.shared.refreshRunning() }
            },
        ]
        refreshRunning()
        if isEnabled { evaluateFrontmost() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers = []
        // Без лога и без apply: вентиляторы отдаёт сам FanController.stop().
        machine.reset()
        phase = .idle
        gamePID = nil
        timer?.invalidate()
        timer = nil
        running = []
    }

    /// «Всё авто»: забыть текущую игру. Снова включится, когда игра станет передней.
    func cancelCurrent() {
        guard machine.isActive else { return }
        FanController.log("игровой режим сброшен вручную → обычный режим")
        machine.reset()
        gamePID = nil
        sync(wasActive: true)
    }

    // MARK: - События

    private func evaluateFrontmost() {
        activated(NSWorkspace.shared.frontmostApplication)
    }

    private func activated(_ app: NSRunningApplication?) {
        guard isRunning, isEnabled, let app else { return }
        refreshRunning()
        let info = Self.info(app)
        var entry: GameEntry?
        if rules.isGame(info), let key = info.key { entry = GameEntry(key: key, name: info.name) }
        let wasActive = machine.isActive
        let event = machine.activated(entry, now: Date())
        if case .started = event { gamePID = app.processIdentifier }
        if case .resumed = event { gamePID = app.processIdentifier }
        report(event)
        sync(wasActive: wasActive)
    }

    private func terminated(_ app: NSRunningApplication?) {
        guard isRunning, let app else { return }
        refreshRunning()
        guard isEnabled, let game = machine.game else { return }
        let key = app.processIdentifier == gamePID ? game.key : Self.info(app).key
        guard let key else { return }
        let wasActive = machine.isActive
        let event = machine.terminated(key: key)
        report(event)
        if event != nil { gamePID = nil }
        sync(wasActive: wasActive)
    }

    private func tick() {
        let wasActive = machine.isActive
        report(machine.tick(now: Date()))
        sync(wasActive: wasActive)
    }

    private func report(_ event: GameModeMachine.Event?) {
        guard let event else { return }
        switch event {
        case .started(let g): FanController.log("игра: \(g.name) → максимум")
        case .leftGame(let g):
            FanController.log("ушёл из игры: \(g.name)")
            FanController.log("вернуть через \(Int(GameModeMachine.grace)) с")
        case .resumed(let g): FanController.log("вернулся в игру: \(g.name), возврат отменён")
        case .expired(let g): FanController.log("\(Int(GameModeMachine.grace)) с вне игры (\(g.name)) → обычный режим")
        case .closed(let g): FanController.log("игра закрылась: \(g.name) → обычный режим")
        }
    }

    /// Обновить то, что видит экран, таймер ожидания и, если режим включился или
    /// выключился, вентиляторы.
    private func sync(wasActive: Bool) {
        phase = machine.phase
        timer?.invalidate()
        timer = nil
        if case .leaving = phase {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in GameModeController.shared.tick() }
            }
        }
        if wasActive != machine.isActive { FanController.shared.gameModeChanged() }
    }

    // MARK: - Списки

    func addGame(_ candidate: RunningCandidate) {
        guard !myGames.contains(where: { $0.key == candidate.key }) else { return }
        myGames.append(GameEntry(key: candidate.key, name: candidate.name))
        persistGames()
    }

    func removeGame(_ entry: GameEntry) {
        myGames.removeAll { $0.key == entry.key }
        persistGames()
    }

    func isLauncherExcluded(_ key: String) -> Bool { !liftedLaunchers.contains(key) }

    func setLauncherExcluded(_ key: String, _ excluded: Bool) {
        if excluded { liftedLaunchers.remove(key) } else { liftedLaunchers.insert(key) }
        UserDefaults.standard.set(Array(liftedLaunchers), forKey: Self.liftedKey)
    }

    /// Программы, которые можно добавить: обычные, ещё не в списке, не сам Utilitumus.
    var addable: [RunningCandidate] {
        let known = Set(myGames.map(\.key))
        return running.filter { !known.contains($0.key) }
    }

    func icon(for entry: GameEntry) -> NSImage? {
        if let icon = running.first(where: { $0.key == entry.key })?.icon { return icon }
        guard !entry.key.hasPrefix("exe:"),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.key) else { return nil }
        return Self.smallIcon(NSWorkspace.shared.icon(forFile: url.path))
    }

    func refreshRunning() {
        running = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  let key = Self.info(app).key else { return nil }
            return RunningCandidate(key: key, name: Self.info(app).name, icon: app.icon.map(Self.smallIcon))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persistGames() {
        if let data = try? JSONEncoder().encode(myGames) {
            UserDefaults.standard.set(data, forKey: Self.gamesKey)
        }
    }

    // MARK: - Вспомогательное

    private static func info(_ app: NSRunningApplication) -> AppInfo {
        let exe = app.executableURL?.lastPathComponent
        var category: String?
        if let url = app.bundleURL, url.pathExtension == "app" {
            category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        }
        let name = app.localizedName ?? exe ?? app.bundleIdentifier ?? "?"
        return AppInfo(bundleID: app.bundleIdentifier, executableName: exe, name: name, category: category)
    }

    /// Копия: иконка из `NSRunningApplication` общая, менять её размер нельзя.
    private static func smallIcon(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}
