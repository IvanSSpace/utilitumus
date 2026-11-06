import Foundation

/// `launchctl list` в фоне раз в минуту: метка → pid. Нужен, чтобы отличить сироту от процесса, которым
/// управляет launchd (kill агента с KeepAlive — это перезапуск, а не остановка). Замер его не ждёт.
/// Этап 2 (фоновые агенты) берёт отсюда же список заданий.
final class LaunchdJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [String: Int32?] = [:]
    private var loadedAt = Date.distantPast
    private var running = false

    /// Метка → pid (nil — загружен, но не запущен). Пусто, пока `launchctl` не ответил.
    func current() -> [String: Int32?] {
        lock.lock()
        defer { lock.unlock() }
        return jobs
    }

    func refreshIfStale(maxAge: TimeInterval = 60) {
        lock.lock()
        let start = !running && Date().timeIntervalSince(loadedAt) >= maxAge
        if start { running = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let text = Tool.run("/bin/launchctl", ["list"], timeout: 10)
            lock.lock()
            if let text { jobs = Self.parse(text) }
            loadedAt = Date()
            running = false
            lock.unlock()
        }
    }

    static func parse(_ text: String) -> [String: Int32?] { LaunchdList.parse(text) }
}

/// Какие модели ollama сейчас загружены: GET /api/ps на 127.0.0.1:11434, таймаут 1 с. Опрашивается в фоне
/// раз в минуту и только когда процесс ollama запущен; порт не слушается или ответ не тот — пусто.
final class OllamaProbe: @unchecked Sendable {
    struct Model: Sendable {
        var name: String
        var mb: Int
    }

    private let lock = NSLock()
    private var models: [Model] = []
    private var checkedAt = Date.distantPast
    private var running = false

    func current(processRunning: Bool) -> [Model] {
        lock.lock()
        let m = models
        let start = processRunning && !running && Date().timeIntervalSince(checkedAt) >= 60
        if start { running = true }
        lock.unlock()
        if start {
            Task.detached(priority: .utility) { [self] in
                let found = await Self.fetch()
                lock.withLock {
                    models = found
                    checkedAt = Date()
                    running = false
                }
            }
        }
        return processRunning ? m : []
    }

    private static func fetch() async -> [Model] {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: "http://127.0.0.1:11434/api/ps"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return [] }
        return list.map { m in
            Model(name: (m["name"] as? String) ?? (m["model"] as? String) ?? "?",
                  mb: Int(((m["size"] as? NSNumber)?.doubleValue ?? 0) / 1_048_576))
        }
    }
}
