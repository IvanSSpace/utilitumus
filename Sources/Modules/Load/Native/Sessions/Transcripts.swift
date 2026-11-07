import Darwin
import Foundation

/// Чтение хвостов транскриптов `~/.claude/projects/<проект>/<sessionId>.jsonl`. Файл может весить сотни MB,
/// поэтому читаем только конец (как sessions.py), а дописанное разбираем с прошлого конца. Данные никуда не
/// уходят: наружу выходят только две строки (запрос и шаг), и те — в экран.
final class TranscriptReader: @unchecked Sendable {
    /// Окна для «времени последней строки»: 64 KB с конца; если там одна огромная строка (вывод инструмента) — 4 MB.
    private static let tsWindows: [UInt64] = [1 << 16, 1 << 22]
    private static let activityTail: UInt64 = 3 << 20
    static let promptMax = 120, actionMax = 90, whatMax = 80
    /// Поля входа инструмента, по которым понятно, что он делает, — по порядку важности.
    private static let whatKeys = ["description", "file_path", "command", "pattern", "url", "query", "skill"]

    private struct Stamp: Equatable {
        var size: UInt64
        var mtimeNs: Int64
        var ino: UInt64
    }

    private struct ActivityEntry {
        var stamp: Stamp
        /// Конец разобранной части: недописанную последнюю строку разберём в следующий раз.
        var end: UInt64
        var out: SessionActivity
    }

    private let lock = NSLock()
    private var activities: [String: ActivityEntry] = [:]
    private var stamps: [String: (Stamp, TimeInterval)] = [:]

    // MARK: Путь

    /// Папка транскриптов: путь, где всё, кроме латинских букв и цифр, заменено на «-».
    static func slug(_ path: String) -> String {
        String(path.unicodeScalars.map { s in
            (s.value < 128 && (CharacterSet.alphanumerics.contains(s))) ? Character(s) : "-"
        })
    }

    /// Транскрипт сессии или nil, если sessionId странный (не пускаем «../» в путь).
    static func path(projectsDir: String, cwd: String, sessionID: String?) -> String? {
        guard let sid = sessionID, !cwd.isEmpty, isSafeID(sid) else { return nil }
        return "\(projectsDir)/\(slug(cwd))/\(sid).jsonl"
    }

