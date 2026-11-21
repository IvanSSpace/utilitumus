import Combine
import Foundation

/// Процесс сервера Студии, который запустила утилита.
protocol StudioProcess: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// SIGTERM: сервер сам стирает свой токен и файл порта.
    func terminate()
    /// SIGKILL: только тому, кто не ушёл после `terminate`.
    func kill()
}

/// Запуск без шелла: путь, папка и окружение заданы явно. Вывод процесса не читается и нигде не копится.
protocol StudioLauncher {
    /// `onExit` зовётся один раз, с любого потока.
    func launch(executable: URL, directory: URL, environment: [String: String],
                onExit: @escaping @Sendable (Int32) -> Void) throws -> StudioProcess
}

/// Сеть только до 127.0.0.1. Ответ больше `StudioRunner.maxReply` отвергается, редиректы не выполняются.
protocol StudioNetwork: Sendable {
    func get(port: Int, path: String, token: String) async throws -> Data
    func post(port: Int, path: String, token: String) async throws -> Data
}

/// Что знает о процессах система. Подмена нужна проверкам: настоящие pid им не нужны.
protocol StudioSystem {
    /// Владелец живого процесса; nil — такого процесса нет.
    func owner(ofPid pid: Int32) -> uid_t?
    /// Слушает ли процесс TCP-порт на 127.0.0.1. Токен уходит на порт, только если им владеет тот самый процесс из server.json.
    func listens(pid: Int32, port: Int) -> Bool
    var uid: uid_t { get }
}

/// Файлы Студии читаются только так: обычный файл (не ссылка), свой, без доступа группе и остальным.
enum StudioFiles {
    enum Failure: Error, Equatable { case missing, unsafe, tooLarge }

    /// `O_NOFOLLOW`: ссылка вместо файла — отказ, а не чтение того, на что она указывает.
    static func readPrivate(_ url: URL, maxBytes: Int, uid: uid_t) throws -> Data {
        // O_NONBLOCK: именованная труба вместо файла не должна повесить главный поток на открытии.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ENOENT ? Failure.missing : Failure.unsafe }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid, info.st_mode & 0o077 == 0 else {
            throw Failure.unsafe
        }
        guard info.st_size <= maxBytes else { throw Failure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw Failure.unsafe }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.count > maxBytes { throw Failure.tooLarge }
        }
        return data
    }

    /// Папка Студии: настоящая папка (не ссылка) и своя, без записи группе и остальным.
    static func isSafeFolder(_ url: URL, uid: uid_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == uid && info.st_mode & 0o022 == 0
    }

    /// Запускаемый файл: обычный (не ссылка), свой, без записи группе и остальным, с битом исполнения владельца.
    static func isSafeExecutable(_ url: URL, uid: uid_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == uid
            && info.st_mode & 0o022 == 0 && info.st_mode & 0o100 != 0
    }
}

/// Сервер Студии: запустить свой или подключиться к чужому, держать одноразовый код входа, остановить только своё.
/// Работает на главном потоке; сеть и ожидание — в задачах, результат каждой проверяется по поколению: после `stop`
/// запоздавший ответ ничего не меняет.
@MainActor
final class StudioRunner: ObservableObject {
    struct Config {
        var port = 47870
        /// Сколько ждать, пока свой сервер начнёт отвечать.
        var startTimeout: TimeInterval = 15
        var pollInterval: TimeInterval = 0.25
        /// Сколько ждать выхода после SIGTERM, потом SIGKILL.
        var killAfter: TimeInterval = 3
    }

    /// Самый длинный ответ сервера, который утилита читает.
    nonisolated static let maxReply = 64 * 1024

    @Published private(set) var state: StudioState
    var config: Config

    private let launcher: StudioLauncher
    private let network: StudioNetwork
    private let system: StudioSystem
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var generation = 0
    private var task: Task<Void, Never>?
    private var process: StudioProcess?
    /// Метка именно этого запуска: запоздавший выход прошлого процесса не должен считаться выходом нынешнего.
    private var processFlag: ExitFlag?
    /// Остановленный нами, но ещё не вышедший: новый запуск ждёт его, иначе подключился бы к умирающему.
    private var lingering: StudioProcess?
    private var folderURL: URL?

    init(folder: String, config: Config = Config(), launcher: StudioLauncher, network: StudioNetwork, system: StudioSystem,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.config = config
        self.launcher = launcher
        self.network = network
        self.system = system
        self.sleep = sleep
        state = StudioState(folder: folder, phase: .stopped, message: nil, ownsServer: false, page: nil, login: 0)
    }

    // MARK: Состояние

    private func set(_ phase: StudioPhase, message: String? = nil, owns: Bool = false, page: String? = nil) {
        var next = state
        next.phase = phase
        next.message = message
        next.ownsServer = owns
        next.page = page
        if next != state { state = next }
    }

    func setFolder(_ folder: String) {
        if state.folder != folder { state.folder = folder }
    }

