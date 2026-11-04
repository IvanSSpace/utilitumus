import Foundation

/// Память root- и чужих процессов: libproc их не отдаёт, она видна только в `top`
/// (там же — сжатое у всех). `top` стоит ~0,6 с CPU, поэтому кэш и обновление
/// в фоне раз в 5 минут; замер никогда его не ждёт. До первого ответа кэш пуст.
final class RootMemory: @unchecked Sendable {
    static let refreshEvery: TimeInterval = 300

    struct Cache: Sendable {
        var memory: [Int32: Double] = [:]
        var compressed: [Int32: Double] = [:]
        var updated: Date = .distantPast
    }

    private let lock = NSLock()
    private var cache = Cache()
    private var running = false

    func current() -> Cache {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// Запустить обновление в фоне, если кэш устарел и оно ещё не идёт.
    func refreshIfStale(maxAge: TimeInterval = refreshEvery) {
        lock.lock()
        let stale = Date().timeIntervalSince(cache.updated) > maxAge
        let start = stale && !running
        if start { running = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let text = Tool.run("/usr/bin/top", ["-l", "1", "-stats", "pid,mem,cmprs"], timeout: 30)
            lock.lock()
            if let text {
                let parsed = Self.parse(text)
                cache = Cache(memory: parsed.memory, compressed: parsed.compressed, updated: Date())
            } else {
                cache.updated = Date() // сбой: top на каждом замере не повторяем
            }
            running = false
            lock.unlock()
        }
    }

    /// Вывод `top -stats pid,mem,cmprs`: строки «PID MEM CMPRS», размеры вида «45M+», «2048K-», «1G».
    static func parse(_ text: String) -> (memory: [Int32: Double], compressed: [Int32: Double]) {
        var mem: [Int32: Double] = [:], cmprs: [Int32: Double] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts.count <= 3, let pid = Int32(parts[0]), let m = size(parts[1]) else { continue }
            mem[pid] = m
            if parts.count == 3, let c = size(parts[2]) { cmprs[pid] = c }
        }
        return (mem, cmprs)
    }

    private static func size(_ token: Substring) -> Double? {
        var t = token
        while let last = t.last, last == "+" || last == "-" { t = t.dropLast() }
        guard let unit = t.last, let v = Double(t.dropLast()) else { return nil }
        switch unit {
        case "B": return v / 1_048_576
        case "K": return v / 1024
        case "M": return v
        case "G": return v * 1024
        case "T": return v * 1024 * 1024
        default: return nil
        }
    }
}
