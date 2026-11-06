import AppKit
import Combine
import Foundation

/// Состояние модуля «Боты». Замеры идут только пока открыт экран (аренда): без неё ни таймера, ни опроса.
/// Команды из bots.toml запускаются одним путём, `BotRunner`; сюда приходят только id бота и кнопка.
@MainActor
final class BotsStore: ObservableObject, BotsModel {
    static let shared = BotsStore()

    @Published private(set) var state = BotsState.empty

    /// Длиннее настоящего id бота; ещё и предел на разбор действия.
    static let maxIDBytes = 256
    static let maxActionBytes = maxIDBytes + 256
    static let interval: TimeInterval = 5

    private struct Plan {
        let id: UUID
        let botID: String
        let verb: BotVerb
        /// Что человек увидел в вопросе. Запуск сверяет это с файлом.
        let argv: [String]
    }

    private let file: URL
    private let readLaunchd: @Sendable () -> [String: Int32?]
    private let probe: BotsMonitor.Probe
    private let execute: @Sendable (BotVerb, String, [String], URL) throws -> String
    private let discoveryRoots: @Sendable () -> BotsDiscovery.Roots
    /// Найденные боты с путями и меткой: на связь уходит только id, имя и пояснение.
    private var candidates: [String: BotsDiscovery.Candidate] = [:]
    private var scanGeneration = 0
    private var pending: Plan?
    private var leases = 0
    private var loop: Task<Void, Never>?
    private var reading = false
    private var again = false
    #if KIT_TEST_DEFAULTS
    fileprivate(set) var testFrozen = false
    #endif

    /// Параметры — для проверок: они не должны читать настоящий launchd и запускать что-либо.
    init(file: URL = BotRegistry.url,
         readLaunchd: @escaping @Sendable () -> [String: Int32?] = { BotsMonitor.readLaunchd() },
         probe: @escaping BotsMonitor.Probe = { BotsMonitor.liveProbe($0) },
         execute: @escaping @Sendable (BotVerb, String, [String], URL) throws -> String = { try BotRunner.run($0, id: $1, file: $3, expected: $2) },
         discoveryRoots: @escaping @Sendable () -> BotsDiscovery.Roots = { BotsDiscovery.live }) {
        self.discoveryRoots = discoveryRoots
        self.file = file
        self.readLaunchd = readLaunchd
        self.probe = probe
        self.execute = execute
    }

    // MARK: Аренда экрана

