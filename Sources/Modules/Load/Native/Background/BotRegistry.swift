import Darwin
import Foundation

/// Минимальный разбор TOML: ровно то, что нужно для bots.toml (таблицы `[[bot]]`, строки, массивы, числа, логика).
/// Готовой библиотеки в Swift нет, а тянуть зависимость ради одного файла незачем. Ошибка синтаксиса — nil:
/// как в lambscape, битый файл не роняет панель, а просто означает «ботов нет».
struct MiniTOML {
    indirect enum Value {
        case string(String)
        case array([Value])
        case table([String: Value])
        case bool(Bool)
        case other(String)

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        /// Массив строк; любая не-строка в нём — nil.
        var strings: [String]? {
            guard case .array(let items) = self else { return nil }
            let list = items.compactMap(\.string)
            return list.count == items.count ? list : nil
        }
    }

    typealias Table = [String: Value]

    /// Массивы таблиц: `[[bot]]` → arrays["bot"].
    private(set) var arrays: [String: [Table]] = [:]

    private struct Failure: Error {}

    private struct Reader {
        let chars: [Character]
        var i = 0

        init(_ text: String) { chars = Array(text) }

        var atEnd: Bool { i >= chars.count }
        var cur: Character? { i < chars.count ? chars[i] : nil }

        func starts(with s: String) -> Bool {
            let a = Array(s)
            return i + a.count <= chars.count && Array(chars[i..<i + a.count]) == a
        }

        mutating func skipSpaces() {
            while let c = cur, c == " " || c == "\t" { i += 1 }
        }

        /// Пробелы, переводы строк и комментарии — между строками и внутри массивов.
        mutating func skipBlank() {
            while let c = cur {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
                else if c == "#" { while let d = cur, d != "\n" { i += 1 } }
                else { break }
            }
        }

        mutating func endOfLine() throws {
            skipSpaces()
            if cur == "#" { while let d = cur, d != "\n" { i += 1 } }
            if let c = cur, c != "\n", c != "\r" { throw Failure() }
        }

        mutating func key() throws -> String {
            skipSpaces()
            if cur == "\"" { return try basic() }
            if cur == "'" { return try literal() }
            var out = ""
            while let c = cur, c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." { out.append(c); i += 1 }
            if out.isEmpty { throw Failure() }
            return out
        }

        mutating func basic() throws -> String {
            let multi = starts(with: "\"\"\"")
            i += multi ? 3 : 1
            if multi, cur == "\n" { i += 1 }
            var out = ""
            while let c = cur {
                if multi ? starts(with: "\"\"\"") : c == "\"" { i += multi ? 3 : 1; return out }
                if c == "\n", !multi { throw Failure() }
                if c == "\\" {
                    i += 1
                    guard let e = cur else { throw Failure() }
                    i += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{8}")
                    case "f": out.append("\u{c}")
                    case "\"", "\\": out.append(e)
                    case "u", "U":
                        let n = e == "u" ? 4 : 8
                        guard i + n <= chars.count, let code = UInt32(String(chars[i..<i + n]), radix: 16),
                              let scalar = Unicode.Scalar(code) else { throw Failure() }
                        out.unicodeScalars.append(scalar)
                        i += n
                    case "\n" where multi:
                        while let d = cur, d == " " || d == "\t" || d == "\n" { i += 1 }
                    default: throw Failure()
                    }
                } else { out.append(c); i += 1 }
            }
            throw Failure()
        }

        mutating func literal() throws -> String {
            let multi = starts(with: "'''")
            i += multi ? 3 : 1
            if multi, cur == "\n" { i += 1 }
            var out = ""
            while let c = cur {
                if multi ? starts(with: "'''") : c == "'" { i += multi ? 3 : 1; return out }
                if c == "\n", !multi { throw Failure() }
                out.append(c)
                i += 1
            }
            throw Failure()
        }

