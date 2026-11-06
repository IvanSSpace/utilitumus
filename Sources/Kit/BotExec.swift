import CryptoKit
import Darwin
import Foundation

// Запуск команд ботов и журнал действий: общее для «Нагрузки» и «Ботов».

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
    static func display(_ argv: [String]) -> String { argv.map(shellQuote).joined(separator: " ") }

    /// Как shlex.quote: без кавычек только безопасные символы.
    static func shellQuote(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !s.isEmpty, s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

// MARK: Журнал действий

/// Журнал действий: по строке JSON на действие в `~/Library/Logs/Utilitumus/actions.log`
/// (что остановлено, отключено, включено и когда). Пишется и для отказов. Права 0600.
enum ActionLog {
    struct Entry: Sendable, Codable, Equatable, Identifiable {
        var id = UUID()
        var time: Date
        var kind: String = ""
        var label: String = ""
        var ok: Bool
        var message: String

        /// `kind` и `label` экран не показывает.
        private enum CodingKeys: String, CodingKey { case id, time, ok, message }
    }

    /// Путь не переопределяется переменной окружения (раньше был UTILITUMUS_LOGS): иначе
    /// журнал можно перенаправить в произвольное место.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utilitumus")
    }

    static var file: URL { directory.appendingPathComponent("actions.log") }

    /// Куда пишет `write`. Стенд пишет не в настоящий ~/Library/Logs/Utilitumus, а во временную папку;
    /// `file` остаётся настоящим путём, чтобы проверки видели, что он не менялся.
    private static var target: URL {
        #if KIT_TEST_DEFAULTS
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("utilitumus-test-logs/actions.log")
        #else
        return file
        #endif
    }

    private static let lock = NSLock()

    /// Как у keyboard.log.
    static let maxFileBytes = 200_000

    /// В журнал — только что за действие, над кем и чем кончилось. Полный argv и вывод
    /// команд (stdout/stderr ботов) не пишем: там бывают токены и пути. Поэтому у ботов
    /// и текст результата общий — подробности остаются только в окне панели.
    static func write(kind: String, label: String, targets: [[String: Any]], ok: Bool, message: String,
                      id: String = "") {
        let message = kind == "bot" ? (ok ? "выполнено" : "ошибка") : message
        let line: [String: Any] = ["ts": Int(Date().timeIntervalSince1970), "action_id": String(id.prefix(200)), "kind": kind,
                                   "label": label, "targets": targets, "result": ok ? "ok" : "error", "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.lock()
        defer { lock.unlock() }
        let file = target
        Kit.assertStandPath(file, "журнал действий")
        PrivateLog.prepare(file: file)
        rotateIfNeeded(file)
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data + Data("\n".utf8))
    }

    /// Больше предела — оставляем вторую половину с ближайшей границы строки, как keyboard.log.
    static func rotateIfNeeded(_ url: URL, limit: Int = maxFileBytes) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(data.count / 2)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Последние записи, новые первыми. Читаем только хвост файла.
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

struct BackgroundActionError: Error {
    var message: String
}

// MARK: Запуск команды бота

/// Единственное место, где запускается команда бота. Из вызова приходят только id бота и кнопка: argv берётся
/// из bots.toml в этот момент, как у `actions.py`. Без shell, окружение — HOME и PATH.
enum BotRunner {
    static let timeout: TimeInterval = 60
    static let changedMessage = "Команда в bots.toml изменилась после вопроса, ничего не запущено. Нажми кнопку ещё раз и проверь команду."

    /// Отпечаток команды для быстрого действия: сам argv в действие не влезает, а связь и не должна его присылать.
    static func fingerprint(_ argv: [String]) -> String {
        SHA256.hash(data: Data(argv.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Текст результата для экрана; сбой — `BackgroundActionError`. `expected` — команда, которую человек подтвердил:
    /// файл успели поменять, значит подтверждал он другое.
    static func run(_ verb: BotVerb, id: String, file: URL = BotRegistry.url, expected: [String]? = nil) throws -> String {
        let loaded = BotRegistry.read(file)
        if case .unsafe(let why)? = loaded.problem { throw BackgroundActionError(message: "Не запускаю: \(why)") }
        guard let bot = loaded.bots.first(where: { $0.id == id }), let cmd = bot.commands[verb] else {
            throw BackgroundActionError(message: "Действие устарело — обновите экран")
        }
        guard case .argv(let argv) = cmd else {
            throw BackgroundActionError(message: "В bots.toml команда \(verb.rawValue) бота \(bot.id) — не список строк")
        }
        if let expected, expected != argv { throw BackgroundActionError(message: changedMessage) }
        let command = Exec.display(argv)
        // Стенд не запускает ничего из bots.toml: даже если файл подложили, настоящие боты ему не цель.
        if Kit.standRefuses("команда бота \(bot.id): \(verb.rawValue)") {
            throw BackgroundActionError(message: "Стенд не запускает команды ботов")
        }
        let r = Exec.run(argv, env: Exec.botEnv(), cwd: NSHomeDirectory(), timeout: timeout, newSession: true)
        if let e = r.launchError { throw BackgroundActionError(message: "Не удалось запустить \(command): \(e)") }
        if r.timedOut { throw BackgroundActionError(message: "Команда не уложилась в \(Int(timeout)) с: \(command)") }
        if r.code != 0 {
            let out = (r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
                ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = out.count <= 500 ? out : "…" + out.suffix(499)
            throw BackgroundActionError(message: "Команда завершилась с кодом \(r.code)" + (err.isEmpty ? "" : ": \(err)"))
        }
        return "\(verb.done): \(bot.name)"
    }
}
