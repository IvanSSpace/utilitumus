import Darwin
import Foundation

// Действия над фоновым: агенты launchd (launchctl bootout / disable / enable / bootstrap) и боты из bots.toml.
// Защита та же, что у `StopExecutor`, и из actions.py: всё, что показано на подтверждении, перед командой
// проверяется заново по свежему скану; системные и Apple-задания, боты, сама панель и системный домен не трогаются.

extension ActionLog {
    /// Цели для журнала: без аргументов.
    static func targets(of plan: StopPlan) -> [[String: Any]] {
        plan.targets.map { ["pid": Int($0.pid), "name": $0.processName] }
    }

    /// Остановка процессов из «Памяти» и «Сессий»: тот же журнал.
    static func record(stop plan: StopPlan, result: StopResult) {
        write(kind: "stop-tree", label: plan.title, targets: targets(of: plan), ok: result.ok, message: result.message,
              id: "stop:\(plan.id.uuidString)")
    }
}

// MARK: План: что покажем на подтверждении

struct BackgroundPlan: Identifiable, Sendable {
    enum Action: Sendable {
        case agent(AgentVerb, AgentItem)
        case bot(BotVerb, BotSpec)
    }

    let id = UUID()
    var action: Action
    var title: String
    var message: String
    /// Что будет запущено: команды launchctl или команда бота.
    var command: String
    var targets: [AgentTarget]
    var totalMB: Double
    var confirmTitle: String
    var destructive: Bool

    /// Что показать на подтверждении.
    var prompt: LoadBackgroundPrompt {
        LoadBackgroundPrompt(id: id, title: title, message: message, command: command, targets: targets,
                             totalMB: totalMB, confirmTitle: confirmTitle, destructive: destructive)
    }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Подтверждение называет последствие из каталога производителей.
    static func agent(_ a: AgentItem, _ verb: AgentVerb) -> BackgroundPlan {
        let cmds = LaunchAgents.argv(verb, label: a.label, plist: a.plist, loaded: a.loaded)
        let what = a.name + (a.vendor.isEmpty ? "" : " от \(a.vendor)")
        let note = capitalized(a.note)
        let freed = a.memMB > 0 ? " Освободит ≈\(Fmt.mb(a.memMB))." : ""
        let title: String, message: String, button: String
        switch verb {
        case .stop:
            title = "Остановить \(a.name)"
            button = "Остановить"
            message = "Остановит \(what) до следующего входа.\(freed) \(note)."
                + (a.runAtLoad || a.keepalive ? " После перезагрузки запустится снова." : "")
        case .disable:
            title = "Убрать \(a.name) из автозапуска"
            button = "Не запускать при входе"
            let head: String
            if a.isRunning {
                head = "Остановит \(what) и уберёт из автозапуска.\(freed)"
            } else if a.loaded {
                // Загружен, ждёт запуска: остановить нечего, но выгрузить надо — иначе запустится сам.
                head = "Уберёт \(what) из автозапуска: сам не запустится и при входе."
            } else {
                head = "Уберёт \(what) из автозапуска: при входе не запустится."
            }
            message = head + " \(note). Вернуть можно на вкладке «Фоновое»."
        case .enable:
            title = "Вернуть \(a.name)"
            button = "Вернуть"
            let start = cmds.count > 1 ? " и запустит" : ", запустится при следующем входе"
            message = "Вернёт \(what) в автозапуск\(start) (launchctl \(cmds.map { $0[0] }.joined(separator: " и ")))."
        }
        let targets = verb == .enable ? [] : a.targets
        return BackgroundPlan(
            action: .agent(verb, a), title: title, message: message,
            command: cmds.map { Exec.display(["launchctl"] + $0) }.joined(separator: " && "),
            targets: targets, totalMB: targets.reduce(0) { $0 + $1.memMB }, confirmTitle: button, destructive: verb != .enable)
    }

