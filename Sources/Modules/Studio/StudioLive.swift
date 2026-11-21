import AppKit

/// Настоящий запуск: `Process` без шелла, ввод и вывод в /dev/null. Вывод не читается, поэтому и не копится:
/// непрочитанная труба переполнилась бы и заморозила сервер.
struct StudioProcessLauncher: StudioLauncher {
    func launch(executable: URL, directory: URL, environment: [String: String],
                onExit: @escaping @Sendable (Int32) -> Void) throws -> StudioProcess {
        // Стенд не запускает Студию из настоящего дома или /Applications: он падает, а не трогает.
        Kit.assertStandPath(executable, "запуск Студии")
        Kit.assertStandPath(directory, "папка Студии")
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
        return LiveStudioProcess(process)
    }
}

private final class LiveStudioProcess: StudioProcess {
    private let process: Process
    init(_ process: Process) { self.process = process }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    func terminate() { if process.isRunning { process.terminate() } }
    /// Не вышел после SIGTERM. Проверка `isRunning` прямо перед сигналом: номер вышедшего процесса мог достаться другому.
    func kill() { if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) } }
}

struct StudioLiveSystem: StudioSystem {
    var uid: uid_t { geteuid() }

    func owner(ofPid pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }
}

extension StudioLiveSystem {
    /// Слушающий TCP-сокет процесса на 127.0.0.1 с этим портом (libproc): по номеру процесса из файла порта нельзя
    /// понять, что порт держит именно он.
    func listens(pid: Int32, port: Int) -> Bool {
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listSize) / MemoryLayout<proc_fdinfo>.stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let local = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: local.insi_lport)))
            let loopback = UInt32(bigEndian: local.insi_laddr.ina_46.i46a_addr4.s_addr) == 0x7F00_0001
            if localPort == port, loopback, local.insi_vflag & UInt8(INI_IPV4) != 0 { return true }
        }
        return false
    }
}

/// Только `http://127.0.0.1:<порт>`: без прокси, без кеша и куки, редиректы не выполняются (токен не уйдёт дальше).
final class StudioLiveNetwork: NSObject, StudioNetwork, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    /// Для API: те же запрещения, но время на запрос задаёт вызывающий (действие мастера может идти минуты).
    private var apiSession: URLSession!

    override init() {
        super.init()
        func configuration(resource: TimeInterval) -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = resource
            configuration.connectionProxyDictionary = [:]
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            // Ни сохранённых паролей, ни ответа на вызов авторизации: токен единственный способ войти.
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            return configuration
        }
        session = URLSession(configuration: configuration(resource: 5), delegate: self, delegateQueue: nil)
        apiSession = URLSession(configuration: configuration(resource: 300), delegate: self, delegateQueue: nil)
    }

    /// Сервер Студии молчит, пока работает с Orca, и отвечает разом: пауза до первого байта и есть время запроса.
    func request(method: String, port: Int, path: String, token: String, body: Data?, maxBytes: Int,
                 timeout: TimeInterval) async throws -> StudioReply {
        guard (1024...65535).contains(port), path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(token, forHTTPHeaderField: "X-Studio-Token")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body ?? Data("{}".utf8)
        }
        let (data, response) = try await Self.read(apiSession, request, maxBytes: maxBytes)
        return StudioReply(status: response.statusCode, data: data)
    }

    func get(port: Int, path: String, token: String) async throws -> Data { try await send("GET", port, path, token) }
    func post(port: Int, path: String, token: String) async throws -> Data { try await send("POST", port, path, token) }

    private func send(_ method: String, _ port: Int, _ path: String, _ token: String) async throws -> Data {
        guard (1024...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Studio-Token")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        let (data, response) = try await Self.read(session, request, maxBytes: StudioRunner.maxReply)
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Тело читается потоком и обрывается на пределе: сервер, который пишут мастера, не раздует память утилиты.
    private static func read(_ session: URLSession, _ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw URLError(.badServerResponse) }
        guard http.expectedContentLength <= Int64(maxBytes) else { bytes.task.cancel(); throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { bytes.task.cancel(); throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, http)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

/// Открыть адрес в браузере по умолчанию. Только в утилите: адрес несёт одноразовый код, а лаунчеру код не положен.
/// Стенд отказывает: из проверки настоящий браузер не запускается.
enum StudioOpen {
    @MainActor static func inBrowser(_ url: URL) {
        guard !Kit.standRefuses("открыть адрес в браузере") else { return }
        NSWorkspace.shared.open(url)
    }
}
