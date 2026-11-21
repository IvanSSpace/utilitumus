import Foundation

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

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= StudioRunner.maxReply else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