        mutating func value() throws -> Value {
            skipSpaces()
            guard let c = cur else { throw Failure() }
            switch c {
            case "\"": return .string(try basic())
            case "'": return .string(try literal())
            case "[":
                i += 1
                var items: [Value] = []
                while true {
                    skipBlank()
                    if cur == "]" { i += 1; return .array(items) }
                    items.append(try value())
                    skipBlank()
                    if cur == "," { i += 1 } else if cur != "]" { throw Failure() }
                }
            case "{":
                i += 1
                var t: [String: Value] = [:]
                while true {
                    skipSpaces()
                    if cur == "}" { i += 1; return .table(t) }
                    let k = try key()
                    skipSpaces()
                    guard cur == "=" else { throw Failure() }
                    i += 1
                    t[k] = try value()
                    skipSpaces()
                    if cur == "," { i += 1 } else if cur != "}" { throw Failure() }
                }
            default:
                var raw = ""
                while let d = cur, !" \t\n\r,]}#".contains(d) { raw.append(d); i += 1 }
                if raw.isEmpty { throw Failure() }
                return raw == "true" ? .bool(true) : raw == "false" ? .bool(false) : .other(raw)
            }
        }
    }

    init?(parsing text: String) {
        var r = Reader(text)
        // nil — значения вне `[[...]]` и обычных таблиц нам не нужны, но разобрать их надо, чтобы поймать ошибки.
        var current: (name: String, index: Int)?
        do {
            while true {
                r.skipBlank()
                guard let c = r.cur else { break }
                if c == "[" {
                    let array = r.starts(with: "[[")
                    r.i += array ? 2 : 1
                    var name = ""
                    while let d = r.cur, d != "]", d != "\n" { name.append(d); r.i += 1 }
                    guard r.starts(with: array ? "]]" : "]") else { throw Failure() }
                    r.i += array ? 2 : 1
                    name = name.trimmingCharacters(in: .whitespaces)
                    if array {
                        arrays[name, default: []].append([:])
                        current = (name, arrays[name]!.count - 1)
                    } else {
                        current = nil // обычная таблица (в том числе вложенная в [[bot]]) — не читаем
                    }
                    try r.endOfLine()
                } else {
                    let k = try r.key()
                    r.skipSpaces()
                    guard r.cur == "=" else { throw Failure() }
                    r.i += 1
                    let v = try r.value()
                    try r.endOfLine()
                    if let cur = current { arrays[cur.name]![cur.index][k] = v }
                }
            }
        } catch {
            return nil
        }
    }
}

// MARK: Описание бота

/// Команда бота из bots.toml: argv без shell. Если в файле не список строк — `.invalid`, и кнопка скажет об этом.
enum BotCommand: Sendable, Equatable {
    case argv([String])
    case invalid
}

enum BotVerb: String, Sendable, CaseIterable {
    case start, stop, restart

    var title: String {
        switch self {
        case .start: return "Включить"
        case .stop: return "Выключить"
        case .restart: return "Перезапустить"
        }
    }

    /// Прошедшее время для сообщения о результате.
    var done: String {
        switch self {
        case .start: return "Включён"
        case .stop: return "Выключен"
        case .restart: return "Перезапущен"
        }
    }
}

struct BotSpec: Sendable, Equatable {
    var id: String
    var name: String
    var project: String
    var url: String?
    var launchd: [String]
    var bundleIDs: [String]
    var commands: [BotVerb: BotCommand]
    var requiresEnv: [String]
    var envFile: String?
    var note: String
}

enum BotRegistry {
    /// `bots.toml` лежит в папке данных приложения; нет файла — нет ботов. UTILITUMUS_BOTS — для проверок.
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["UTILITUMUS_BOTS"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Utilitumus/bots.toml")
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: (path: String, stamp: TimeInterval, size: Int, bots: [BotSpec])?

    /// Боты из файла. Читается заново, только если файл изменился: замер идёт каждые 3 с.
    static func load(_ url: URL = BotRegistry.url) -> [BotSpec] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        lock.lock()
        defer { lock.unlock() }
        if let c = cached, c.path == url.path, c.stamp == stamp, c.size == size { return c.bots }
        var bots: [BotSpec] = []
        if attrs != nil, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
           let toml = MiniTOML(parsing: text) {
            bots = (toml.arrays["bot"] ?? []).compactMap(spec)
        }
        cached = (url.path, stamp, size, bots)
        return bots
    }

