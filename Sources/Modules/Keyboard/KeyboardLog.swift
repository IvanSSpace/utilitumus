import Foundation

/// Журнал модуля «Клавиатура» для диагностики: последние записи в памяти и файл с ротацией.
/// Нажатые клавиши не пишем: только Fn и тип события. Без AppKit: проверяется тестом.
final class KeyboardLog: @unchecked Sendable {
    typealias Entry = KeyboardLogEntry

    static let maxEntries = 50
    static let maxFileBytes = 200_000

    #if KIT_TEST_DEFAULTS
    /// Стенд не пишет в настоящий журнал пользователя: свой файл во временной папке.
    static let shared = KeyboardLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("utilitumus-keyboard-test.log"))
    #else
    static let shared = KeyboardLog(fileURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Utilitumus/keyboard.log"))
    #endif

    private let fileURL: URL?
    private let lock = NSLock()
    private var items: [Entry] = []
    /// Запись в файл идёт не на главном потоке и по порядку.
    private let queue = DispatchQueue(label: "utilitumus.keyboard.log", qos: .utility)

    init(fileURL: URL?) { self.fileURL = fileURL }

    func add(_ text: String, date: Date = Date()) {
        let entry = Entry(date: date, text: text)
        lock.lock()
        items.append(entry)
        if items.count > Self.maxEntries { items.removeFirst(items.count - Self.maxEntries) }
        lock.unlock()
        if fileURL != nil { queue.async { self.append(Self.line(entry)) } }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    /// Последние записи, новые в конце.
    func recent(_ n: Int = maxEntries) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.suffix(n))
    }

    /// Весь журнал одним текстом, чтобы прислать.
    func text() -> String { recent().map(Self.line).joined(separator: "\n") }

    /// Дождаться записи в файл (для теста).
    func flush() { queue.sync {} }

    static func line(_ entry: Entry) -> String { "\(KeyboardLogEntry.stamp(entry.date)) \(entry.text)" }

    /// Время для списка на экране.
    static func shortTime(_ date: Date) -> String { KeyboardLogEntry.shortTime(date) }

    // MARK: Файл

    private func append(_ line: String) {
        guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        let fm = FileManager.default
        let path = fileURL.path
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > Self.maxFileBytes {
            rotate(fileURL)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Оставляем вторую половину файла с ближайшей границы строки.
    private func rotate(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(data.count / 2)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