    static func bot(_ b: BotItem, _ verb: BotVerb) -> BackgroundPlan {
        var cmd = ""
        if case .argv(let argv)? = b.spec.commands[verb] { cmd = BotRunner.shown(argv) }
        return BackgroundPlan(
            action: .bot(verb, b.spec), title: ScreenText.clean("\(verb.title) \(b.name)", BotRunner.maxShown),
            message: ScreenText.clean((cmd.isEmpty ? "Выполнит команду из bots.toml." : "Выполнит \(cmd).") + (b.spec.note.isEmpty ? "" : " \(b.spec.note)"), BotRunner.maxShown),
            command: cmd, targets: [], totalMB: 0, confirmTitle: verb.title, destructive: verb == .stop)
    }
}

// MARK: Исполнитель

/// Выполняет план по свежим данным: свежие launchctl list и скан процессов, все запреты заново, одно действие за раз.
/// Работает вне движка замеров: команды бывают долгими (до 30–60 с), а замеры на это время вставать не должны.
final class BackgroundExecutor: @unchecked Sendable {
    static let agentTimeout: TimeInterval = 30
    static let botTimeout: TimeInterval = BotRunner.timeout
    /// После bootout ждём, пока launchctl list перестанет показывать pid агента.
    static let agentWait: TimeInterval = 3

    private let gate = NSLock()
    private let scanner = ProcessScanner()

    func execute(_ plan: BackgroundPlan) -> StopResult {
        guard gate.try() else { return StopResult(ok: false, message: "Уже выполняется другое действие", freedMB: 0) }
        defer { gate.unlock() }
        var targets: [[String: Any]] = []
        var command = "", output = ""
        let kind: String, label: String
        switch plan.action {
        case .agent(_, let a): kind = "agent"; label = plan.title; _ = a
        case .bot: kind = "bot"; label = plan.title
        }
        do {
            let result: StopResult
            switch plan.action {
            case .agent(let verb, let item):
                result = try agent(verb, item, targets: &targets, command: &command, output: &output)
            case .bot(let verb, let spec):
                result = try bot(verb, spec, command: &command, output: &output)
            }
            ActionLog.write(kind: kind, label: label, targets: targets, ok: true, message: result.message,
                            id: plan.id.uuidString)
            return result
        } catch let e as BackgroundActionError {
            ActionLog.write(kind: kind, label: label, targets: targets, ok: false, message: e.message,
                            id: plan.id.uuidString)
            return StopResult(ok: false, message: e.message, freedMB: 0)
        } catch {
            return StopResult(ok: false, message: "внутренняя ошибка", freedMB: 0)
        }
    }

    // MARK: Агент

    private func jobs() -> [String: Int32?]? {
        guard let text = Tool.run(Exec.launchctl, ["list"], timeout: 10) else { return nil }
        let parsed = LaunchdJobs.parse(text)
        return parsed.isEmpty ? nil : parsed
    }

