import CryptoKit
import Darwin
import Foundation

/// Поиск ботов Telegram на этом Mac. Только чтение: ничего не запускает, не пишет, не ходит в сеть и не трогает
/// launchd. Идёт только по нажатию «Найти ботов», в утилите, не на главном потоке. Файл не зависит от остального
/// кода, чтобы его можно было собрать отдельно и убедиться, что он ничего не пишет (Tests/run-bots-remote-check.sh).
///
/// Откуда берутся кандидаты: LaunchAgents пользователя (включая незагруженные) и запущенные процессы пользователя.
/// Доказательства ищутся только в папке проекта и в ограниченном числе файлов верхнего уровня: зависимости, имена
/// ключей в `.env`, импорты. Значения переменных и токены не читаются в результат: из `.env` и окружения агента
/// берутся только имена ключей, из аргументов процессов и агентов — только пути, которые указывают на проект.
enum BotsDiscovery {
    struct ProcInfo: Sendable, Equatable {
        var pid: Int32
        var exe: String
        var cwd: String
    }

    struct Roots: Sendable {
        var home: String
        var launchAgents: String
        var uid: UInt32
        var processes: @Sendable () -> [ProcInfo]
    }

    enum Strength: String, Sendable { case confirmed, possible }

    struct Candidate: Sendable, Equatable {
        var id: String
        var name: String
        var label: String?
        var plist: String?
        var project: String?
        var strength: Strength
        var why: String
        var place: String
        var noAccess: Bool
    }

    struct Result: Sendable, Equatable {
        var candidates: [Candidate]
        /// Агенты с именем, которое нельзя безопасно подставить в команду.
        var skipped: Int
    }

    /// Уже описанное в bots.toml: метки launchd и папки проектов (абсолютные, без `~`).
    struct Known: Sendable {
        var labels: Set<String> = []
        var paths: Set<String> = []
    }

    // MARK: Пределы

    static let maxPlists = 300
    static let maxPlistBytes = 262_144
    static let maxProjects = 40
    static let maxCandidates = 32
    static let maxDirEntries = 2000
    static let depBytes = 131_072
    static let envBytes = 32_768
    static let sourceBytes = 65_536
    static let maxSources = 12
    static let maxProcesses = 4000

    static let depFiles = ["requirements.txt", "pyproject.toml", "Pipfile", "setup.py", "setup.cfg", "package.json", "go.mod", "Cargo.toml", "Gemfile"]
    static let envFiles = [".env", ".env.local", ".env.production", ".env.example"]
    static let sourceExtensions: Set<String> = ["py", "js", "mjs", "cjs", "ts", "go", "rb", "rs"]
    static let preferredSources = ["main", "bot", "app", "index", "run", "start", "server", "telegram", "tg"]
    static let libraries = ["aiogram", "python-telegram-bot", "pytelegrambotapi", "telebot", "telethon", "pyrogram", "telegraf", "grammy",
                            "@grammyjs", "node-telegram-bot-api", "telegram-bot-api", "teloxide", "tgbotapi", "gotgbot", "telegram-bot-ruby"]
    static let pythonModules: Set<String> = ["aiogram", "telegram", "telebot", "telethon", "pyrogram"]
    static let ownPrefixes = ["com.apple.", "local.utilitumus"]
    static let systemRoots = ["/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/private/var", "/dev", "/opt/homebrew"]

    // MARK: Живые корни

    static var live: Roots {
        let home = NSHomeDirectory()
        let agents = home + "/Library/LaunchAgents"
        #if KIT_TEST_DEFAULTS
        // Стенд ищет только в подставном доме и не смотрит на настоящие процессы.
        Kit.assertStandPath(agents, "поиск ботов")
        return Roots(home: home, launchAgents: agents, uid: getuid(), processes: { [] })
        #else
        return Roots(home: home, launchAgents: agents, uid: getuid(), processes: { liveProcesses() })
        #endif
    }

    // MARK: Поиск

