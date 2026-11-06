import Darwin
import Foundation

struct TmuxInfo: Sendable, Codable, Equatable {
    struct Session: Sendable, Codable, Equatable, Identifiable {
        var name: String
        var windows: Int = 0
        var attached: Bool
        var id: String { name }

        /// `windows` экран не показывает.
        private enum CodingKeys: String, CodingKey { case name, attached }
    }

    var running = false
    var sessions: [Session] = []
}

struct DockerInfo: Sendable, Codable, Equatable {
    struct Container: Sendable, Codable, Equatable, Identifiable {
        var id: String = ""
        var name: String
        var image: String = ""
        var state: String
        var status: String

        /// `id` и `image` экран не показывает.
        private enum CodingKeys: String, CodingKey { case name, state, status }
    }

    var running = false
    var containers: [Container] = []
}

/// tmux и Docker в фоне: опрос раз в несколько секунд, замер его не ждёт. Запускаем их, только если есть
/// сокет — иначе даже не трогаем бинарник (как sessions.py).
final class MuxProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var tmux = TmuxInfo()
    private var docker = DockerInfo()
    private var loadedAt = Date.distantPast
    private var busy = false

    func current() -> (tmux: TmuxInfo, docker: DockerInfo) {
        lock.lock()
        defer { lock.unlock() }
        return (tmux, docker)
    }

    func refreshIfStale(maxAge: TimeInterval = 10) {
        lock.lock()
        let start = !busy && Date().timeIntervalSince(loadedAt) >= maxAge
        if start { busy = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let t = Self.readTmux(), d = Self.readDocker()
            lock.lock()
            tmux = t
            docker = d
            loadedAt = Date()
            busy = false
            lock.unlock()
        }
    }

    // MARK: tmux

    private static var tmuxSocket: String { "/private/tmp/tmux-\(getuid())/default" }

    private static var tmuxBinary: String? {
        // Под launchd PATH минимальный — ищем по известным местам.
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `/private/tmp` общий: другая учётная запись может заранее создать там такой каталог и сокет со своим сервером.
    /// Поэтому оба должны быть настоящими (не ссылками) и своими.
    static func isOwnSocket(_ path: String, uid: uid_t = getuid()) -> Bool {
        func owned(_ item: String, _ type: mode_t) -> Bool {
            var info = stat()
            return lstat(item, &info) == 0 && info.st_uid == uid && info.st_mode & S_IFMT == type
        }
        return owned((path as NSString).deletingLastPathComponent, S_IFDIR) && owned(path, S_IFSOCK)
    }

    /// `-u`: без переменных окружения tmux считает вывод не UTF-8 и заменяет русские имена сессий на «_».
    static func tmuxArguments(socket: String) -> [String] {
        ["-u", "-S", socket, "list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_attached}"]
    }

    static func readTmux() -> TmuxInfo {
        // Окружение пустое: клиент tmux передаёт своё серверу.
        guard isOwnSocket(tmuxSocket), let bin = tmuxBinary,
              let text = Tool.run(bin, tmuxArguments(socket: tmuxSocket), timeout: 3, environment: []),
              !text.isEmpty else { return TmuxInfo() }
        // Сокет есть, а сервера нет: list-sessions молчит — это «не запущен», а не «пусто».
        return TmuxInfo(running: true, sessions: parseTmux(text))
    }

    static func parseTmux(_ text: String) -> [TmuxInfo.Session] {
        text.split(separator: "\n").map { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return TmuxInfo.Session(name: f.first ?? "", windows: f.count > 1 ? Int(f[1]) ?? 0 : 0,
                                    attached: f.count > 2 && !f[2].isEmpty && f[2] != "0")
        }
    }

    // MARK: Docker

    private static var dockerSocket: String { NSHomeDirectory() + "/.docker/run/docker.sock" }

    /// Контейнеры — тот же список, что `docker ps`, но напрямую через Engine API по сокету: без запуска CLI
    /// и без зависимости от PATH.
    static func readDocker() -> DockerInfo {
        guard FileManager.default.fileExists(atPath: dockerSocket),
              let body = httpGet(socketPath: dockerSocket, url: "/containers/json", timeout: 2),
              let list = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else { return DockerInfo() }
        return DockerInfo(running: true, containers: list.map { c in
            let names = c["Names"] as? [String]
            return DockerInfo.Container(
                id: String(((c["Id"] as? String) ?? "").prefix(12)),
                name: String((names?.first ?? "?").drop { $0 == "/" }),
                image: (c["Image"] as? String) ?? "", state: (c["State"] as? String) ?? "", status: (c["Status"] as? String) ?? "")
        })
    }

    /// Минимальный GET по unix-сокету: HTTP/1.0, чтобы ответ шёл целиком без chunked. Только 200 с телом.
    static func httpGet(socketPath: String, url: String, timeout: Int) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let request = Array("GET \(url) HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        guard send(fd, request, request.count, 0) == request.count else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while data.count < 8 << 20 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8),
              head.hasPrefix("HTTP/1.") , head.split(separator: " ").dropFirst().first == "200" else { return nil }
        return data[split.upperBound...]
    }
}
