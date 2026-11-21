import Combine
import Foundation

// Раннер Студии: запуск, подключение к чужой, токен и код входа, остановка. Процесс, сеть и система подменены.
// Настоящая Студия, порт 47870 и её .cache не трогаются: всё во временной папке, порты случайные.
// Запуск: Tests/run-studio-runner-check.sh <временная папка>

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// MARK: Подмены

final class FakeProcess: StudioProcess, @unchecked Sendable {
    let pid: Int32
    var running = true
    var terminated = 0
    var killed = 0
    var exitOnTerminate = true
    var onExit: (@Sendable (Int32) -> Void)?
    var isRunning: Bool { running }
    init(pid: Int32) { self.pid = pid }
    func terminate() { terminated += 1; if exitOnTerminate { finish(15) } }
    func kill() { killed += 1; finish(9) }
    func finish(_ status: Int32) {
        guard running else { return }
        running = false
        onExit?(status)
    }
}

final class FakeSystem: StudioSystem {
    let uid: uid_t = geteuid()
    var owners: [Int32: uid_t] = [:]
    /// Процессы, которые живы, но порт не держат.
    var notListening: Set<Int32> = []
    func owner(ofPid pid: Int32) -> uid_t? { owners[pid] }
    func listens(pid: Int32, port: Int) -> Bool { owners[pid] != nil && !notListening.contains(pid) }
}

final class FakeLauncher: StudioLauncher {
    struct Launch { let executable: URL; let directory: URL; let environment: [String: String] }
    var launches: [Launch] = []
    var processes: [FakeProcess] = []
    var failWith: Error?
    var nextPid: Int32 = 71000
    let system: FakeSystem
    /// Что делает «сервер» при запуске: пишет свои файлы. nil — не пишет ничего.
    var onLaunch: ((FakeProcess, URL) -> Void)?
    /// Процесс выходит сразу с этим кодом.
    var exitImmediately: Int32?

    init(system: FakeSystem) { self.system = system }

    func launch(executable: URL, directory: URL, environment: [String: String],
                onExit: @escaping @Sendable (Int32) -> Void) throws -> StudioProcess {
        if let failWith { throw failWith }
        launches.append(Launch(executable: executable, directory: directory, environment: environment))
        let process = FakeProcess(pid: nextPid)
        nextPid += 1
        // Настоящая Студия при выходе стирает свои файлы; умерший процесс исчезает из системы.
        process.onExit = { [system] status in
            system.owners[process.pid] = nil
            let file = directory.appendingPathComponent(".cache/server.json")
            // Убитый SIGKILL ничего не успевает стереть.
            if status != 9, let data = try? Data(contentsOf: file), let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               info["pid"] as? Int == Int(process.pid) { removeServerFiles(directory) }
            onExit(status)
        }
        processes.append(process)
        system.owners[process.pid] = system.uid
        onLaunch?(process, directory)
        if let status = exitImmediately {
            system.owners[process.pid] = nil
            process.finish(status)
        }
        return process
    }
}

struct Refused: Error {}