    static func scan(_ roots: Roots, known: Known = Known()) -> Result {
        var found: [Candidate] = []
        var skipped = 0
        var projectsSeen = Set<String>()
        var agentProjects = Set<String>()

        for plist in plistPaths(roots.launchAgents) {
            guard let agent = readAgent(plist) else { continue }
            if ownPrefixes.contains(where: { agent.label.hasPrefix($0) }) { continue }
            if !validLabel(agent.label) { skipped += 1; continue }
            if known.labels.contains(agent.label) { continue }
            let project = projectDir(for: agent, home: roots.home)
            if let project, known.paths.contains(project.dir) { continue }
            if let project { agentProjects.insert(project.dir) }

            var reasons: [Reason] = agent.envKeys.compactMap(envKeyReason).prefix(1).map { Reason(text: "ключ \($0.text) в окружении агента", strong: $0.strong) }
            var denied = false
            if let project, projectsSeen.count < maxProjects || projectsSeen.contains(project.dir) {
                projectsSeen.insert(project.dir)
                let inspected = inspect(project.dir)
                reasons += inspected.reasons
                denied = inspected.denied
                if reasons.isEmpty, project.checkParent, let parent = parentDir(project.dir, home: roots.home) {
                    let more = inspect(parent)
                    reasons += more.reasons
                    denied = denied || more.denied
                }
            }
            let name = displayName(label: agent.label)
            let place = "LaunchAgent " + clean(agent.label, 90) + (project.map { " · " + shown($0.dir, home: roots.home) } ?? "")
            let weakPaths = [project?.dir, agent.program].compactMap { $0 }.map { relative($0, home: roots.home) }
            if let candidate = classify(id: "launchd:" + agent.label, name: name, label: agent.label, plist: plist, project: project?.dir,
                                        place: place, reasons: reasons, weak: weakName(agent.label, weakPaths), denied: denied) {
                found.append(candidate)
            }
        }

        // Процессы: рабочая папка и путь программы, больше ничего. Папки, уже занятые агентом, пропускаем.
        var byDir: [String: String] = [:]
        for p in roots.processes().prefix(maxProcesses) where isRuntime(exe: p.exe, cwd: p.cwd) {
            let dir = (p.cwd as NSString).standardizingPath
            guard usable(dir, home: roots.home), dir.hasPrefix(roots.home + "/"), !known.paths.contains(dir),
                  !agentProjects.contains(dir), byDir[dir] == nil else { continue }
            byDir[dir] = p.exe
        }
        for (dir, exe) in byDir.sorted(by: { $0.key < $1.key }).prefix(maxProjects) {
            let inspected = inspect(dir)
            let weak = weakName("", [relative(dir, home: roots.home), relative(exe, home: roots.home)])
            // Без названия-подсказки закрытая папка случайного скрипта в «Документах» не интересна.
            if inspected.denied && !weak && inspected.reasons.isEmpty { continue }
            let name = clean((dir as NSString).lastPathComponent, 60)
            if let candidate = classify(id: "proc:" + dir, name: name, label: nil, plist: nil, project: dir,
                                        place: "Процесс · " + shown(dir, home: roots.home), reasons: inspected.reasons, weak: weak, denied: inspected.denied) {
                found.append(candidate)
            }
        }

        found.sort { ($0.strength == .confirmed ? 0 : 1, $0.name.lowercased(), $0.id) < ($1.strength == .confirmed ? 0 : 1, $1.name.lowercased(), $1.id) }
        return Result(candidates: Array(found.prefix(maxCandidates)), skipped: skipped)
    }

    private struct Reason: Equatable {
        var text: String
        var strong: Bool
    }

    private static func classify(id: String, name: String, label: String?, plist: String?, project: String?, place: String,
                                 reasons: [Reason], weak: Bool, denied: Bool) -> Candidate? {
        let strong = reasons.filter(\.strong)
        let why: String
        let strength: Strength
        if !strong.isEmpty {
            strength = .confirmed
            why = strong.prefix(2).map(\.text).joined(separator: "; ")
        } else if let first = reasons.first {
            strength = .possible
            why = first.text
        } else if weak {
            strength = .possible
            why = "по названию (bot, tg, telegram); зависимостей Telegram в папке не нашлось"
        } else if denied, label != nil {
            strength = .possible
            why = "папку проекта проверить не удалось"
        } else {
            return nil
        }
        var final = why
        if denied { final += (strength == .confirmed ? "; " : ". ") + "Нет доступа к папке: разрешите в «Конфиденциальность и безопасность»" }
        return Candidate(id: digest(id), name: name.isEmpty ? "бот" : name, label: label, plist: plist, project: project,
                         strength: strength, why: clean(final, 240), place: clean(place, 220), noAccess: denied)
    }

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: LaunchAgents