    var isActive: Bool { state.phase == .starting || state.phase == .running }

    // MARK: Запуск

    /// Включили: запустить сервер или подключиться к уже работающему. Повторный вызов безвреден.
    func start() {
        guard !isActive else { return }
        generation += 1
        let mine = generation
        task?.cancel()
        let folder = state.folder
        guard !folder.isEmpty else { return set(.stopped, message: "Папка Студии не задана") }
        guard StudioPath.validated(folder) == folder else { return set(.failed, message: "Путь к папке Студии задан неверно") }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard StudioFiles.isSafeFolder(url, uid: system.uid) else {
            return set(.failed, message: "Папка Студии не найдена или небезопасна: нужна своя папка без записи для группы и остальных")
        }
        folderURL = url
        set(.starting)
        task = Task { await self.bringUp(url, mine) }
    }

    private func bringUp(_ folder: URL, _ mine: Int) async {
        // Прошлый сервер, остановленный этой утилитой, мог ещё не выйти.
        if let old = lingering {
            let deadline = Date().addingTimeInterval(config.killAfter + 1)
            while old.isRunning, Date() < deadline, mine == generation { await sleep(config.pollInterval) }
            guard mine == generation else { return }
            lingering = nil
        }
        // Уже запущена кем-то: подключаемся, остановить её нам не дано.
        if let found = await probe(folder, expectedPid: nil) {
            return await finishStart(found, owns: false, mine)
        }
        guard mine == generation else { return }
        let executable = folder.appendingPathComponent("studio")
        guard StudioFiles.isSafeExecutable(executable, uid: system.uid) else {
            return fail("Файл studio в папке не найден или небезопасен: нужен обычный исполняемый файл без записи для группы и остальных", mine)
        }
        let exited = ExitFlag()
        let started: StudioProcess
        do {
            started = try launcher.launch(executable: executable, directory: folder, environment: environment()) { status in
                exited.set(status)
                Task { @MainActor in self.processExited(exited, status: status) }
            }
        } catch {
            return fail("Не удалось запустить Студию", mine)
        }
        process = started
        processFlag = exited
        let deadline = Date().addingTimeInterval(config.startTimeout)
        while mine == generation {
            if let found = await probe(folder, expectedPid: started.pid) {
                return await finishStart(found, owns: true, mine)
            }
            guard mine == generation else { return }
            if let status = exited.value {
                process = nil
                processFlag = nil
                // Порт мог занять другая Студия, запущенная одновременно: подключаемся к ней.
                if let found = await probe(folder, expectedPid: nil) { return await finishStart(found, owns: false, mine) }
                return fail("Студия остановилась сразу после запуска (код \(status))", mine)
            }
            if Date() >= deadline {
                terminateOwn()
                return fail("Студия не ответила за \(Int(config.startTimeout)) с: файл studio должен запускать сервер через exec", mine)
            }
            await sleep(config.pollInterval)
        }
    }

    private func finishStart(_ server: Server, owns: Bool, _ mine: Int) async {
        guard mine == generation else { return }
        guard let page = await mint(server) else {
            if owns { terminateOwn() }
            return fail("Студия работает, но не выдала код входа", mine)
        }
        guard mine == generation else { return }
        state.login += 1
        set(.running, owns: owns, page: page)
    }

    private func fail(_ message: String, _ mine: Int) {
        guard mine == generation else { return }
        set(.failed, message: message)
    }

    private static var serverHome: String {
        #if KIT_TEST_DEFAULTS
        NSTemporaryDirectory()
        #else
        NSHomeDirectory()
        #endif
    }

