import Darwin
import Foundation

/// Запись найденного бота в bots.toml. Центр называет только id кандидата; запись целиком строит утилита, а команды
/// собираются здесь из метки и пути плиста без shell. Файл заменяется целиком и атомарно, права 600, старое содержимое
/// остаётся как было. Перед заменой новый текст разбирается тем же `MiniTOML`, что и при чтении.
enum BotsEntryWriter {
    struct Entry: Equatable {
        var id: String
        var name: String
        var project: String
        var launchd: [String]
        var start: [String]
        var stop: [String]
        var restart: [String]
        var watchDir: String?
        var note: String
    }

    static let monitorOnlyNote = "Найден поиском. Метки launchd нет, поэтому бот только наблюдается: включить, выключить и перезапустить отсюда нельзя."
    static let managedNote = "Найден поиском. Управляется через launchd."

    // MARK: Запись из кандидата

    static func entry(for c: BotsDiscovery.Candidate, uid: UInt32, home: String = NSHomeDirectory()) -> Entry {
        let shownProject = c.project.map { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        if let label = c.label, let plist = c.plist {
            let service = "gui/\(uid)/\(label)"
            return Entry(id: slug(c.name), name: c.name, project: shownProject ?? label, launchd: [label],
                         start: ["/bin/launchctl", "bootstrap", "gui/\(uid)", plist],
                         stop: ["/bin/launchctl", "bootout", service],
                         restart: ["/bin/launchctl", "kickstart", "-k", service],
                         watchDir: nil, note: managedNote)
        }
        return Entry(id: slug(c.name), name: c.name, project: shownProject ?? c.name, launchd: [],
                     start: [], stop: [], restart: [], watchDir: c.project, note: monitorOnlyNote)
    }

    static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased().unicodeScalars {
            if ch.value < 128, CharacterSet.alphanumerics.contains(ch) { out.unicodeScalars.append(ch) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((trimmed.isEmpty ? "bot" : trimmed).prefix(40))
    }

    /// Что уже описано в bots.toml: для того, чтобы не предлагать найденное повторно.
    static func known(_ bots: [BotSpec], home: String = NSHomeDirectory()) -> BotsDiscovery.Known {
        var known = BotsDiscovery.Known()
        func expand(_ p: String) -> String { p.hasPrefix("~/") ? home + p.dropFirst(1) : p }
        for bot in bots {
            known.labels.formUnion(bot.launchd)
            for path in [bot.project, bot.watchDir].compactMap({ $0 }) where path.hasPrefix("/") || path.hasPrefix("~/") {
                known.paths.insert((expand(path) as NSString).standardizingPath)
            }
            if let env = bot.envFile, env.hasPrefix("/") { known.paths.insert((((env as NSString).deletingLastPathComponent) as NSString).standardizingPath) }
        }
        return known
    }

    // MARK: TOML

    /// Строка TOML в двойных кавычках. Экранируется всё, что могло бы закрыть строку или начать новую запись:
    /// кавычка, обратная косая, управляющие символы, а также знаки, которые склеиваются с предыдущим символом.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let combining: Bool
                switch u.properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark, .format: combining = true
                default: combining = false
                }
                if u.value < 0x20 || u.value == 0x7f || (0x80...0x9f).contains(u.value) || u.value == 0x2028 || u.value == 0x2029 || combining {
                    out += String(format: u.value > 0xffff ? "\\U%08X" : "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    private static func array(_ items: [String]) -> String { "[" + items.map(quote).joined(separator: ", ") + "]" }

    static func block(_ e: Entry) -> String {
        var lines = ["[[bot]]", "id = \(quote(e.id))", "name = \(quote(e.name))", "project = \(quote(e.project))"]
        if !e.launchd.isEmpty { lines.append("launchd = \(array(e.launchd))") }
        if let dir = e.watchDir { lines.append("watch_dir = \(quote(dir))") }
        if !e.start.isEmpty { lines.append("start = \(array(e.start))") }
        if !e.stop.isEmpty { lines.append("stop = \(array(e.stop))") }
        if !e.restart.isEmpty { lines.append("restart = \(array(e.restart))") }
        lines.append("note = \(quote(e.note))")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Дозапись

    private static func refuse(_ text: String) -> BackgroundActionError { BackgroundActionError(message: text) }

    /// Добавляет запись в конец файла. Возвращает записанную запись (id мог получить суффикс). Отказ — `BackgroundActionError`.
    @discardableResult
    static func append(_ wanted: Entry, to url: URL) throws -> Entry {
        Kit.assertStandPath(url, "bots.toml")
        var entry = wanted
        var old = ""
        var existing: [MiniTOML.Table] = []
        var st = stat()
        let existed = lstat(url.path, &st) == 0
        if existed {
            guard st.st_mode & S_IFMT == S_IFREG else { throw refuse("bots.toml не обычный файл: не трогаю") }
            if let why = BotRegistry.unsafeReason(url) { throw refuse("Не добавляю: \(why)") }
            guard let data = FileManager.default.contents(atPath: url.path), let text = String(data: data, encoding: .utf8),
                  let toml = MiniTOML(parsing: text) else {
                throw refuse("bots.toml не читается: сначала исправьте файл, дописывать в него не буду")
            }
            old = text
            existing = toml.arrays["bot"] ?? []
        } else if errno != ENOENT {
            throw refuse("Не удалось проверить bots.toml")
        }
        for table in existing {
            let labels = table["launchd"]?.strings ?? []
            if entry.launchd.contains(where: labels.contains) || (entry.watchDir != nil && table["watch_dir"]?.string == entry.watchDir) {
                throw refuse("Этот бот уже есть в bots.toml")
            }
        }
        let taken = Set(existing.compactMap { $0["id"]?.string })
        if taken.contains(entry.id) {
            var n = 2
            while taken.contains("\(entry.id)-\(n)") { n += 1 }
            entry.id = "\(entry.id)-\(n)"
        }

        var text = old
        if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
        text += block(entry)

        // Новый текст должен разобраться, а последняя запись совпасть с задуманной до буквы.
        guard let check = MiniTOML(parsing: text), let bots = check.arrays["bot"], bots.count == existing.count + 1, let last = bots.last,
              last["id"]?.string == entry.id, last["name"]?.string == entry.name, last["project"]?.string == entry.project,
              (last["launchd"]?.strings ?? []) == entry.launchd, last["watch_dir"]?.string == entry.watchDir,
              last["start"]?.strings ?? [] == entry.start, last["stop"]?.strings ?? [] == entry.stop,
              last["restart"]?.strings ?? [] == entry.restart, last["note"]?.string == entry.note else {
            throw refuse("Запись не прошла проверку разбора: bots.toml не изменён")
        }

        let dir = url.deletingLastPathComponent()
        do {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch { throw refuse("Не удалось создать папку для bots.toml") }
        let temp = dir.appendingPathComponent(".bots.toml.\(getpid()).tmp")
        Kit.assertStandPath(temp, "bots.toml")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw refuse("Не удалось записать bots.toml") }
        var written = false
        defer { if !written { try? FileManager.default.removeItem(at: temp) } }
        let bytes = Array(text.utf8)
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + done, bytes.count - done) }
            if n <= 0 { close(fd); throw refuse("Не удалось записать bots.toml") }
            done += n
        }
        fchmod(fd, 0o600)
        fsync(fd)
        close(fd)
        // У нового файла проверяется и папка: небезопасная папка делает небезопасным и его.
        if !existed, let why = BotRegistry.unsafeReason(temp) { throw refuse("Не добавляю: \(why.replacingOccurrences(of: temp.lastPathComponent, with: "bots.toml"))") }
        guard rename(temp.path, url.path) == 0 else { throw refuse("Не удалось заменить bots.toml") }
        written = true
        return entry
    }
}