    private struct Agent {
        var label: String
        var program: String?
        var arguments: [String]
        var workDir: String?
        var envKeys: [String]
    }

    private static func plistPaths(_ dir: String) -> [String] {
        guard let names = listDirectory(dir) else { return [] }
        return names.filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }.sorted().prefix(maxPlists).map { dir + "/" + $0 }
    }

    /// Из плиста берутся метка, путь программы и аргументы (чтобы найти проект), рабочая папка и имена переменных окружения.
    /// Значения переменных наружу не выходят; аргументы остаются только как пути, указывающие на проект.
    private static func readAgent(_ path: String) -> Agent? {
        guard case .data(let data) = readBounded(path, limit: maxPlistBytes),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty, label.utf8.count <= 300 else { return nil }
        var arguments = (plist["ProgramArguments"] as? [Any])?.prefix(16).compactMap { $0 as? String } ?? []
        let program = (plist["Program"] as? String) ?? arguments.first
        if let program, arguments.first != program { arguments.insert(program, at: 0) }
        // Остаются только абсолютные пути: аргумент вроде токена в проект не указывает.
        arguments = arguments.filter { $0.hasPrefix("/") && $0.utf8.count <= 1024 && !$0.contains("\0") }
        let keys = Array(((plist["EnvironmentVariables"] as? [String: Any]) ?? [:]).keys).sorted().prefix(64)
        return Agent(label: label, program: program?.hasPrefix("/") == true ? program : nil, arguments: arguments,
                     workDir: plist["WorkingDirectory"] as? String, envKeys: Array(keys))
    }

    /// Метка идёт в `gui/<uid>/<метка>`: только обычные символы, без слэшей и пробелов.
    static func validLabel(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 200 && s.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    private struct Project {
        var dir: String
        /// Папка выведена из пути скрипта: зависимости могут лежать на уровень выше (src/).
        var checkParent: Bool
    }

    private static func projectDir(for agent: Agent, home: String) -> Project? {
        if let w = agent.workDir, w.hasPrefix("/") {
            let dir = (w as NSString).standardizingPath
            if usable(dir, home: home) { return Project(dir: dir, checkParent: false) }
        }
        for arg in agent.arguments {
            for marker in ["/.venv/", "/venv/", "/node_modules/"] {
                if let r = arg.range(of: marker) {
                    let dir = ((String(arg[..<r.lowerBound])) as NSString).standardizingPath
                    if usable(dir, home: home) { return Project(dir: dir, checkParent: false) }
                }
            }
        }
        for arg in agent.arguments.dropFirst() where sourceExtensions.contains(((arg as NSString).pathExtension).lowercased()) {
            let dir = ((arg as NSString).deletingLastPathComponent as NSString).standardizingPath
            if usable(dir, home: home) { return Project(dir: dir, checkParent: true) }
        }
        if let program = agent.program {
            let dir = ((program as NSString).deletingLastPathComponent as NSString).standardizingPath
            if dir.hasPrefix(home + "/"), usable(dir, home: home) { return Project(dir: dir, checkParent: true) }
        }
        return nil
    }

    private static func parentDir(_ dir: String, home: String) -> String? {
        let parent = (dir as NSString).deletingLastPathComponent
        return usable(parent, home: home) && parent.hasPrefix(home + "/") ? parent : nil
    }

    /// Папка, в которой имеет смысл искать проект: не корень, не дом, не системное и не `~/Library`.
    static func usable(_ dir: String, home: String) -> Bool {
        guard dir.hasPrefix("/"), dir != "/", dir != home, !dir.contains("\0") else { return false }
        if dir.hasPrefix(home + "/Library/") { return false }
        if dir.hasPrefix(home + "/.") && !dir.hasPrefix(home + "/.local/") { return false }
        for root in systemRoots where dir == root || dir.hasPrefix(root + "/") { return false }
        return true
    }

    // MARK: Процессы

    static func isRuntime(exe: String, cwd: String) -> Bool {
        guard !cwd.isEmpty, cwd != "/" else { return false }
        let base = (exe as NSString).lastPathComponent.lowercased()
        if base == "python" || base == "node" || base == "bun" || base == "deno" || base == "ruby" { return true }
        if base.hasPrefix("python"), base.dropFirst(6).allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        return exe.hasPrefix(cwd + "/")
    }

    /// Все процессы пользователя: путь программы и рабочая папка. Аргументы командной строки не читаются.
    static func liveProcesses(uid: UInt32 = getuid()) -> [ProcInfo] {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard size > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(size) / MemoryLayout<Int32>.size + 32)
        let got = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got) / MemoryLayout<Int32>.size).prefix(maxProcesses).compactMap { $0 > 0 ? processInfo($0) : nil }
    }

    static func processInfo(_ pid: Int32) -> ProcInfo? {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let want = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, want) == want else { return nil }
        let cwd = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return ProcInfo(pid: pid, exe: String(cString: path), cwd: cwd)
    }

    // MARK: Доказательства в папке проекта

    private struct Inspection {
        var reasons: [Reason] = []
        var denied = false
    }

    /// Зависимости, имена ключей `.env`, импорты в верхних файлах. Всё с пределами по числу и размеру, без обхода вглубь.
    private static func inspect(_ dir: String) -> Inspection {
        var out = Inspection()
        guard let names = listDirectory(dir, denied: &out.denied) else { return out }
        func add(_ r: Reason) { if !out.reasons.contains(r), out.reasons.count < 4 { out.reasons.append(r) } }

        for file in depFiles where names.contains(file) {
            switch readBounded(dir + "/" + file, limit: depBytes) {
            case .data(let data):
                let text = String(decoding: data, as: UTF8.self).lowercased()
                if let lib = libraries.first(where: { mentions(text, $0) }) { add(Reason(text: "\(lib) в \(file)", strong: true)) }
            case .denied: out.denied = true
            case .missing: break
            }
        }
        for file in envFiles where names.contains(file) {
            switch readBounded(dir + "/" + file, limit: envBytes) {
            case .data(let data):
                // Из файла берутся только имена ключей: значение отбрасывается сразу, строка дальше не нужна.
                for key in envKeys(in: data) {
                    if let r = envKeyReason(key) { add(Reason(text: "ключ \(r.text) в \(file)", strong: r.strong)) }
                }
            case .denied: out.denied = true
            case .missing: break
            }
        }
        if out.reasons.isEmpty {
            let sources = names.filter { sourceExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted { (rank($0), $0) < (rank($1), $1) }.prefix(maxSources)
            for file in sources {
                guard case .data(let data) = readBounded(dir + "/" + file, limit: sourceBytes) else { continue }
                if let lib = importedLibrary(in: String(decoding: data, as: UTF8.self)) {
                    add(Reason(text: "импорт \(lib) в \(clean(file, 60))", strong: true))
                    break
                }
            }
        }
        return out
    }

    private static func rank(_ file: String) -> Int {
        let stem = (file as NSString).deletingPathExtension.lowercased()
        return preferredSources.firstIndex(of: stem) ?? preferredSources.count
    }

    /// Имена переменных из файла окружения (`KEY=значение`, `export KEY=…`). Значения не возвращаются.
    static func envKeys(in data: Data) -> [String] {
        var keys: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            var s = Substring(line.drop(while: { $0 == " " || $0 == "\t" }))
            if s.hasPrefix("#") { continue }
            if s.hasPrefix("export ") { s = s.dropFirst(7).drop(while: { $0 == " " }) }
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, key.utf8.count <= 80, key.unicodeScalars.allSatisfy({ $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }) {
                keys.append(key)
            }
            if keys.count >= 400 { break }
        }
        return keys
    }

    /// Ключ, по которому видно токен бота. `TELEGRAM_*` и `TG_*` — уверенно, голый `BOT_TOKEN` — только «возможно».
    private static func envKeyReason(_ key: String) -> Reason? {
        let k = key.uppercased()
        if k.contains("TELEGRAM") && (k.contains("TOKEN") || k.contains("BOT") || k.contains("API_HASH")) { return Reason(text: key, strong: true) }
        if k.hasPrefix("TG_") && (k.contains("TOKEN") || k.contains("BOT")) { return Reason(text: key, strong: true) }
        if k == "BOT_TOKEN" || k == "BOT_API_TOKEN" { return Reason(text: key, strong: false) }
        return nil
    }

    /// Библиотека Telegram в строках импорта. Остальной текст файла не разбирается.
    static func importedLibrary(in source: String) -> String? {
        for raw in source.split(whereSeparator: \.isNewline).prefix(400) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.count > 300 { continue }
            if line.hasPrefix("import ") || line.hasPrefix("from ") {
                let rest = line.drop(while: { !$0.isWhitespace }).drop(while: { $0.isWhitespace })
                let root = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                if pythonModules.contains(root) { return root }
            }
            if line.hasPrefix("import") || line.hasPrefix("from ") || line.contains("require(") || line.hasPrefix("\"") || line.hasPrefix("use ") || line.hasPrefix("gem ") {
                if let lib = libraries.first(where: { mentions(line, $0) }) { return lib }
            }
        }
        return nil
    }

    /// Слово целиком: «aiogram» в «aiogram==3» да, в «myaiogramx» нет.
    static func mentions(_ lowered: String, _ lib: String) -> Bool {
        var from = lowered.startIndex
        while from < lowered.endIndex, let r = lowered.range(of: lib, range: from..<lowered.endIndex) {
            let before = r.lowerBound == lowered.startIndex ? nil : lowered[lowered.index(before: r.lowerBound)]
            let after = r.upperBound == lowered.endIndex ? nil : lowered[r.upperBound]
            let glued = { (c: Character?) in c.map { $0.isLetter || $0.isNumber } ?? false }
            if !glued(before) && !glued(after) { return true }
            from = r.upperBound
        }
        return false
    }

    // MARK: Слабый признак: название

    static func weakName(_ label: String, _ paths: [String]) -> Bool {
        let text = ([label] + paths).joined(separator: "/")
        let tokens = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { $0.lowercased() }
        return tokens.contains { t in
            ["bot", "bots", "tg", "telegram", "tgbot", "telebot"].contains(t) || (t.hasSuffix("bot") && t.count > 3 && t != "robot")
        }
    }

    // MARK: Чтение с пределами

    enum Read {
        case data(Data)
        case denied
        case missing
    }

    /// Обычный файл не больше `limit` байт. Ссылки не раскрываются (`O_NOFOLLOW`), каналы не блокируют (`O_NONBLOCK`).
    static func readBounded(_ path: String, limit: Int) -> Read {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            // Плист часто лежит ссылкой в LaunchAgents: ссылку на файл разрешаем один раз и только для обычного файла.
            if errno == ELOOP, let real = realFile(path) { return readBounded(real, limit: limit) }
            return errno == EPERM || errno == EACCES ? .denied : .missing
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .missing }
        let cap = min(Int(st.st_size), limit)
        var buffer = [UInt8](repeating: 0, count: cap)
        var total = 0
        while total < cap {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, cap - total) }
            if n <= 0 { break }
            total += n
        }
        return .data(Data(buffer.prefix(total)))
    }

    private static func realFile(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return nil }
        return String(cString: buf)
    }

    private static func listDirectory(_ dir: String) -> [String]? {
        var denied = false
        return listDirectory(dir, denied: &denied)
    }

    /// Имена в папке, не больше `maxDirEntries`. nil — не открылась; `denied` отличает запрет системы от «нет такой папки».
    private static func listDirectory(_ dir: String, denied: inout Bool) -> [String]? {
        guard let d = opendir(dir) else {
            if errno == EPERM || errno == EACCES { denied = true }
            return nil
        }
        defer { closedir(d) }
        var names: [String] = []
        while let entry = readdir(d), names.count < maxDirEntries {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    // MARK: Показ

    static func displayName(label: String) -> String {
        let last = label.split(separator: ".").last.map(String.init) ?? label
        return clean(last.isEmpty ? label : last, 60)
    }

    static func relative(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
    }

    static func shown(_ path: String, home: String) -> String {
        clean(path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path, 110)
    }

    /// Строка для экрана: без управляющих и невидимых символов, не длиннее `limit`.
    static func clean(_ s: String, _ limit: Int) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            if v < 0x20 || (0x7f...0x9f).contains(v) || v == 0x2028 || v == 0x2029 || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200b || v == 0xfeff {
                out.append(" ")
            } else {
                out.append(u)
            }
        }
        let text = String(out).trimmingCharacters(in: .whitespaces)
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
