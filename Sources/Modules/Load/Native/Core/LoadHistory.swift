import Foundation

/// Один замер раз в минуту: итоги памяти и память топ-групп. Ключи групп — id («project:x», «app:Chrome»),
/// остальное сложено в «other».
struct HistorySample: Codable, Sendable {
    var ts: Int
    var used: Int
    var swap: Int
    var compressed: Int
    var wired: Int
    /// 1 — норма, 2 — высокое, 4 — критическое.
    var pressure: Int
    /// Счётчик записи в своп с загрузки, MB.
    var swapouts: Int?
    var groups: [String: Int]
}

/// Окно истории для графика: корзины по 5 минут, ряды — топ-5 групп и «прочее».
struct HistoryWindow: Sendable, Codable, Equatable {
    struct Series: Sendable, Codable, Identifiable, Equatable {
        var key: String
        var name: String
        var id: String { key }
    }

    struct Point: Sendable, Codable, Identifiable, Equatable {
        var ts: Int
        var usedMB: Int
        var swapMB: Int
        var pressure: Int
        /// По рядам `series`.
        var values: [Int]
        var id: Int { ts }
    }

    var stepSeconds: Int
    var from: Int
    var to: Int
    var series: [Series]
    var points: [Point]
    var firstSample: Int?
}

/// История за сутки в памяти и в файле. Не потокобезопасна: живёт внутри `LoadEngine`.
final class LoadHistory {
    static let keepSeconds = 24 * 3600
    static let interval: TimeInterval = 60
    static let topGroups = 12
    static let seriesCount = 5
    static let step = 300

    private(set) var samples: [HistorySample] = []
    private let url: URL?

    init(url: URL? = LoadHistory.defaultURL) {
        self.url = url
        load()
    }