final class FakeNetwork: StudioNetwork, @unchecked Sendable {
    struct Request: Equatable { let method: String; let port: Int; let path: String; let token: String }
    private let lock = NSLock()
    private var log: [Request] = []
    /// порт → токен сервера и что он отвечает на ping.
    private var servers: [Int: (token: String, app: String)] = [:]
    private var boots = 0
    var bootOverride: String?
    var bootBroken = false

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }
    func serve(port: Int, token: String, app: String = "utilitumus-studio") { lock.lock(); servers[port] = (token, app); lock.unlock() }
    func unserve(port: Int) { lock.lock(); servers[port] = nil; lock.unlock() }

    func get(port: Int, path: String, token: String) async throws -> Data { try answer("GET", port, path, token) }
    func post(port: Int, path: String, token: String) async throws -> Data { try answer("POST", port, path, token) }

    private func answer(_ method: String, _ port: Int, _ path: String, _ token: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        log.append(Request(method: method, port: port, path: path, token: token))
        guard let server = servers[port], server.token == token else { throw Refused() }
        switch (method, path) {
        case ("GET", "/api/ping"): return Data(#"{"app":"\#(server.app)"}"#.utf8)
        case ("POST", "/api/boot"):
            if bootBroken { return Data("мусор".utf8) }
            boots += 1
            return Data(#"{"boot":"\#(bootOverride ?? "bootcode\(String(format: "%08d", boots))xxxx")"}"#.utf8)
        default: throw Refused()
        }
    }
}

// MARK: Помощники

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func requireTemporaryRoot() {
    precondition(root.path.contains("studio-runner-check"), "стенд работает только во временной папке проверки")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    precondition(!root.path.hasPrefix(home + "/Library") && !root.path.hasPrefix(home + "/Documents") && !root.path.hasPrefix("/Applications"),
                 "временная папка не должна лежать в настоящем доме")
}

var counter = 0
let fm = FileManager.default

enum StudioFile { case ok, missing, symlink, groupWritable, notExecutable, notRegular }

/// Папка Студии с файлом studio нужного вида. Возвращает путь.
func makeFolder(mode: Int = 0o700, studio: StudioFile = .ok) -> URL {
    counter += 1
    let folder = root.appendingPathComponent("folder-\(counter)", isDirectory: true)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
    try! fm.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
    let file = folder.appendingPathComponent("studio")
    switch studio {
    case .ok: fm.createFile(atPath: file.path, contents: Data("#!/bin/bash\n".utf8), attributes: [.posixPermissions: 0o755])
    case .missing: break
    case .symlink:
        let target = root.appendingPathComponent("outside-\(counter)")
        fm.createFile(atPath: target.path, contents: Data("#!/bin/bash\n".utf8), attributes: [.posixPermissions: 0o755])
        try! fm.createSymbolicLink(at: file, withDestinationURL: target)
    case .groupWritable: fm.createFile(atPath: file.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o775])
    case .notExecutable: fm.createFile(atPath: file.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
    case .notRegular: try! fm.createDirectory(at: file, withIntermediateDirectories: true)
    }
    return folder
}

/// Файлы работающей Студии. Токен и порт, как их пишет studio.py: оба 0600.
func writeServer(_ folder: URL, port: Int, pid: Int32, token: String, tokenMode: Int = 0o600, fileMode: Int = 0o600) {
    let cache = folder.appendingPathComponent(".cache", isDirectory: true)
    try? fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    fm.createFile(atPath: cache.appendingPathComponent("token").path, contents: Data(token.utf8), attributes: [.posixPermissions: tokenMode])
    fm.createFile(atPath: cache.appendingPathComponent("server.json").path,
                  contents: Data(#"{"port": \#(port), "pid": \#(pid)}"#.utf8), attributes: [.posixPermissions: fileMode])
}

func removeServerFiles(_ folder: URL) {
    for name in ["token", "server.json"] { try? fm.removeItem(at: folder.appendingPathComponent(".cache/\(name)")) }
}

var nextPort = 40000 + Int.random(in: 0..<2000)
func randomPort() -> Int { nextPort += 7; return nextPort }

struct Rig {
    let runner: StudioRunner
    let launcher: FakeLauncher
    let network: FakeNetwork
    let system: FakeSystem
    let folder: URL
}

@MainActor func rig(folder: URL, port: Int, timeout: TimeInterval = 2) -> Rig {
    let system = FakeSystem()
    let launcher = FakeLauncher(system: system)
    let network = FakeNetwork()
    let config = StudioRunner.Config(port: port, startTimeout: timeout, pollInterval: 0.01, killAfter: 0.15)
    let runner = StudioRunner(folder: folder.path, config: config, launcher: launcher, network: network, system: system)
    return Rig(runner: runner, launcher: launcher, network: network, system: system, folder: folder)
}

/// Сервер, который поднимается при запуске: пишет файлы и начинает отвечать.
@MainActor func serveOnLaunch(_ rig: Rig, port: Int, token: String) {
    rig.launcher.onLaunch = { process, folder in
        writeServer(folder, port: port, pid: process.pid, token: token)
        rig.network.serve(port: port, token: token)
    }
}

@MainActor func settle(_ what: @autoclosure () -> Bool, seconds: Double = 3) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if what() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return what()
}

let token1 = "tok1_abcdefghijklmnopqrstuvwxyzABCDEF-0123456789"
let token2 = "tok2_abcdefghijklmnopqrstuvwxyzABCDEF-0123456789"

func json(_ state: StudioState) -> String { String(decoding: LinkWire.encoded(state), as: UTF8.self) }

// MARK: Проверки

@MainActor func scenarios() async {
    // 1. Папка не задана или негодная: ничего не запускается и в сеть не уходит.
    do {
        let r = rig(folder: root.appendingPathComponent("unused"), port: randomPort())
        r.runner.setFolder("")
        r.runner.start()
        check(r.runner.state.phase == .stopped && r.runner.state.message?.contains("не задана") == true && r.launcher.launches.isEmpty,
              "папка не задана: остановлена с подсказкой, запуска нет")
        r.runner.setFolder("relative/path")
        r.runner.start()
        check(r.runner.state.phase == .failed && r.launcher.launches.isEmpty, "относительный путь: ошибка, запуска нет")
        r.runner.setFolder(root.path + "/a/../b")
        r.runner.start()
        check(r.runner.state.phase == .failed && r.launcher.launches.isEmpty, "путь с «..»: ошибка")
        r.runner.setFolder(root.path + "/нет-такой-папки")
        r.runner.start()
        check(r.runner.state.phase == .failed && r.launcher.launches.isEmpty && r.network.requests.isEmpty, "папки нет: ошибка, сети нет")
    }

    // 2. Папка и файл studio: небезопасное не запускается.
    for (name, folder, text) in [
        ("папка открыта группе на запись", makeFolder(mode: 0o770), "ошибка"),
        ("папка открыта остальным на запись", makeFolder(mode: 0o707), "ошибка"),
        ("studio нет", makeFolder(studio: .missing), "ошибка"),
        ("studio — ссылка наружу", makeFolder(studio: .symlink), "ошибка"),
        ("studio открыт группе на запись", makeFolder(studio: .groupWritable), "ошибка"),
        ("studio без бита исполнения", makeFolder(studio: .notExecutable), "ошибка"),
        ("studio — папка", makeFolder(studio: .notRegular), "ошибка"),
    ] {
        let r = rig(folder: folder, port: randomPort())
        r.runner.start()
        let done = await settle(r.runner.state.phase != .starting)
        check(done && r.runner.state.phase == .failed && r.runner.state.message?.isEmpty == false && r.launcher.launches.isEmpty,
              "\(name): \(text) с текстом, запуска нет")
    }
    do {
        let link = root.appendingPathComponent("folder-link")
        let real = makeFolder()
        try? fm.createSymbolicLink(at: link, withDestinationURL: real)
        let r = rig(folder: link, port: randomPort())
        r.runner.start()
        check(r.runner.state.phase == .failed && r.launcher.launches.isEmpty, "папка — ссылка: ошибка")
    }

    // 3. Обычный запуск своего сервера.
    do {
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        serveOnLaunch(r, port: port, token: token1)
        r.runner.start()
        check(r.runner.state.phase == .starting, "старт: сразу «запускается»")
        let up = await settle(r.runner.state.phase == .running)
        let state = r.runner.state
        check(up && state.ownsServer && state.login == 1, "свой сервер: работает, запущен нами, код выдан")
        check(r.launcher.launches.count == 1 && r.launcher.launches[0].executable.path == folder.appendingPathComponent("studio").path
              && r.launcher.launches[0].directory.path == folder.path, "запущен именно <папка>/studio, из папки Студии")
        check(r.launcher.launches[0].environment["HOME"] != FileManager.default.homeDirectoryForCurrentUser.path,
              "стенд: настоящий дом в окружение сервера не попадает")
        check(Set(r.launcher.launches[0].environment.keys) == ["PATH", "HOME", "LANG", "STUDIO_OPEN", "STUDIO_PORT"]
              && r.launcher.launches[0].environment["STUDIO_OPEN"] == "none" && r.launcher.launches[0].environment["STUDIO_PORT"] == String(port),
              "окружение минимальное и явное: STUDIO_OPEN=none, свой порт")
        check(state.page?.hasPrefix("http://127.0.0.1:\(port)/#b=bootcode") == true, "адрес входа: 127.0.0.1, порт, код во фрагменте")
        check(!json(state).contains(token1) && !(state.page ?? "").contains(token1) && !(state.message ?? "").contains(token1),
              "токена нет ни в состоянии, ни в адресе")
        check(r.network.requests.allSatisfy { $0.port == port && $0.token == token1 && ($0.path == "/api/ping" || $0.path == "/api/boot") },
              "в сеть ушло только на свой порт и только ping и boot")
        check(StudioNavigation.loginURL(state.page)?.port == port, "адрес принимает политика навигации")

        // Новый код: другой адрес, номер вырос.
        let before = state.page
        r.runner.newLogin()
        let fresh = await settle(r.runner.state.login == 2)
        check(fresh && r.runner.state.page != before && r.runner.state.phase == .running, "«обновить»: новый код, номер вырос")

        // 4. Выключение: свой процесс просим выйти.
        r.runner.stop()
        let process = r.launcher.processes[0]
        check(process.terminated == 1 && r.runner.state.phase == .stopped && r.runner.state.page == nil && !r.runner.state.ownsServer,
              "стоп: SIGTERM своему процессу, страницы нет")
        try? await Task.sleep(for: .milliseconds(300))
        check(process.killed == 0, "вышел сам: SIGKILL не нужен")
        check(r.runner.state.phase == .stopped, "после выхода процесса остаётся «остановлена», не ошибка")
    }

    // 5. Процесс не уходит после SIGTERM: через killAfter SIGKILL.
    do {
        let port = randomPort()
        let r = rig(folder: makeFolder(), port: port)
        serveOnLaunch(r, port: port, token: token1)
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        r.launcher.processes[0].exitOnTerminate = false
        r.runner.stop()
        let killed = await settle(r.launcher.processes[0].killed == 1)
        check(killed, "не вышел после SIGTERM: добит SIGKILL")
        // Убитый SIGKILL сервер не стёр свои файлы сам: их стирает раннер.
        let cache = r.folder.appendingPathComponent(".cache")
        _ = await settle(!fm.fileExists(atPath: cache.appendingPathComponent("token").path))
        check(!fm.fileExists(atPath: cache.appendingPathComponent("token").path) && !fm.fileExists(atPath: cache.appendingPathComponent("server.json").path),
              "добитый SIGKILL сервер: его токен и server.json стёрты раннером")
    }

    // 6. Подключение к чужой Студии: пинг с токеном, выключение её не трогает.
    do {
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        let foreign: Int32 = 90001
        r.system.owners[foreign] = r.system.uid
        writeServer(folder, port: port, pid: foreign, token: token1)
        r.network.serve(port: port, token: token1)
        r.runner.start()
        let up = await settle(r.runner.state.phase == .running)
        check(up && !r.runner.state.ownsServer && r.launcher.launches.isEmpty, "чужая Студия: подключились, свой процесс не запускался")
        check(r.runner.state.page?.hasPrefix("http://127.0.0.1:\(port)/#b=") == true, "чужая Студия: страница с кодом")
        r.runner.stop()
        check(r.launcher.processes.isEmpty && r.runner.state.phase == .stopped, "выключение: чужой процесс не трогается")
        // Включили снова — снова подключились.
        r.runner.start()
        check(await settle(r.runner.state.phase == .running && !r.runner.state.ownsServer), "включили снова: подключились снова")
        r.runner.stop()
    }

    // 7. Файлы от умершего или чужого процесса: токен на порт не уходит.
    do {
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        writeServer(folder, port: port, pid: 90002, token: token1)   // pid нет в системе
        r.network.serve(port: port, token: token1)
        serveOnLaunch(r, port: port, token: token2)
        r.runner.start()
        check(await settle(r.runner.state.phase == .running), "файлы от умершего процесса: запущен свой")
        check(!r.network.requests.contains { $0.token == token1 }, "умерший pid: старый токен на порт не посылался")
        check(r.runner.state.ownsServer && r.launcher.launches.count == 1, "умерший pid: свой процесс запущен")
        r.runner.stop()
    }
    do {
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        r.system.owners[90003] = r.system.uid &+ 1   // чужой пользователь
        writeServer(folder, port: port, pid: 90003, token: token1)
        r.network.serve(port: port, token: token1)
        serveOnLaunch(r, port: port, token: token2)
        r.runner.start()
        check(await settle(r.runner.state.phase == .running), "pid чужого пользователя: запущен свой")
        check(!r.network.requests.contains { $0.token == token1 }, "pid чужого пользователя: токен на порт не посылался")
        r.runner.stop()
    }
    do {
        // Порт отвечает не Студия: подключения нет.
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        r.system.owners[90004] = r.system.uid
        writeServer(folder, port: port, pid: 90004, token: token1)
        r.network.serve(port: port, token: token1, app: "другое-приложение")
        serveOnLaunch(r, port: port, token: token2)
        r.runner.start()
        check(await settle(r.runner.state.phase == .running), "порт отвечает чужое приложение: запущен свой")
        check(!r.network.requests.contains { $0.path == "/api/boot" && $0.token == token1 }, "чужое приложение: код входа у него не просили")
        r.runner.stop()
    }

    do {
        // pid жив и наш, но порт держит не он: токен на порт не уходит.
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        r.system.owners[90011] = r.system.uid
        r.system.notListening = [90011]
        writeServer(folder, port: port, pid: 90011, token: token1)
        r.network.serve(port: port, token: token1)
        serveOnLaunch(r, port: port, token: token2)
        r.runner.start()
        check(await settle(r.runner.state.phase == .running), "pid не слушает порт: запущен свой")
        check(!r.network.requests.contains { $0.token == token1 }, "pid не слушает порт: токен на порт не посылался")
        r.runner.stop()
    }

    // 8. Файлы с неверными правами или формой не читаются.
    for (name, tokenMode, fileMode, token) in [
        ("токен 0644", 0o644, 0o600, token1), ("server.json 0644", 0o600, 0o644, token1),
        ("токен с пробелом внутри", 0o600, 0o600, "tok en_abcdefghijklmnopqrstuvwxyz"), ("токен короткий", 0o600, 0o600, "short"),
    ] {
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        r.system.owners[90005] = r.system.uid
        writeServer(folder, port: port, pid: 90005, token: token, tokenMode: tokenMode, fileMode: fileMode)
        r.network.serve(port: port, token: token)
        serveOnLaunch(r, port: port, token: token2)
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        check(!r.network.requests.contains { $0.token == token } && r.runner.state.ownsServer, "\(name): не читается, запущен свой")
        r.runner.stop()
    }
    do {
        // server.json — ссылка на другой файл: O_NOFOLLOW.
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        r.system.owners[90006] = r.system.uid
        writeServer(folder, port: port, pid: 90006, token: token1)
        let cache = folder.appendingPathComponent(".cache")
        let real = root.appendingPathComponent("real-server-\(counter).json")
        try? fm.moveItem(at: cache.appendingPathComponent("server.json"), to: real)
        try? fm.createSymbolicLink(at: cache.appendingPathComponent("server.json"), withDestinationURL: real)
        r.network.serve(port: port, token: token1)
        serveOnLaunch(r, port: port, token: token2)
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        check(!r.network.requests.contains { $0.token == token1 }, "server.json — ссылка: не читается")
        r.runner.stop()
    }
    do {
        // Порт из файла вне допустимых.
        let folder = makeFolder()
        let r = rig(folder: folder, port: randomPort())
        r.system.owners[90007] = r.system.uid
        writeServer(folder, port: 80, pid: 90007, token: token1)
        r.network.serve(port: 80, token: token1)
        serveOnLaunch(r, port: 41999, token: token2)
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        check(!r.network.requests.contains { $0.port == 80 }, "порт 80 из файла: на него ничего не уходит")
        r.runner.stop()
    }

    // 9. Сбои запуска.
    do {
        let r = rig(folder: makeFolder(), port: randomPort())
        r.launcher.exitImmediately = 3
        r.runner.start()
        _ = await settle(r.runner.state.phase == .failed)
        check(r.runner.state.phase == .failed && r.runner.state.message?.contains("3") == true && r.runner.state.page == nil,
              "процесс вышел сразу: ошибка с кодом")
    }
    do {
        let r = rig(folder: makeFolder(), port: randomPort())
        r.launcher.failWith = Refused()
        r.runner.start()
        _ = await settle(r.runner.state.phase == .failed)
        check(r.runner.state.phase == .failed && r.runner.state.message?.isEmpty == false, "не запустился: ошибка с текстом")
    }
    do {
        let r = rig(folder: makeFolder(), port: randomPort(), timeout: 0.3)
        r.runner.start()  // процесс запущен, но файлов нет и ответа нет
        _ = await settle(r.runner.state.phase == .failed, seconds: 3)
        check(r.runner.state.phase == .failed && r.launcher.processes.first?.terminated == 1, "не ответил за время: ошибка, процесс остановлен")
    }
    do {
        // Порт занят другой Студией, запущенной одновременно: наш процесс вышел, подключаемся к ней.
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        r.system.owners[90008] = r.system.uid
        r.launcher.onLaunch = { process, folder in
            writeServer(folder, port: port, pid: 90008, token: token1)
            r.network.serve(port: port, token: token1)
            process.finish(1)
        }
        r.runner.start()
        _ = await settle(r.runner.state.phase != .starting)
        check(r.runner.state.phase == .running && !r.runner.state.ownsServer, "порт занят другой Студией: подключились к ней")
        r.runner.stop()
    }
    do {
        // Свой процесс жив, а файл от другого pid: к нему не подключаемся.
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port, timeout: 0.3)
        r.system.owners[90009] = r.system.uid
        r.launcher.onLaunch = { _, folder in
            writeServer(folder, port: port, pid: 90009, token: token1)
            r.network.serve(port: port, token: token1)
        }
        r.runner.start()
        _ = await settle(r.runner.state.phase == .failed, seconds: 3)
        check(r.runner.state.phase == .failed && !r.network.requests.contains { $0.token == token1 } && r.launcher.processes.first?.terminated == 1,
              "файл от чужого pid при своём запущенном: токен не посылается, ждали зря — ошибка")
        r.runner.stop()
    }

    // 10. Код входа не годится: страницы нет.
    do {
        for (name, bad) in [("с пробелом", "boot code with space"), ("со слэшем", "bootcode/abcdefghijkl"), ("короткий", "abc"),
                            ("с ?", "bootcode?abcdefghijkl"), ("с #", "bootcode#abcdefghijkl"), ("с юникодом", "bootcodeабвгдежзийкл")] {
            let port = randomPort()
            let r = rig(folder: makeFolder(), port: port)
            serveOnLaunch(r, port: port, token: token1)
            r.network.bootOverride = bad
            r.runner.start()
            _ = await settle(r.runner.state.phase == .failed)
            check(r.runner.state.phase == .failed && r.runner.state.page == nil, "код входа \(name): страницы нет, ошибка")
            r.runner.stop()
        }
        let port = randomPort()
        let r = rig(folder: makeFolder(), port: port)
        serveOnLaunch(r, port: port, token: token1)
        r.network.bootBroken = true
        r.runner.start()
        _ = await settle(r.runner.state.phase == .failed)
        check(r.runner.state.phase == .failed && r.runner.state.page == nil, "boot вернул не JSON: страницы нет, ошибка")
        r.runner.stop()
    }

    // 11. Свой процесс упал при работе.
    do {
        let port = randomPort()
        let r = rig(folder: makeFolder(), port: port)
        serveOnLaunch(r, port: port, token: token1)
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        r.launcher.processes[0].finish(9)
        let failed = await settle(r.runner.state.phase == .failed)
        check(failed && r.runner.state.page == nil && r.runner.state.message?.contains("9") == true, "упал при работе: ошибка с кодом, страницы нет")
        // Запоздавший выход прошлого процесса не портит новый.
        r.runner.stop()
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        let second = r.launcher.processes.last!
        check(second !== r.launcher.processes[0] && r.runner.state.phase == .running, "после сбоя включили снова: новый процесс работает")
        r.launcher.processes[0].onExit?(1)
        try? await Task.sleep(for: .milliseconds(50))
        check(r.runner.state.phase == .running, "запоздалый выход прошлого процесса новый не ломает")
        r.runner.stop()
    }

    // 12. Выключили до конца запуска: ничего не остаётся, запоздалый ответ ничего не меняет.
    do {
        let port = randomPort()
        let r = rig(folder: makeFolder(), port: port)
        serveOnLaunch(r, port: port, token: token1)
        r.runner.start()
        r.runner.stop()
        try? await Task.sleep(for: .milliseconds(200))
        check(r.runner.state.phase == .stopped && r.runner.state.page == nil, "выключили во время запуска: остановлена, страницы нет")
        check(r.launcher.processes.allSatisfy { !$0.running }, "выключили во время запуска: процесса не осталось")
    }

    // 13. Быстро выключили и включили: новый запуск ждёт выхода прошлого и не подключается к умирающему.
    do {
        let port = randomPort()
        let r = rig(folder: makeFolder(), port: port)
        serveOnLaunch(r, port: port, token: token1)
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        r.launcher.processes[0].exitOnTerminate = false
        r.runner.stop()
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running && r.launcher.launches.count == 2, seconds: 4)
        check(r.launcher.processes[0].killed == 1 && r.launcher.launches.count == 2 && r.runner.state.ownsServer,
              "стоп и сразу старт: прошлый добит, потом запущен новый свой")
        r.runner.stop()
    }

    // 14. Сервер пропал при «обновить».
    do {
        let port = randomPort()
        let folder = makeFolder()
        let r = rig(folder: folder, port: port)
        let foreign: Int32 = 90010
        r.system.owners[foreign] = r.system.uid
        writeServer(folder, port: port, pid: foreign, token: token1)
        r.network.serve(port: port, token: token1)
        r.runner.start()
        _ = await settle(r.runner.state.phase == .running)
        // Чужую Студию перезапустили с другим токеном: берётся новый из файлов.
        writeServer(folder, port: port, pid: foreign, token: token2)
        r.network.serve(port: port, token: token2)
        r.runner.newLogin()
        check(await settle(r.runner.state.login == 2), "чужую перезапустили с новым токеном: «обновить» работает")
        check(r.network.requests.contains { $0.token == token2 && $0.path == "/api/boot" }, "новый токен прочитан заново")
        removeServerFiles(folder)
        r.network.unserve(port: port)
        r.runner.newLogin()
        check(await settle(r.runner.state.phase == .failed), "сервер пропал: ошибка, не вечное «работает»")
        r.runner.stop()
    }
}