    /// Запись без id, name или project пропускаем — как в lambscape.
    private static func spec(_ t: MiniTOML.Table) -> BotSpec? {
        guard let id = t["id"]?.string, let name = t["name"]?.string, let project = t["project"]?.string else { return nil }
        var commands: [BotVerb: BotCommand] = [:]
        for verb in BotVerb.allCases {
            guard let v = t[verb.rawValue] else { continue }
            if let argv = v.strings, !argv.isEmpty, argv.allSatisfy({ !$0.isEmpty }) { commands[verb] = .argv(argv) }
            else if case .array(let a) = v, a.isEmpty { continue }
            else if case .string(let s) = v, s.isEmpty { continue }
            else { commands[verb] = .invalid }
        }
        return BotSpec(id: id, name: name, project: project, url: t["url"]?.string,
                       launchd: t["launchd"]?.strings ?? [], bundleIDs: t["bundle_ids"]?.strings ?? [],
                       commands: commands, requiresEnv: t["requires_env"]?.strings ?? [],
                       envFile: t["env_file"]?.string, note: t["note"]?.string ?? "")
    }

    // MARK: Процессы бота

    /// Папки под защитой TCC: файлы в них не читаем, иначе macOS спросит доступ окном.
    static func isProtectedPath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return ["Documents", "Desktop", "Downloads"].contains { path.hasPrefix("\(home)/\($0)/") }
    }

    private nonisolated(unsafe) static var bundles: [String: String?] = [:]

    /// bundle id приложения, которому принадлежит exe, — из Info.plist (кэш по пути бандла).
    static func bundleID(ofExe exe: String) -> String? {
        guard let r = exe.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        let bundle = String(exe[..<r.lowerBound]) + ".app"
        lock.lock()
        if let hit = bundles[bundle] { lock.unlock(); return hit }
        lock.unlock()
        var id: String?
        if !isProtectedPath(bundle),
           let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            id = plist["CFBundleIdentifier"] as? String
        }
        lock.lock()
        bundles[bundle] = .some(id)
        lock.unlock()
        return id
    }

    /// Главные процессы бота: pid его меток launchd и запущенные .app с его bundle id.
    static func pids(of spec: BotSpec, procs: [Int32: LoadProcess], launchd: [String: Int32?]) -> [Int32] {
        var out = Set<Int32>()
        for label in spec.launchd {
            if let outer = launchd[label], let pid = outer, procs[pid] != nil { out.insert(pid) }
        }
        if !spec.bundleIDs.isEmpty {
            for p in procs.values where p.exe.contains(".app/Contents/MacOS/") {
                if let id = bundleID(ofExe: p.exe), spec.bundleIDs.contains(id) { out.insert(p.pid) }
            }
        }
        return out.sorted()
    }

    /// pid → причина: процессы ботов со всеми потомками трогает только команда из bots.toml
    /// (kill агента с KeepAlive — это перезапуск, а не остановка).
    static func fence(_ bots: [BotSpec], procs: [Int32: LoadProcess], tree: ProcessTree, launchd: [String: Int32?]) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for b in bots {
            for main in pids(of: b, procs: procs, launchd: launchd) {
                for q in tree.subtree(of: main) where out[q] == nil { out[q] = "процесс бота \(b.id) — только его кнопками" }
            }
        }
        return out
    }

    /// Обязательные переменные без значения. Сами значения (токены) никуда не уходят.
    static func envMissing(_ spec: BotSpec) -> [String] {
        guard !spec.requiresEnv.isEmpty else { return [] }
        var values = ProcessInfo.processInfo.environment
        if let file = spec.envFile, !file.isEmpty {
            values = [:]
            let text = isProtectedPath(file) ? "" : ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
            for raw in text.split(whereSeparator: \.isNewline) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("export ") { line.removeFirst(7) }
                guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                values[k] = v
            }
        }
        return spec.requiresEnv.filter { (values[$0] ?? "").isEmpty }
    }

    // MARK: Слушающие порты

    /// Слушающие TCP-сокеты процесса вида «127.0.0.1:8765» — через libproc, без lsof.
    static func listenPorts(of pid: Int32) -> [String] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var out = Set<String>()
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_options & Int16(SO_ACCEPTCONN) != 0 else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let port = UInt16(truncatingIfNeeded: ini.insi_lport).byteSwapped
            var buf = [CChar](repeating: 0, count: 64)
            if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
                var addr = ini.insi_laddr.ina_6
                inet_ntop(AF_INET6, &addr, &buf, 64)
                out.insert("[\(String(cString: buf))]:\(port)")
            } else {
                var addr = ini.insi_laddr.ina_46.i46a_addr4
                inet_ntop(AF_INET, &addr, &buf, 64)
                out.insert("\(String(cString: buf)):\(port)")
            }
        }
        return out.sorted()
    }
}