    /// Настоящий файл. Проверки сверяют, что его не трогали.
    static var realURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Utilitumus/load-history.json")
    }

    /// Сборка со швом пишет в свою временную папку: стенд с настоящей утилитой не должен трогать настоящую историю.
    static var defaultURL: URL? {
        #if KIT_TEST_DEFAULTS
        return FileManager.default.temporaryDirectory.appendingPathComponent("utilitumus-test-load/load-history.json")
        #else
        return realURL
        #endif
    }

    /// Единственный писатель файла: замок flock на соседнем файле держит тот, кто пишет. Центр и утилита
    /// не работают вместе, но при передаче модуля они могут пересечься, и тогда второй только читает.
    private var writerFD: Int32 = -1

    private func claimWriter() -> Bool {
        if writerFD >= 0 { return true }
        guard let url else { return true }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        writerFD = fd
        // Пока писал другой, файл ушёл вперёд.
        load()
        return true
    }

    /// Модуль остановлен: замок нужен тому, кто стартует следом.
    func releaseWriter() {
        guard writerFD >= 0 else { return }
        flock(writerFD, LOCK_UN)
        close(writerFD)
        writerFD = -1
    }

    deinit { releaseWriter() }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) else { return }
        samples = decoded.sorted { $0.ts < $1.ts }
        prune(now: Int(Date().timeIntervalSince1970))
    }

    private func prune(now: Int) {
        let cutoff = now - Self.keepSeconds
        if let first = samples.firstIndex(where: { $0.ts >= cutoff }) {
            if first > 0 { samples.removeFirst(first) }
        } else {
            samples.removeAll()
        }
    }

    func record(memory: MemoryTotals, groups: [ProcessGroup], swapoutsMB: Int?, now: Int = Int(Date().timeIntervalSince1970)) {
        // Читатель пишущего только догоняет, своих замеров в файл не кладёт.
        guard claimWriter() else {
            load()
            return
        }
        let top = groups.filter { $0.id != "other" }.sorted { $0.memMB > $1.memMB }.prefix(Self.topGroups)
        var byGroup = Dictionary(uniqueKeysWithValues: top.map { ($0.id, $0.memMB) })
        // Всё остальное, включая группу «Прочее» (её id тоже other).
        byGroup["other"] = groups.reduce(0) { $0 + $1.memMB } - top.reduce(0) { $0 + $1.memMB }
        let sample = HistorySample(ts: now, used: memory.usedMB, swap: memory.swapUsedMB, compressed: memory.compressedMB,
                                   wired: memory.wiredMB, pressure: memory.pressure.rawValue, swapouts: swapoutsMB, groups: byGroup)
        if samples.last?.ts == now { samples.removeLast() }
        samples.append(sample)
        prune(now: now)
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(samples) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// На сколько MB вырос своп за последние `minutes`: последний замер минус первый в окне; nil — меньше двух замеров.
    func swapGrowth(minutes: Int = 30, now: Int = Int(Date().timeIntervalSince1970)) -> Int? {
        let rows = samples.filter { $0.ts >= now - minutes * 60 }
        guard rows.count >= 2, let first = rows.first, let last = rows.last else { return nil }
        return last.swap - first.swap
    }

    /// (MB записи в своп за сутки, часов истории за этим числом) по счётчику из замеров за последние 24 ч.
    /// Истории меньше суток — пересчёт на сутки (оценка, а не замер), но не меньше 2 ч (иначе nil).
    /// Счётчик с загрузки: после перезагрузки он сбрасывается — такие шаги назад не считаем.
    func swapWrittenLastDay(now: Int = Int(Date().timeIntervalSince1970)) -> (mb: Double, spanHours: Double)? {
        let rows = samples.filter { $0.ts >= now - 86400 }.compactMap { s in s.swapouts.map { (s.ts, $0) } }
        guard let first = rows.first, let last = rows.last else { return nil }
        let span = last.0 - first.0
        guard span >= 2 * 3600 else { return nil }
        var written = 0
        for (a, b) in zip(rows, rows.dropFirst()) { written += max(0, b.1 - a.1) }
        return (Double(written) * 86400 / Double(span), Double(span) / 3600)
    }

    /// Окно за `hours` корзинами по 5 минут. Начало окна — по границе корзины; пустые корзины пропускаем.
    func window(hours: Int = 24, now: Int = Int(Date().timeIntervalSince1970)) -> HistoryWindow {
        let step = Self.step
        let lo = (now - hours * 3600 + step - 1) / step * step
        struct Bucket {
            var n = 0
            var used = 0, swap = 0, pressure = 1
            var groups: [String: Int] = [:]
        }
        var buckets: [Int: Bucket] = [:]
        for s in samples where s.ts >= lo && s.ts <= now {
            let b = s.ts / step * step
            var cur = buckets[b] ?? Bucket()
            cur.n += 1
            cur.used += s.used
            cur.swap += s.swap
            cur.pressure = max(cur.pressure, s.pressure)
            for (k, v) in s.groups { cur.groups[k, default: 0] += v }
            buckets[b] = cur
        }
        var sums: [String: Int] = [:]
        for b in buckets.values {
            for (k, v) in b.groups where k != "other" { sums[k, default: 0] += v }
        }
        let top = sums.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.seriesCount).map(\.key)
        let points = buckets.keys.sorted().map { ts -> HistoryWindow.Point in
            let b = buckets[ts]!
            let n = max(b.n, 1)
            func mean(_ v: Int) -> Int { Int((Double(v) / Double(n)).rounded()) }
            let rest = b.groups.filter { !top.contains($0.key) }.values.reduce(0, +)
            return HistoryWindow.Point(ts: ts, usedMB: mean(b.used), swapMB: mean(b.swap), pressure: b.pressure,
                                       values: top.map { mean(b.groups[$0] ?? 0) } + [mean(rest)])
        }
        return HistoryWindow(
            stepSeconds: step, from: lo, to: now,
            series: top.map { HistoryWindow.Series(key: $0, name: Attribution.groupName($0)) } + [.init(key: "rest", name: "прочее")],
            points: points, firstSample: samples.first?.ts)
    }
}