// MARK: Настоящая система: кто слушает порт

@MainActor func systemScenarios() {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    check(bound == 0 && listen(fd, 1) == 0, "стенд: слушатель на 127.0.0.1, случайный порт")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    let port = Int(UInt16(bigEndian: address.sin_port))
    let system = StudioLiveSystem()
    check(system.owner(ofPid: getpid()) == geteuid(), "настоящая система: владелец своего процесса — мы")
    check(system.owner(ofPid: 2_000_000_000) == nil, "настоящая система: несуществующий процесс — nil")
    check(system.listens(pid: getpid(), port: port), "настоящая система: процесс слушает свой порт")
    check(!system.listens(pid: getpid(), port: port == 65535 ? 65534 : port + 1), "настоящая система: чужой порт — нет")
    check(!system.listens(pid: 1, port: port), "настоящая система: другой процесс этот порт не держит")
    check(!system.listens(pid: 2_000_000_000, port: port), "настоящая система: несуществующий процесс — нет")
    close(fd)
    check(!system.listens(pid: getpid(), port: port), "настоящая система: после закрытия не слушает")
}

// MARK: Контроллер: настройки и действия с экрана

@MainActor func controllerScenarios() async {
    let defaults = Kit.defaults
    defaults.removeObject(forKey: StudioKeys.folder)
    let port = randomPort()
    let folder = makeFolder()
    let r = rig(folder: folder, port: port)
    serveOnLaunch(r, port: port, token: token1)
    let controller = StudioController(runner: r.runner, defaults: defaults)

    func send(_ action: StudioAction) -> LinkReply<StudioState>? {
        try? JSONDecoder().decode(LinkReply<StudioState>.self, from: controller.handle(LinkWire.encoded(action)))
    }
    check(StudioController.storedFolder(defaults) == "", "по умолчанию папка пуста")
    check(send(.setFolder("не абсолютный"))?.error != nil && defaults.string(forKey: StudioKeys.folder) == nil, "кривой путь: отказ, настройка не записана")
    check(send(.setFolder("/a/../b"))?.error != nil, "путь с «..»: отказ")
    check(send(.newLogin)?.error != nil, "код входа у остановленной: отказ")

    // Выключенный модуль: папка сохраняется, сервер не стартует.
    check(send(.setFolder(folder.path))?.error == nil && defaults.string(forKey: StudioKeys.folder) == folder.path, "папка записана в настройки")
    check(r.launcher.launches.isEmpty && controller.state.phase == .stopped, "модуль выключен: сервер не запускается")

    // Включили: старт.
    controller.start()
    check(await settle(controller.state.phase == .running && controller.state.ownsServer), "включили: сервер работает")
    let page = controller.state.page
    check(send(.newLogin)?.error == nil, "включён: новый код принят")
    check(await settle(controller.state.page != page), "новый код выдан")

    // Смена папки: старый свой сервер остановлен, новый запущен в новой.
    let other = makeFolder()
    serveOnLaunch(r, port: port, token: token2)
    check(send(.setFolder(other.path))?.error == nil, "смена папки принята")
    check(await settle(controller.state.phase == .running && r.launcher.launches.count == 2), "смена папки: запущена из новой")
    check(r.launcher.processes[0].terminated == 1 && r.launcher.launches[1].directory.path == other.path, "смена папки: старый свой сервер остановлен")

    // Очистили папку.
    check(send(.setFolder(""))?.error == nil && defaults.string(forKey: StudioKeys.folder) == nil, "папку очистили: настройка снята")
    check(controller.state.phase == .stopped, "папки нет: остановлена")

    // Выключили.
    controller.stop()
    check(controller.state.phase == .stopped && !controller.running, "выключили")
    check(controller.statusLine(passiveReason: nil) == "остановлена" && !controller.statusLine(passiveReason: nil).contains("/"), "строка статуса без пути")
    defaults.removeObject(forKey: StudioKeys.folder)
}

@main
struct Check {
    @MainActor static func main() async {
        requireTemporaryRoot()
        systemScenarios()
        await scenarios()
        await controllerScenarios()
        print(failures == 0 ? "ВСЁ ЗЕЛЁНОЕ" : "ПРОВАЛОВ: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