    private static func fileStamp(_ path: String) -> Stamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return Stamp(size: UInt64(st.st_size), mtimeNs: ns, ino: UInt64(st.st_ino))
    }

    private static func read(_ path: String, from: UInt64, count: UInt64) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: from)
            return try h.read(upToCount: Int(count))
        } catch { return nil }
    }

    // MARK: Время последней строки

    private static func parseISO(_ v: Any?) -> TimeInterval? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// Время последней строки транскрипта с меткой времени. mtime файла не годится: служебные строки
    /// (last-prompt, permission-mode, …) дописываются без метки и без всякой активности.
    func lastTimestamp(path: String) -> TimeInterval {
        guard let stamp = Self.fileStamp(path) else { return 0 }
        lock.lock()
        let hit = stamps[path]
        lock.unlock()
        if let hit, hit.0 == stamp { return hit.1 }
        var found: TimeInterval = 0
        outer: for size in Self.tsWindows {
            let start = stamp.size > size ? stamp.size - size : 0
            guard let data = Self.read(path, from: start, count: stamp.size - start) else { break }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            // Первая строка окна обрезана, если окно не с начала файла.
            for raw in (start > 0 ? lines.dropFirst() : lines[...]).reversed() where raw.range(of: Data("\"timestamp\"".utf8)) != nil {
                if let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any], let ts = Self.parseISO(obj["timestamp"]) {
                    found = ts
                    break outer
                }
            }
            if start == 0 { break }
        }
        lock.lock()
        stamps[path] = (stamp, found)
        lock.unlock()
        return found
    }

    // MARK: Запрос и шаг

    private static func clip(_ text: String, _ n: Int) -> String {
        let scalars = text.unicodeScalars
        return scalars.count <= n ? text : String(String.UnicodeScalarView(scalars.prefix(n - 1))) + "…"
    }

    private static func squash(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Запрос человека: не ответ инструмента, не служебная строка, не обёртка команды («<command-name>…»).
    static func prompt(_ d: [String: Any]) -> String {
        if (d["isCompactSummary"] as? Bool) == true { return "" }
        guard let msg = d["message"] as? [String: Any] else { return "" }
        var text: String
        if let list = msg["content"] as? [Any] {
            let blocks = list.compactMap { $0 as? [String: Any] }
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return "" }
            text = blocks.filter { ($0["type"] as? String) == "text" }.map { ($0["text"] as? String) ?? "" }.joined(separator: " ")
        } else {
            text = (msg["content"] as? String) ?? ""
        }
        text = squash(text)
        return text.hasPrefix("<") || text.hasPrefix("[Request interrupted") ? "" : clip(text, promptMax)
    }

    /// Последний шаг ассистента: «Tool: описание|файл|команда» или «ответ: текст»; размышления — не шаг.
    static func step(_ blocks: [Any]) -> String {
        for case let b as [String: Any] in blocks.reversed() {
            let type = b["type"] as? String
            if type == "tool_use" {
                var name = (b["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
                if name.hasPrefix("mcp__"), let r = name.range(of: "__", options: .backwards) { name = String(name[r.upperBound...]) }
                let input = b["input"] as? [String: Any] ?? [:]
                guard let key = whatKeys.first(where: { (input[$0] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }),
                      let raw = input[key] as? String else { return clip(name, actionMax) }
                var what = squash(raw)
                if key == "file_path", what.unicodeScalars.count > whatMax {
                    // У пути важен конец — имя файла.
                    what = "…" + String(String.UnicodeScalarView(what.unicodeScalars.suffix(whatMax - 1)))
                } else {
                    what = clip(what, whatMax)
                }
                return clip("\(name): \(what)", actionMax)
            }
            if type == "text", case let text = squash((b["text"] as? String) ?? ""), !text.isEmpty {
                return clip("ответ: \(text)", actionMax)
            }
        }
        return ""
    }

    private static let kindPatterns = ["\"type\":\"user\"", "\"type\": \"user\"", "\"type\":\"assistant\"", "\"type\": \"assistant\""].map { Data($0.utf8) }
    private static let skipPatterns = ["\"isSidechain\":true", "\"isSidechain\": true", "\"type\":\"tool_result\"", "\"type\": \"tool_result\""].map { Data($0.utf8) }

    private static func has(_ line: Data, _ patterns: [Data]) -> Bool {
        patterns.contains { line.range(of: $0) != nil }
    }

    /// (запрос, ts) и (шаг, ts) — самые новые среди строк (сначала новые). До разбора JSON отсеиваем всё, кроме
    /// строк user/assistant, без субагентов и ответов инструментов (в них бывает по мегабайту).
    private static func scan(_ lines: [Data]) -> (prompt: (String, TimeInterval)?, action: (String, TimeInterval)?) {
        var prompt: (String, TimeInterval)?
        var action: (String, TimeInterval)?
        for raw in lines {
            if prompt != nil, action != nil { break }
            guard has(raw, kindPatterns), !has(raw, skipPatterns),
                  let d = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let msg = d["message"] as? [String: Any],
                  let ts = parseISO(d["timestamp"]),
                  (d["isSidechain"] as? Bool) != true, (d["isMeta"] as? Bool) != true else { continue }
            let type = d["type"] as? String
            if type == "user", prompt == nil {
                let text = Self.prompt(d)
                if !text.isEmpty { prompt = (text, ts) }
            } else if type == "assistant", action == nil, let blocks = msg["content"] as? [Any] {
                let text = step(blocks)
                if !text.isEmpty { action = (text, ts) }
            }
        }
        return (prompt, action)
    }

    /// Запрос и шаг с метками времени из хвоста (до 3 MB с конца). Кэш по (размер, mtime, inode): неизменный
    /// файл не читаем, а дописанный в конец разбираем только с прошлого конца.
    func activity(path: String) -> SessionActivity {
        guard let stamp = Self.fileStamp(path) else { return SessionActivity() }
        lock.lock()
        let hit = activities[path]
        lock.unlock()
        if let hit, hit.stamp == stamp { return hit.out }
        let grown = hit.map { $0.stamp.ino == stamp.ino && stamp.size >= $0.end && stamp.size - $0.end <= Self.activityTail } ?? false
        let start = grown ? hit!.end : (stamp.size > Self.activityTail ? stamp.size - Self.activityTail : 0)
        guard let data = Self.read(path, from: start, count: stamp.size - start) else { return SessionActivity() }
        // Недописанную последнюю строку разберём в следующий раз.
        let cut = (data.lastIndex(of: 10).map { data.distance(from: data.startIndex, to: $0) + 1 }) ?? 0
        var lines = data.prefix(cut).split(separator: 10, omittingEmptySubsequences: true).map { Data($0) }
        if start > 0, !grown, !lines.isEmpty { lines.removeFirst() } // первая строка окна обрезана
        let (prompt, action) = Self.scan(lines.reversed())
        var out = grown ? hit!.out : SessionActivity()
        if let prompt { out.lastPrompt = prompt.0; out.lastPromptTS = prompt.1 }
        if let action { out.lastAction = action.0; out.lastActionTS = action.1 }
        lock.lock()
        activities[path] = ActivityEntry(stamp: stamp, end: start + UInt64(cut), out: out)
        lock.unlock()
        return out
    }

    /// Кэш — только для живых сессий.
    func prune(keeping paths: Set<String>) {
        lock.lock()
        activities = activities.filter { paths.contains($0.key) }
        stamps = stamps.filter { paths.contains($0.key) }
        lock.unlock()
    }
}

extension TranscriptReader {
    static func isSafeID(_ sid: String) -> Bool { SessionTexts.isSafeID(sid) }
}