    private func agent(_ verb: AgentVerb, _ item: AgentItem, targets: inout [[String: Any]], command: inout String,
                       output: inout String) throws -> StopResult {
        let label = item.label
        let bots = BotRegistry.load()
        let state = LaunchState.shared
        let rootPlist = state.plists(LaunchAgents.systemDirs)[label]?.plist
        let systemJob = item.domain != "gui" || rootPlist != nil
        guard let jobs = jobs() else { throw BackgroundActionError(message: "launchctl не ответил — повтори позже") }
        let loaded = jobs.keys.contains(label)
        let pid: Int32? = jobs[label] ?? nil

        let procs = scanner.scan(rootMemory: [:], compressed: [:])
        // Служба macOS или нет — по свежим plist и пути процесса, как при составлении списка.
        let apple = LaunchAgents.isAppleService(label: label, plist: state.plists(LaunchAgents.guiDirs)[label]?.plist ?? rootPlist,
                                                exe: pid.flatMap { procs[$0]?.exe })
        if let why = LaunchAgents.whyRefused(label: label, domain: systemJob ? "system" : "gui", botLabels: LaunchAgents.botLabels(bots),
                                             appleService: apple) {
            throw BackgroundActionError(message: "Не трогаю \(label): \(why)")
        }
        let tree = ProcessTree(procs)
        let sub = pid.flatMap { procs[$0] != nil ? tree.subtree(of: $0) : nil } ?? []
        let fence = Protection.fence(procs: procs, tree: tree, extra: BotRegistry.fence(bots, procs: procs, tree: tree, launchd: jobs))
        if let why = LaunchAgents.whyTree(procs: procs, tree: sub, fenced: fence) {
            throw BackgroundActionError(message: "Не трогаю \(label): \(why)")
        }
        if verb == .stop, !loaded { throw BackgroundActionError(message: "Агент уже остановлен — обновите экран") }
        let plist = verb == .enable && !loaded ? item.plist : nil
        if let plist, !state.isOwnPlist(plist, label: label) {
            throw BackgroundActionError(message: "plist агента сменился или лежит не в LaunchAgents — обновите экран")
        }
        targets.append(["label": label, "pid": pid.map { Int($0) } as Any])
        let cmds = LaunchAgents.argv(verb, label: label, plist: plist, loaded: loaded)
        command = cmds.map { Exec.display(["launchctl"] + $0) }.joined(separator: " && ")

        var outs: [String] = []
        for args in cmds {
            // Стенд не гасит и не включает настоящие агенты; проверки с заглушкой launchctl идут как обычно.
            if Exec.launchctl == "/bin/launchctl", Kit.standRefuses("launchctl \(args.joined(separator: " "))") {
                throw BackgroundActionError(message: "Стенд не трогает настоящие агенты")
            }
            let r = Exec.run([Exec.launchctl] + args, env: Exec.launchctlEnv(), timeout: Self.agentTimeout)
            if let e = r.launchError { throw BackgroundActionError(message: "Не удалось запустить launchctl: \(e)") }
            if r.timedOut {
                throw BackgroundActionError(message: "launchctl не уложился в \(Int(Self.agentTimeout)) с: \(Exec.display(["launchctl"] + args))")
            }
            outs.append((r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
            output = LaunchAgents.clip(outs.filter { !$0.isEmpty }.joined(separator: "\n"))
            if r.code != 0 {
                let err = LaunchAgents.clip(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                                                ?? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                // Выключенное в «Объектах входа» (Background Task Management) launchctl не вернёт.
                let btm = verb == .enable ? " Если агент выключен в «Системные настройки → Основные → Объекты входа», включи его там." : ""
                throw BackgroundActionError(message: "launchctl \(args[0]) завершился с кодом \(r.code)" + (err.isEmpty ? "." : ": \(err).") + btm)
            }
        }
        // bootout мог отработать без ошибки, а процесс остаться: верим только launchctl list.
        if verb != .enable, loaded, let left = waitGone(label) {
            throw BackgroundActionError(message: "Агент не остановился: launchctl list всё ещё показывает pid \(left)" + (output.isEmpty ? "" : ". \(output)"))
        }
        state.forget()
        let freed = verb == .enable ? 0 : Int(sub.reduce(0.0) { $0 + (procs[$1]?.mem ?? 0) }.rounded())
        let done: String
        switch verb {
        case .stop: done = "Остановлен до следующего входа"
        case .disable: done = sub.isEmpty ? "Убран из автозапуска" : "Остановлен и убран из автозапуска"
        case .enable: done = "Возвращён в автозапуск"
        }
        return StopResult(ok: true, message: "\(done): \(label)", freedMB: freed)
    }

    /// pid агента по свежему launchctl list, пока он не пропадёт, но не дольше `agentWait`.
    private func waitGone(_ label: String) -> Int32? {
        let deadline = Date().addingTimeInterval(Self.agentWait)
        while true {
            let pid: Int32? = (jobs() ?? [:])[label] ?? nil
            guard let pid else { return nil }
            if Date() >= deadline { return pid }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: Бот

    /// Сверка с командой из плана: её человек видел на подтверждении, а файл к этому времени могли поменять.
    /// В плане нет команды (в файле было не списком строк) — пустой список не совпадёт ни с какой настоящей:
    /// то, чего человек не видел, не запустится.
    private func bot(_ verb: BotVerb, _ spec: BotSpec, command: inout String, output: inout String) throws -> StopResult {
        var shown: [String] = []
        if case .argv(let argv)? = spec.commands[verb] { shown = argv }
        command = Exec.display(shown)
        return StopResult(ok: true, message: try BotRunner.run(verb, id: spec.id, expected: shown), freedMB: 0)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