// MARK: Статус бота

enum BotState: String, Sendable {
    case running, partial, stopped, noConfig

    var title: String {
        switch self {
        case .running: return "Работает"
        case .partial: return "Частично"
        case .stopped: return "Остановлен"
        case .noConfig: return "Не настроен"
        }
    }
}

struct BotItem: Sendable, Identifiable {
    var id: String
    var name: String
    var state: BotState
    var pids: [Int32]
    var memMB: Int
    var uptime: TimeInterval
    var ports: [String]
    var url: String?
    var note: String
    var actions: [BotVerb]
    var spec: BotSpec

    var isOn: Bool { state == .running || state == .partial }
}

extension BotRegistry {
    static func status(_ spec: BotSpec, procs: [Int32: LoadProcess], tree: ProcessTree, launchd: [String: Int32?]) -> BotItem {
        let mains = pids(of: spec, procs: procs, launchd: launchd)
        let all = Set(mains.flatMap { tree.subtree(of: $0) })
        // Статус — по меткам launchd (их и гасит команда из конфига); .app вроде менюбара — только в pid и памяти.
        let up: Int, total: Int
        if !spec.launchd.isEmpty {
            up = spec.launchd.filter { label in (launchd[label] ?? nil).map { procs[$0] != nil } ?? false }.count
            total = spec.launchd.count
        } else {
            let found = Set(mains.compactMap { procs[$0].flatMap { bundleID(ofExe: $0.exe) } })
            up = spec.bundleIDs.filter { found.contains($0) }.count
            total = spec.bundleIDs.count
        }
        let missing = envMissing(spec)
        let state: BotState = total > 0 && up == total ? .running : up > 0 ? .partial : !missing.isEmpty ? .noConfig : .stopped
        var note = spec.note
        if state == .noConfig {
            let where_ = spec.envFile.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? "окружение"
            note = "Не настроен: впиши \(missing.joined(separator: ", ")) в \(where_)"
        }
        let wanted: [BotVerb]
        switch state {
        case .running: wanted = [.stop, .restart]
        case .partial: wanted = [.start, .stop, .restart]
        case .stopped: wanted = [.start]
        case .noConfig: wanted = []
        }
        // Аптайм — по процессам launchd: менюбар-приложение бота живёт неделями и врало бы.
        let labelled = Set(spec.launchd.compactMap { launchd[$0] ?? nil }).intersection(mains)
        let starts = (labelled.isEmpty ? Set(mains) : labelled).compactMap { procs[$0]?.startTime }.filter { $0 > 0 }
        let ports = Set(all.flatMap { listenPorts(of: $0) }).sorted()
        return BotItem(
            id: spec.id, name: spec.name, state: state, pids: mains,
            memMB: Int(all.reduce(0.0) { $0 + (procs[$1]?.mem ?? 0) }.rounded()),
            uptime: starts.min().map { Date().timeIntervalSince1970 - $0 } ?? 0, ports: ports, url: spec.url,
            note: note, actions: wanted.filter { spec.commands[$0] != nil }, spec: spec)
    }
}