    /// Окружение сервера целиком: ничего из окружения утилиты, кроме явно названного.
    private func environment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            // Стенд живёт с подставным домом: настоящий не должен попасть в окружение сервера.
            "HOME": Self.serverHome,
            "LANG": "en_US.UTF-8",
            "STUDIO_OPEN": "none",
            "STUDIO_PORT": String(config.port),
        ]
    }

    // MARK: Подключение к серверу

    private struct Server {
        let port: Int
        let token: String
    }

    /// Сервер, который отвечает как Студия. Порт и токен берутся из её файлов в `<папка>/.cache`, и токен уходит на порт,
    /// только если pid из файла жив и принадлежит нам: иначе файл от прошлого запуска, а порт мог занять чужой процесс.
    /// `expectedPid` — свой сервер: файл должен быть именно от него.
    private func probe(_ folder: URL, expectedPid: Int32?) async -> Server? {
        let cache = folder.appendingPathComponent(".cache", isDirectory: true)
        guard StudioFiles.isSafeFolder(cache, uid: system.uid),
              let info = try? StudioFiles.readPrivate(cache.appendingPathComponent("server.json"), maxBytes: 4096, uid: system.uid),
              let json = (try? JSONSerialization.jsonObject(with: info)) as? [String: Any],
              let port = json["port"] as? Int, (1024...65535).contains(port),
              let pid = (json["pid"] as? Int).flatMap({ Int32(exactly: $0) }), pid > 0,
              expectedPid == nil || pid == expectedPid,
              system.owner(ofPid: pid) == system.uid,
              system.listens(pid: pid, port: port),
              let token = readToken(cache) else { return nil }
        guard let reply = try? await network.get(port: port, path: "/api/ping", token: token),
              reply.count <= Self.maxReply,
              let answer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              answer["app"] as? String == "utilitumus-studio" else { return nil }
        return Server(port: port, token: token)
    }

    private func readToken(_ cache: URL) -> String? {
        guard let data = try? StudioFiles.readPrivate(cache.appendingPathComponent("token"), maxBytes: 512, uid: system.uid),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isSecret(token) ? token : nil
    }

    /// Токен и код входа Студии — `secrets.token_urlsafe`: буквы, цифры, `-` и `_`. Остальное в адрес не попадёт.
    nonisolated static func isSecret(_ text: String) -> Bool {
        (16...128).contains(text.utf8.count)
            && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    /// Одноразовый код входа: `POST /api/boot` с токеном. Токен дальше этой функции не уходит.
    private func mint(_ server: Server) async -> String? {
        guard let reply = try? await network.post(port: server.port, path: "/api/boot", token: server.token),
              reply.count <= Self.maxReply,
              let answer = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let code = answer["boot"] as? String, Self.isSecret(code) else { return nil }
        return "http://127.0.0.1:\(server.port)/#b=\(code)"
    }

    /// Новый код входа для «обновить» и «открыть в браузере». Сервер пропал — состояние это и говорит.
    func newLogin() {
        guard state.phase == .running, let folder = folderURL else { return }
        let mine = generation
        let owns = state.ownsServer
        Task {
            // Файлы читаются заново: чужой сервер могли перезапустить, и токен у него уже другой.
            if let server = await probe(folder, expectedPid: owns ? process?.pid : nil), let page = await mint(server) {
                guard mine == generation, state.phase == .running else { return }
                state.login += 1
                set(.running, owns: owns, page: page)
            } else {
                guard mine == generation, state.phase == .running else { return }
                if owns { terminateOwn() }
                set(.failed, message: "Студия перестала отвечать")
            }
        }
    }

    // MARK: Остановка

    /// Выключили. Свой сервер просим выйти (SIGTERM, через `killAfter` SIGKILL), к чужому только отключаемся.
    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        terminateOwn()
        folderURL = nil
        set(.stopped, message: state.folder.isEmpty ? "Папка Студии не задана" : nil)
    }

    private func terminateOwn() {
        guard let own = process else { return }
        process = nil
        processFlag = nil
        guard own.isRunning else { return }
        lingering = own
        own.terminate()
        let wait = config.killAfter
        let folder = folderURL
        Task {
            await self.sleep(wait)
            if own.isRunning {
                own.kill()
                if let folder { Self.removeStaleFiles(of: own.pid, in: folder) }
            }
        }
    }

    /// Выключение на выходе процесса (SIGTERM от launchd): дождаться, пока свой сервер уйдёт, иначе добить. Блокирует главный
    /// поток не дольше `killAfter`, потому что за этим сразу идёт выход.
    func stopAndWait() {
        let own = process
        let folder = folderURL
        stop()
        guard let own else { return }
        let deadline = Date().addingTimeInterval(config.killAfter)
        while own.isRunning, Date() < deadline { usleep(50_000) }
        if own.isRunning {
            own.kill()
            if let folder { Self.removeStaleFiles(of: own.pid, in: folder) }
        }
    }

    /// Убитый SIGKILL сервер не стёр свой токен и файл порта. Стираем их, только если они его: `server.json` с его pid.
    private static func removeStaleFiles(of pid: Int32, in folder: URL) {
        let cache = folder.appendingPathComponent(".cache", isDirectory: true)
        guard let data = try? Data(contentsOf: cache.appendingPathComponent("server.json")),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              info["pid"] as? Int == Int(pid) else { return }
        // Стенд стирает только во временных папках: настоящий дом и /Applications роняют его.
        Kit.assertStandPath(cache, "файлы убитой Студии")
        for name in ["token", "server.json"] { try? FileManager.default.removeItem(at: cache.appendingPathComponent(name)) }
    }

    /// Свой сервер вышел. Если его не просили выйти — это сбой.
    private func processExited(_ flag: ExitFlag, status: Int32) {
        guard flag === processFlag, state.phase == .running, state.ownsServer else { return }
        process = nil
        processFlag = nil
        generation += 1
        set(.failed, message: "Студия остановилась (код \(status))")
    }
}

/// Код выхода свежего процесса: читает цикл ожидания запуска, пока `processExited` ещё не дошёл до главного потока.
private final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    var value: Int32? { lock.lock(); defer { lock.unlock() }; return status }
    func set(_ code: Int32) { lock.lock(); status = code; lock.unlock() }
}