    func screenAppeared() {
        leases += 1
        guard loop == nil else { return }
        refresh()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func screenDisappeared() {
        leases = max(0, leases - 1)
        guard leases == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    var isLeased: Bool { leases > 0 }

    /// Остановка модуля: цикл снят, ожидающее подтверждение забыто.
    func shutDown() {
        leases = 0
        loop?.cancel()
        loop = nil
        pending = nil
        state.prompt = nil
        scanGeneration += 1
        candidates = [:]
        state.discovery = nil
    }

    // MARK: Замер

    func refreshNow() { refresh() }

    func refresh() {
        #if KIT_TEST_DEFAULTS
        if testFrozen { return }
        #endif
        guard !reading else { again = true; return }
        reading = true
        let file = file, readLaunchd = readLaunchd, probe = probe
        let apps = runningApps()
        Task {
            let fresh = await Task.detached(priority: .utility) { Self.measure(file: file, launchd: readLaunchd(), apps: apps, probe: probe) }.value
            apply(fresh)
            reading = false
            if again { again = false; refresh() }
        }
    }

    /// Приложения с bundle id из файла: список берётся здесь, на главном потоке.
    private func runningApps() -> [String: [Int32]] {
        let wanted = Set(BotRegistry.load(file).flatMap(\.bundleIDs))
        guard !wanted.isEmpty else { return [:] }
        var out: [String: [Int32]] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, wanted.contains(id) { out[id, default: []].append(app.processIdentifier) }
        }
        return out
    }

    nonisolated static func measure(file: URL, launchd: [String: Int32?], apps: [String: [Int32]], probe: BotsMonitor.Probe) -> (BotsFileState, [BotCard]) {
        let read = BotRegistry.read(file)
        let dirs = BotsMonitor.pidsByDir(Set(read.bots.compactMap(\.watchDir)))
        return (BotsMonitor.fileState(read), BotsMonitor.cards(read.bots, launchd: launchd, appPIDs: apps, dirPIDs: dirs, probe: probe))
    }

    private func apply(_ fresh: (BotsFileState, [BotCard])) {
        var next = state
        next.file = fresh.0
        next.bots = fresh.1
        // Ожидающее подтверждение живёт, пока бот и кнопка остаются в файле.
        if let p = pending, !fresh.1.contains(where: { $0.id == p.botID && $0.verbs.contains(p.verb) }) {
            pending = nil
            next.prompt = nil
        }
        if next != state { state = next }
    }

    // MARK: Действия

    func request(_ bot: BotCard, _ verb: BotVerb) { _ = handleRequest(id: bot.id, verb: verb) }

    func cancel() {
        guard !state.running else { return }
        pending = nil
        state.prompt = nil
    }

    func confirm(_ planID: UUID) { _ = handleConfirm(planID) }

    func dismissNotice() { state.notice = nil }

    /// Просьба: бот и кнопка должны быть и в файле сейчас, и на экране. План строит модуль по файлу.
    fileprivate func handleRequest(id: String, verb: BotVerb) -> String? {
        guard id.utf8.count <= Self.maxIDBytes else { return "Непонятная команда" }
        guard !state.running else { return "Уже выполняется другое действие" }
        guard let card = state.bots.first(where: { $0.id == id }), card.verbs.contains(verb),
              let spec = BotRegistry.load(file).first(where: { $0.id == id }), let cmd = spec.commands[verb] else {
            return "Такого действия на экране уже нет — обнови экран"
        }
        var argv: [String] = []
        if case .argv(let list) = cmd { argv = list }
        let command = Self.shown(argv)
        let plan = Plan(id: UUID(), botID: id, verb: verb, argv: argv)
        pending = plan
        state.prompt = BotsPrompt(
            id: plan.id, title: BotsDiscovery.clean("\(verb.title) \(spec.name)", Self.maxShown),
            message: BotsDiscovery.clean((command.isEmpty ? "Выполнит команду из bots.toml." : "Выполнит \(command).") + (spec.note.isEmpty ? "" : " \(spec.note)"), Self.maxShown),
            command: command, confirmTitle: verb.title, destructive: verb == .stop)
        return nil
    }

    fileprivate func handleCancel() -> String? {
        guard !state.running else { return "Уже выполняется другое действие" }
        cancel()
        return nil
    }

    fileprivate func handleConfirm(_ planID: UUID) -> String? {
        guard !state.running else { return "Уже выполняется другое действие" }
        guard let plan = pending, plan.id == planID else { return "Подтверждение устарело — попробуй ещё раз" }
        run(plan)
        return nil
    }

    /// Быстрое действие: тот же путь, но без листа: человека спросил центр. Кнопка проверяется по свежему файлу и состоянию.
    fileprivate func handleQuick(id: String, verb: BotVerb, sum: String) -> String? {
        guard id.utf8.count <= Self.maxIDBytes else { return "Непонятная команда" }
        guard !state.running else { return "Уже выполняется другое действие" }
        guard state.bots.first(where: { $0.id == id })?.verbs.contains(verb) == true,
              case .argv(let argv)? = BotRegistry.load(file).first(where: { $0.id == id })?.commands[verb] else {
            return "Такого действия уже нет — обнови экран"
        }
        guard BotRunner.fingerprint(argv) == sum else { return BotRunner.changedMessage }
        run(Plan(id: UUID(), botID: id, verb: verb, argv: argv))
        return nil
    }

    /// Описания из файла сейчас: вопрос быстрого действия показывает команду, а действие несёт её отпечаток.
    func specsNow() -> [BotSpec] { BotRegistry.load(file) }

    /// Команда в вопросе: без управляющих символов и смены направления текста, которыми подпись можно выдать за другую.
    nonisolated static func shown(_ argv: [String]) -> String { BotsDiscovery.clean(Exec.display(argv), maxShown) }
    private nonisolated static let maxShown = 2000

    private func run(_ plan: Plan) {
        pending = nil
        state.prompt = nil
        state.running = true
        state.notice = nil
        let file = file, execute = execute
        Task {
            let outcome: BotsNotice = await Task.detached(priority: .userInitiated) {
                do {
                    let message = try execute(plan.verb, plan.botID, plan.argv, file)
                    ActionLog.write(kind: "bot", label: "\(plan.verb.title) \(plan.botID)", targets: [], ok: true, message: message, id: plan.id.uuidString)
                    return BotsNotice(text: message, isError: false)
                } catch let e as BackgroundActionError {
                    ActionLog.write(kind: "bot", label: "\(plan.verb.title) \(plan.botID)", targets: [], ok: false, message: e.message, id: plan.id.uuidString)
                    return BotsNotice(text: e.message, isError: true)
                } catch {
                    return BotsNotice(text: "внутренняя ошибка", isError: true)
                }
            }.value
            state.running = false
            state.notice = outcome
            refresh()
        }
    }

    // MARK: Поиск ботов

    func findBots() { _ = handleFind() }
    func addFound(_ id: String) { _ = handleAdd(id) }
    func dismissFound() { _ = handleDismissFound() }

    /// Поиск идёт по просьбе, в фоне, и ничего не меняет: только читает плисты и папки проектов.
    fileprivate func handleFind() -> String? {
        if state.discovery?.scanning == true { return "Поиск уже идёт" }
        scanGeneration += 1
        let generation = scanGeneration
        candidates = [:]
        state.discovery = .scanning
        let roots = discoveryRoots(), file = file
        Task {
            let result = await Task.detached(priority: .utility) {
                BotsDiscovery.scan(roots, known: BotsEntryWriter.known(BotRegistry.load(file), home: roots.home))
            }.value
            guard generation == scanGeneration else { return }
            candidates = Dictionary(result.candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            state.discovery = BotsDiscoveryState(scanning: false, found: result.candidates.map { c in
                BotFound(id: c.id, name: c.name, place: c.place, why: c.why, possible: c.strength == .possible, monitorOnly: c.label == nil)
            }, skipped: result.skipped)
        }
        return nil
    }

    fileprivate func handleDismissFound() -> String? {
        scanGeneration += 1
        candidates = [:]
        state.discovery = nil
        return nil
    }

    /// Добавление: по id из последнего поиска. Запись строит утилита, центр путей и команд не присылает.
    fileprivate func handleAdd(_ id: String) -> String? {
        guard id.utf8.count <= Self.maxIDBytes else { return "Непонятная команда" }
        guard let candidate = candidates[id], state.discovery?.scanning == false else { return "Такого бота в результатах уже нет — найдите заново" }
        let roots = discoveryRoots()
        do {
            let written = try BotsEntryWriter.append(BotsEntryWriter.entry(for: candidate, uid: roots.uid, home: roots.home), to: file)
            candidates[id] = nil
            state.discovery?.found.removeAll { $0.id == id }
            state.notice = BotsNotice(text: "Добавлен: \(written.name). Он в bots.toml и на экране.", isError: false)
            refresh()
        } catch let e as BackgroundActionError {
            state.notice = BotsNotice(text: e.message, isError: true)
        } catch {
            state.notice = BotsNotice(text: "Не удалось добавить", isError: true)
        }
        return nil
    }

    // MARK: Связь

    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: BotsAction.self, limit: Self.maxActionBytes, state: { state }) { handle($0) }
    }

    /// Действие из связи: сначала проверка, изменения только после неё. Текст — если действие не выполнено.
    func handle(_ action: BotsAction) -> String? {
        switch action {
        case .refresh: refresh()
        case .request(let id, let verb): return handleRequest(id: id, verb: verb)
        case .cancel: return handleCancel()
        case .confirm(let planID): return handleConfirm(planID)
        case .dismissNotice: dismissNotice()
        case .quick(let id, let verb, let sum): return handleQuick(id: id, verb: verb, sum: sum)
        case .find: return handleFind()
        case .add(let id): return handleAdd(id)
        case .dismissFound: return handleDismissFound()
        }
        return nil
    }
}

#if KIT_TEST_DEFAULTS
extension BotsStore {
    /// Стенд ставит состояние сам и снимает замеры: настоящие launchctl и процессы ему не нужны.
    func testPin(_ pinned: BotsState) {
        testFrozen = true
        state = pinned
    }

    func testUnpin() { testFrozen = false }
}
#endif
