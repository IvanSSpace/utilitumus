import Darwin
import Foundation

// Действия над фоновым: агенты launchd (launchctl bootout / disable / enable / bootstrap) и боты из bots.toml.
// Защита та же, что у `StopExecutor`, и из actions.py: всё, что показано на подтверждении, перед командой
// проверяется заново по свежему скану; системные и Apple-задания, боты, сама панель и системный домен не трогаются.

// MARK: Запуск команд без shell

enum Exec {
    /// launchctl только по этому пути; проверки подставляют заглушку, чтобы не трогать настоящие задания.
    nonisolated(unsafe) static var launchctl = "/bin/launchctl"

    struct Result {
        var code: Int32
        var stdout: String
        var stderr: String
        var timedOut = false
        /// Не удалось даже запустить (нет файла, нет прав).
        var launchError: String?
    }

    /// Запуск argv без shell, с заданным окружением. `newSession` — отдельная сессия (setsid), как у ботов в lambscape:
    /// команда бота не должна делить группу процессов с панелью. Вывод и ожидание — через poll, без потоков.
    static func run(_ argv: [String], env: [String: String], cwd: String? = nil, timeout: TimeInterval,
                    newSession: Bool = false) -> Result {
        guard var path = argv.first else { return Result(code: -1, stdout: "", stderr: "", launchError: "пустая команда") }
        if !path.contains("/") {
            // Как execvpe с переданным окружением: ищем в его PATH, а не в PATH панели.
            let dirs = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
            guard let hit = dirs.map({ "\($0)/\(path)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return Result(code: -1, stdout: "", stderr: "", launchError: "No such file or directory")
            }
            path = hit
        }
        var out = [Int32](repeating: -1, count: 2), err = [Int32](repeating: -1, count: 2)
        guard pipe(&out) == 0, pipe(&err) == 0 else {
            return Result(code: -1, stdout: "", stderr: "", launchError: String(cString: strerror(errno)))
        }
        defer { for fd in out + err where fd >= 0 { close(fd) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        for fd in out + err { posix_spawn_file_actions_addclose(&actions, fd) }
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if newSession { posix_spawnattr_setflags(&attr, Int16(0x0400)) } // POSIX_SPAWN_SETSID

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgv + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, cArgv, cEnv)
        guard rc == 0 else { return Result(code: -1, stdout: "", stderr: "", launchError: String(cString: strerror(rc))) }
        close(out[1]); close(err[1])
        out[1] = -1; err[1] = -1

        var outData = Data(), errData = Data()
        var status: Int32 = 0
        var exited = false, timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt = Date.distantFuture
        var open = [out[0], err[0]]
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            if !exited, waitpid(pid, &status, WNOHANG) == pid { exited = true; exitedAt = Date().addingTimeInterval(1) }
            if !exited, Date() > deadline {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                exited = true; timedOut = true; exitedAt = Date().addingTimeInterval(0.2)
            }
            // После выхода дочитываем остаток, но не ждём вечно: демон мог унаследовать конец пайпа.
            if exited, open.isEmpty || Date() > exitedAt { break }
            var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if poll(&fds, nfds_t(fds.count), 50) > 0 {
                for f in fds where f.revents != 0 {
                    let n = read(f.fd, &buf, buf.count)
                    if n > 0 {
                        if f.fd == out[0], outData.count < 1 << 16 { outData.append(contentsOf: buf[0..<n]) }
                        else if f.fd == err[0], errData.count < 1 << 16 { errData.append(contentsOf: buf[0..<n]) }
                    } else {
                        open.removeAll { $0 == f.fd }
                    }
                }
            }
        }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(code: code, stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    }

    /// Минимальное окружение launchctl: только HOME и системный PATH.
    static func launchctlEnv() -> [String: String] {
        ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    /// Окружение команд ботов: без переменных панели, как у launchd-агента с ~/.local/bin.
    static func botEnv() -> [String: String] {
        let home = NSHomeDirectory()
        return ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"]
    }

    /// argv в одну строку для показа и журнала (кавычки как в shlex.join).
    static func display(_ argv: [String]) -> String { argv.map(LaunchAgents.shellQuote).joined(separator: " ") }
}

// MARK: Журнал действий

/// Журнал действий: по строке JSON на действие в `~/Library/Logs/Utilitumus/actions.log`
/// (что остановлено, отключено, включено и когда). Пишется и для отказов.
enum ActionLog {
    struct Entry: Identifiable, Sendable {
        var id = UUID()
        var time: Date
        var kind: String
        var label: String
        var ok: Bool
        var message: String
    }

    static var directory: URL {
        if let p = ProcessInfo.processInfo.environment["UTILITUMUS_LOGS"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utilitumus")
    }

    static var file: URL { directory.appendingPathComponent("actions.log") }

    private static let lock = NSLock()

    static func write(kind: String, label: String, targets: [[String: Any]], ok: Bool, message: String,
                      command: String? = nil, output: String? = nil, id: String = "") {
        var line: [String: Any] = ["ts": Int(Date().timeIntervalSince1970), "action_id": String(id.prefix(200)), "kind": kind,
                                   "label": label, "targets": targets, "result": ok ? "ok" : "error", "message": message]
        if let command { line["command"] = command }
        if let output, !output.isEmpty { line["output"] = output }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data + Data("\n".utf8))
    }

    /// Остановка процессов из «Памяти» и «Сессий»: тот же журнал.
    static func record(stop plan: StopPlan, result: StopResult) {
        write(kind: "stop-tree", label: plan.title,
              targets: plan.targets.map { ["pid": Int($0.pid), "name": $0.name] }, ok: result.ok, message: result.message,
              id: "stop:\(plan.id.uuidString)")
    }

    /// Последние записи, новые первыми. Читаем только хвост файла: он растёт без ограничений.
    static func recent(limit: Int = 8) -> [Entry] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > 65536 ? size - 65536 : 0
        try? h.seek(toOffset: from)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if from > 0, !lines.isEmpty { lines.removeFirst() } // первая строка могла обрезаться
        return lines.suffix(limit).reversed().compactMap { l in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                  let ts = obj["ts"] as? Double ?? (obj["ts"] as? Int).map(Double.init) else { return nil }
            return Entry(time: Date(timeIntervalSince1970: ts), kind: obj["kind"] as? String ?? "",
                         label: obj["label"] as? String ?? "", ok: (obj["result"] as? String) == "ok",
                         message: obj["message"] as? String ?? "")
        }
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
        if case .argv(let argv)? = b.spec.commands[verb] { cmd = Exec.display(argv) }
        return BackgroundPlan(
            action: .bot(verb, b.spec), title: "\(verb.title) \(b.name)",
            message: (cmd.isEmpty ? "Выполнит команду из bots.toml." : "Выполнит \(cmd).") + (b.spec.note.isEmpty ? "" : " \(b.spec.note)"),
            command: cmd, targets: [], totalMB: 0, confirmTitle: verb.title, destructive: verb == .stop)
    }
}

// MARK: Исполнитель

struct BackgroundActionError: Error {
    var message: String
}

/// Выполняет план по свежим данным: свежие launchctl list и скан процессов, все запреты заново, одно действие за раз.
/// Работает вне движка замеров: команды бывают долгими (до 30–60 с), а замеры на это время вставать не должны.
final class BackgroundExecutor: @unchecked Sendable {
    static let agentTimeout: TimeInterval = 30
    static let botTimeout: TimeInterval = 60
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
                            command: command.isEmpty ? nil : command, output: output, id: plan.id.uuidString)
            return result
        } catch let e as BackgroundActionError {
            ActionLog.write(kind: kind, label: label, targets: targets, ok: false, message: e.message,
                            command: command.isEmpty ? nil : command, output: output, id: plan.id.uuidString)
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
        let systemJob = item.domain != "gui" || state.plists(LaunchAgents.systemDirs)[label] != nil
        if let why = LaunchAgents.whyRefused(label: label, domain: systemJob ? "system" : "gui", botLabels: LaunchAgents.botLabels(bots)) {
            throw BackgroundActionError(message: "Не трогаю \(label): \(why)")
        }
        guard let jobs = jobs() else { throw BackgroundActionError(message: "launchctl не ответил — повтори позже") }
        let loaded = jobs.keys.contains(label)
        let pid: Int32? = jobs[label] ?? nil

        let procs = scanner.scan(rootMemory: [:], compressed: [:])
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

    private func bot(_ verb: BotVerb, _ spec: BotSpec, command: inout String, output: inout String) throws -> StopResult {
        guard let bot = BotRegistry.load().first(where: { $0.id == spec.id }), let cmd = bot.commands[verb] else {
            throw BackgroundActionError(message: "Действие устарело — обновите экран")
        }
        guard case .argv(let argv) = cmd else {
            throw BackgroundActionError(message: "В bots.toml команда \(verb.rawValue) бота \(bot.id) — не список строк")
        }
        command = Exec.display(argv)
        let r = Exec.run(argv, env: Exec.botEnv(), cwd: NSHomeDirectory(), timeout: Self.botTimeout, newSession: true)
        if let e = r.launchError { throw BackgroundActionError(message: "Не удалось запустить \(command): \(e)") }
        if r.timedOut { throw BackgroundActionError(message: "Команда не уложилась в \(Int(Self.botTimeout)) с: \(command)") }
        output = LaunchAgents.clip((r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        if r.code != 0 {
            let err = LaunchAgents.clip(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                                            ?? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            throw BackgroundActionError(message: "Команда завершилась с кодом \(r.code)" + (err.isEmpty ? "" : ": \(err)"))
        }
        return StopResult(ok: true, message: "\(verb.done): \(bot.name)", freedMB: 0)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
