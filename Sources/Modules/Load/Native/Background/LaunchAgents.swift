import Foundation

/// Фоновые агенты launchd: сторонние задания gui/<uid> и системные службы из /Library/LaunchDaemons,
/// плюс каталог известных производителей — что перестанет работать, если агента выключить.
/// Здесь только чтение; менять состояние может только `BackgroundExecutor`. Правила один в один с lambscape (agents.py).

enum AgentVerb: String, Sendable, Codable {
    case stop, disable, enable
}

struct AgentTarget: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var name: String
    var memMB: Double
    var id: Int32 { pid }
}

struct AgentItem: Sendable, Codable, Equatable, Identifiable {
    var label: String
    var name: String
    var vendor: String
    var plist: String?
    var pids: [Int32]
    var memMB: Int
    var keepalive: Bool
    var runAtLoad: Bool
    var disabled: Bool
    /// "gui" или "system": у системных служб (root) кнопок нет, только подсказка sudo.
    var domain: String
    var note: String
    var sudoHint: String?
    var verbs: [AgentVerb]
    /// Процессы задания: корень первым, дальше по убыванию памяти. Для подтверждения.
    var targets: [AgentTarget] = []
    var loaded = false
    /// Почему панель не трогает задание (терминал, сама панель, macOS…).
    var refusal: String?
    /// Где запущен главный процесс; у служб с cwd «/» и из домашней папки — nil.
    var place: ProcessPlace? = nil

    var id: String { label }
    var isRunning: Bool { !pids.isEmpty }
    /// Имя для людей: «Производитель · Приложение» либо метка.
    var title: String {
        let s = [vendor, name].filter { !$0.isEmpty }.joined(separator: " · ")
        return s.isEmpty ? label : s
    }

    /// `targets` и `loaded` нужны только плану действия, его строит модуль.
    private enum CodingKeys: String, CodingKey {
        case label, name, vendor, plist, pids, memMB, keepalive, runAtLoad, disabled, domain, note, sudoHint, verbs, refusal, place
    }
}

enum LaunchAgents {
    static let guiDirs: [String] = {
        let home = NSHomeDirectory()
        return ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents"]
    }()
    static let systemDirs = ["/Library/LaunchDaemons"]
    /// Метки не com.apple., но от Apple (например com.openssh.ssh-agent): ищем их plist здесь.
    static let appleDirs = ["/System/Library/LaunchAgents"]
    /// Сам Utilitumus под launchd (local.utilitumus.plist). Сравнение точное: `local.utilitumus.selftest`
    /// проверки — обычный чужой агент, а префикс закрыл бы и его.
    static var selfLabels: Set<String> { Set(["local.utilitumus", Bundle.main.bundleIdentifier ?? ""]).subtracting([""]) }

    // начало метки (в нижнем регистре) → производитель, где лежат его программы (начало пути без домашней папки,
    // в нижнем регистре) и что перестанет работать
    private static let catalog: [(prefixes: [String], programs: [String], vendor: String, note: String)] = [
        (["com.logi.optionsplus.updater"], logiPrograms, "Logitech", "перестанут приходить обновления Logi Options+"),
        (["com.logi.", "com.logitech."], logiPrograms, "Logitech",
         "перестанут работать кнопки и жесты Logitech, мышь останется работать"),
        (["com.google.keystone", "com.google.googleupdater"],
         ["/library/google/", "/library/application support/google/"], "Google",
         "программы Google не будут обновляться в фоне, Chrome обновится при запуске"),
        (["us.zoom."], ["/applications/zoom.us.app/", "/library/privilegedhelpertools/us.zoom."], "Zoom",
         "Zoom не будет обновляться в фоне, звонки работают"),
        (["com.valvesoftware."], ["/applications/steam.app/", "/library/application support/steam/"], "Steam",
         "службы Steam: Steam и игры работают, службы поднимутся при запуске"),
        (["com.adobe."],
         ["/applications/adobe", "/applications/utilities/adobe", "/library/application support/adobe",
          "/library/privilegedhelpertools/com.adobe."], "Adobe",
         "службы Creative Cloud: синхронизация и обновления только при открытом Creative Cloud"),
        (["com.microsoft.update", "com.microsoft.autoupdate"],
         ["/library/application support/microsoft/", "/applications/microsoft", "/library/privilegedhelpertools/com.microsoft."],
         "Microsoft", "Office не будет обновляться в фоне, только вручную"),
        (["com.rogueamoeba."],
         ["/library/audio/plug-ins/hal/ark.driver/", "/library/application support/rogue amoeba",
          "/library/application support/loopback/", "/library/application support/audio hijack",
          "/library/application support/soundsource", "/library/application support/piezo",
          "/library/application support/farrago", "/library/application support/fission",
          "/library/privilegedhelpertools/com.rogueamoeba.", "/applications/loopback.app/", "/applications/audio hijack.app/",
          "/applications/soundsource.app/", "/applications/piezo.app/", "/applications/farrago.app/", "/applications/fission.app/"],
         "Rogue Amoeba", "перестанут работать Loopback, Audio Hijack и SoundSource, их звуковые устройства пропадут"),
    ]
    private static let logiPrograms = ["/applications/logi", "/library/application support/logi"]
    static let unknown = "что перестанет работать, неизвестно; вернуть можно кнопкой"
    /// У служб root кнопок нет — и «вернуть кнопкой» тоже.
    static let unknownRoot = "что перестанет работать — неизвестно"
    static let rootNote = "системная служба (нужен sudo)"
    static let terminalNote = "хост вкладок терминала: закроются все вкладки и сессии Claude"

    /// Метку выбирает сам автор агента, поэтому производителя показываем, только если и программа лежит у него.
    static func vendor(of label: String, program: String) -> (vendor: String, note: String) {
        let low = label.lowercased()
        var path = program.lowercased()
        let home = NSHomeDirectory().lowercased()
        if path.hasPrefix(home + "/") { path.removeFirst(home.count) }
        guard !path.contains("/../") else { return ("", unknown) }
        for c in catalog where c.prefixes.contains(where: { low.hasPrefix($0) }) && c.programs.contains(where: { path.hasPrefix($0) }) {
            return (c.vendor, c.note)
        }
        return ("", unknown)
    }

    /// Служба macOS. Одной метки мало: `com.apple.что-угодно` может назвать себя любой агент. Подходит plist из
    /// /System/Library/, а задание без plist (службы XPC, mdworker и другие) — только с программой из системы.
    /// Без plist и без процесса показывать нечего. Пустой `exe` — путь процесса не прочитался.
    static func isAppleService(label: String, plist: String?, exe: String?) -> Bool {
        guard label.hasPrefix("com.apple.") else { return false }
        if let plist { return plist.hasPrefix("/System/Library/") }
        guard let exe, !exe.isEmpty else { return true }
        return Kinds.isOSExecutable(exe)
    }

    static func botLabels(_ bots: [BotSpec]) -> Set<String> { Set(bots.flatMap(\.launchd)) }

    /// Почему панель не трогает задание, или nil: службы macOS, запущенные приложения, боты (у них свои кнопки),
    /// сама панель и всё в системном домене (там нужен root).
    static func whyRefused(label: String, domain: String, botLabels: Set<String>, appleService: Bool) -> String? {
        if appleService { return "служба macOS" }
        if label.hasPrefix("application.") || label.hasPrefix("[") || label.hasPrefix("0x") {
            return "это запущенное приложение, а не агент"
        }
        if botLabels.contains(label) { return "агент бота из bots.toml — только кнопками бота" }
        if selfLabels.contains(label) { return "это сама панель" }
        if domain != "gui" { return rootNote }
        return nil
    }

    /// Процессы задания, которые нельзя гасить: хост вкладок терминала, панель и её предки, процессы ботов.
    /// Причину называем по самому верхнему такому процессу (дерево — от глубоких к корню).
    static func whyTree(procs: [Int32: LoadProcess], tree: [Int32], fenced: [Int32: String]) -> String? {
        for q in tree.reversed() {
            if let p = procs[q], Kinds.terminalApp(p) != nil { return terminalNote }
            if let why = fenced[q] { return why }
        }
        return nil
    }

    /// Что можно сделать с агентом по его состоянию: остановить запущенного (загруженный без процесса ничего не
    /// держит — его только убрать из автозапуска), убрать из автозапуска невыключенного, вернуть выключенного или
    /// выгруженного (без plist вернуть можно только флагом — загрузится при входе).
    static func verbs(loaded: Bool, running: Bool, disabled: Bool, hasPlist: Bool) -> [AgentVerb] {
        var out: [AgentVerb] = loaded && running ? [.stop] : []
        if !disabled, loaded || hasPlist { out.append(.disable) }
        if disabled || (!loaded && hasPlist) { out.append(.enable) }
        return out
    }

    /// Команды launchctl для агента в gui/<uid>: stop — bootout (до следующего входа), disable — bootout и disable,
    /// enable — enable и, если не загружен, bootstrap своего plist.
    static func argv(_ verb: AgentVerb, label: String, plist: String?, loaded: Bool) -> [[String]] {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(label)"
        switch verb {
        case .stop: return [["bootout", target]]
        case .disable: return (loaded ? [["bootout", target]] : []) + [["disable", target]]
        case .enable: return [["enable", target]] + (plist != nil && !loaded ? [["bootstrap", domain, plist!]] : [])
        }
    }

    /// Как shlex.quote: без кавычек только безопасные символы.
    static func shellQuote(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !s.isEmpty, s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func sudoHint(_ label: String) -> String {
        let target = shellQuote("system/\(label)")
        return "sudo launchctl bootout \(target); sudo launchctl disable \(target)"
    }

    /// `launchctl print-disabled`: метка → выключена ли. Новые macOS пишут disabled/enabled, старые — true/false.
    static func parseDisabled(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        guard let re = try? NSRegularExpression(pattern: #""([^"]+)"\s*=>\s*(\w+)"#) else { return out }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 2))
            out[ns.substring(with: m.range(at: 1))] = word == "disabled" || word == "true"
        }
        return out
    }

    /// Имя для людей: бандл, в котором лежит исполняемый файл, иначе имя файла, иначе метка.
    static func name(program: String, label: String) -> String {
        if let r = program.range(of: #"([^/]+)\.app/Contents/MacOS/[^/]+$"#, options: .regularExpression) {
            let tail = String(program[r])
            if let end = tail.range(of: ".app/Contents/MacOS/") { return String(tail[..<end.lowerBound]) }
        }
        return program.hasPrefix("/") ? (program as NSString).lastPathComponent : label
    }

    static func clip(_ text: String, max: Int = 500) -> String {
        text.count <= max ? text : "…" + text.suffix(max - 1)
    }
}

// MARK: Чтение plist и флагов автозапуска

/// plist заданий и флаги автозапуска. Кэш: plist — по пути, mtime и размеру (файлы меняются редко),
/// флаги `print-disabled` — на минуту (меняются в основном кнопками самой панели, тогда `forget`).
final class LaunchState: @unchecked Sendable {
    struct Job: Sendable {
        var label: String
        var plist: String
        var program: String
        var keepalive: Bool
        var runAtLoad: Bool
        var disabled: Bool
    }

    static let shared = LaunchState()

    private let lock = NSLock()
    private var plistCache: [String: (stamp: Date, size: Int, job: Job?)] = [:]
    private var disabledAt = Date.distantPast
    private var disabledData: [String: Bool] = [:]
    private var appleCache: [String: Bool] = [:]

    private static func truthy(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return !s.isEmpty
        case let a as [Any]: return !a.isEmpty
        case let d as [String: Any]: return !d.isEmpty
        default: return false
        }
    }

    /// Именно булево true (CFBoolean), а не число 1: как `is True` в Python.
    private static func isTrue(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }

    static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func job(path: String, data: [String: Any]) -> Job? {
        guard let label = data["Label"] as? String, !label.isEmpty else { return nil }
        let args = data["ProgramArguments"] as? [Any]
        let program = (data["Program"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (args?.first as? String) ?? ""
        return Job(label: label, plist: path, program: program, keepalive: truthy(data["KeepAlive"]),
                   runAtLoad: isTrue(data["RunAtLoad"]), disabled: isTrue(data["Disabled"]))
    }

    /// Метка → задание из *.plist в каталогах. Первая найденная метка побеждает (каталоги по порядку, файлы по имени).
    func plists(_ dirs: [String]) -> [String: Job] {
        var out: [String: Job] = [:]
        let fm = FileManager.default
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = dir + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let stamp = attrs[.modificationDate] as? Date else { continue }
                let size = (attrs[.size] as? Int) ?? 0
                lock.lock()
                let hit = plistCache[path]
                lock.unlock()
                let job: Job?
                if let hit, hit.stamp == stamp, hit.size == size {
                    job = hit.job
                } else {
                    job = Self.readPlist(path).flatMap { Self.job(path: path, data: $0) }
                    lock.lock()
                    plistCache[path] = (stamp, size, job)
                    lock.unlock()
                }
                if let job, out[job.label] == nil { out[job.label] = job }
            }
        }
        return out
    }

    /// plist для bootstrap: лежит прямо в каталоге LaunchAgents и описывает именно эту метку (читаем заново).
    func isOwnPlist(_ path: String, label: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard LaunchAgents.guiDirs.contains(parent) else { return false }
        return (Self.readPlist(path)?["Label"] as? String) == label
    }

    /// Флаги автозапуска gui/<uid>. Нет ответа launchctl — пусто.
    func disabled(maxAge: TimeInterval = 60) -> [String: Bool] {
        lock.lock()
        if Date().timeIntervalSince(disabledAt) < maxAge { defer { lock.unlock() }; return disabledData }
        lock.unlock()
        let text = Tool.run(Exec.launchctl, ["print-disabled", "gui/\(getuid())"], timeout: 10)
        let data = text.map(LaunchAgents.parseDisabled) ?? [:]
        lock.lock()
        disabledData = data
        disabledAt = Date()
        lock.unlock()
        return data
    }

    /// После действия или по «Обновить»: флаги автозапуска перечитаются.
    func forget() {
        lock.lock()
        disabledAt = .distantPast
        lock.unlock()
    }

    func isApple(_ label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let hit = appleCache[label] { return hit }
        let v = LaunchAgents.appleDirs.contains { FileManager.default.fileExists(atPath: "\($0)/\(label).plist") }
        appleCache[label] = v
        return v
    }
}

// MARK: Список агентов

extension LaunchAgents {
    private static func isAppEntry(_ label: String) -> Bool {
        label.hasPrefix("application.") || label.hasPrefix("[") || label.hasPrefix("0x")
    }

    /// Сторонние задания launchd: с plist в LaunchAgents (автозапуск), без plist — только запущенные или выключенные
    /// кнопкой «убрать» (дремлющие апдейтеры приложений вроде ShipIt память не держат, а без них приложение не
    /// обновится), и запущенные системные службы (только подсказка sudo). Без служб macOS, приложений и ботов.
    static func collect(procs: [Int32: LoadProcess], tree: ProcessTree, launchd: [String: Int32?], bots: [BotSpec],
                        fenced: [Int32: String], state: LaunchState = .shared) -> [AgentItem] {
        // Без launchctl list не знаем, что загружено, — лучше ничего не предлагать.
        guard !launchd.isEmpty else { return [] }
        let skip = botLabels(bots)
        let gui = state.plists(guiDirs), dis = state.disabled(), rootJobs = state.plists(systemDirs)
        func pid(_ label: String) -> Int32? { launchd[label] ?? nil }
        func apple(_ label: String) -> Bool {
            isAppleService(label: label, plist: (gui[label] ?? rootJobs[label])?.plist, exe: pid(label).flatMap { procs[$0]?.exe })
        }
        func foreign(_ label: String) -> Bool { !isAppEntry(label) && !apple(label) }

        var labels = Set(gui.keys.filter(foreign))
        let extra = launchd.keys.filter { l in pid(l).map { procs[$0] != nil } ?? false } + dis.filter(\.value).map(\.key)
        for label in extra where gui[label] == nil && foreign(label) && !state.isApple(label) { labels.insert(label) }

        var items: [AgentItem] = []
        for label in labels.subtracting(skip) {
            let job = gui[label]
            let main = pid(label).flatMap { procs[$0] != nil ? $0 : nil }
            let sub = main.map { tree.subtree(of: $0) } ?? []
            let program = job?.program ?? main.flatMap { procs[$0]?.exe } ?? ""
            let off = dis[label] ?? job?.disabled ?? false
            // Метка есть и в /Library/LaunchDaemons — это служба root: bootout в gui её не остановит, исполнитель откажет.
            let root = rootJobs[label] != nil
            let why = whyRefused(label: label, domain: root ? "system" : "gui", botLabels: skip, appleService: apple(label))
                ?? whyTree(procs: procs, tree: sub, fenced: fenced)
            let v = vendor(of: label, program: program)
            // У защищённого — память только своего процесса: дерево хоста терминала — это вкладки и сессии в них,
            // они уже посчитаны в проектах, а остановить их отсюда всё равно нельзя.
            let held = why != nil ? Array(sub.suffix(1)) : sub
            items.append(AgentItem(
                label: label, name: name(program: program, label: label), vendor: v.vendor, plist: job?.plist,
                pids: main.map { [$0] } ?? [], memMB: Int(held.reduce(0.0) { $0 + (procs[$1]?.mem ?? 0) }.rounded()),
                keepalive: job?.keepalive ?? false, runAtLoad: job?.runAtLoad ?? false, disabled: off, domain: "gui",
                note: root ? rootNote : why.map { "Не трогаю: \($0)" } ?? v.note,
                sudoHint: root ? sudoHint(label) : nil,
                verbs: why != nil ? [] : verbs(loaded: launchd.keys.contains(label), running: !sub.isEmpty, disabled: off, hasPlist: job != nil),
                targets: targets(sub, main: main, procs: procs), loaded: launchd.keys.contains(label), refusal: why,
                place: main.flatMap { ProcessPlaces.place(cwd: procs[$0]?.cwd) }.flatMap { $0.isHome ? nil : $0 }))
        }

        // Запущенные системные службы root без метки в launchctl list gui: только подсказка sudo.
        var byExe: [String: [Int32]] = [:]
        for p in procs.values { byExe[p.exe, default: []].append(p.pid) }
        for (label, job) in rootJobs {
            let pids = job.program.hasPrefix("/") ? (byExe[job.program] ?? []).sorted() : []
            if pids.isEmpty || !foreign(label) || skip.contains(label) || labels.contains(label) { continue }
            let sub = pids.flatMap { tree.subtree(of: $0) }
            let v = vendor(of: label, program: job.program)
            items.append(AgentItem(
                label: label, name: name(program: job.program, label: label), vendor: v.vendor, plist: job.plist, pids: pids,
                memMB: Int(sub.reduce(0.0) { $0 + (procs[$1]?.mem ?? 0) }.rounded()), keepalive: job.keepalive,
                runAtLoad: job.runAtLoad, disabled: job.disabled, domain: "system",
                note: v.note == unknown ? unknownRoot : v.note, sudoHint: sudoHint(label), verbs: [],
                targets: [], loaded: true, refusal: rootNote))
        }
        return items.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            if $0.memMB != $1.memMB { return $0.memMB > $1.memMB }
            return $0.label.lowercased() < $1.label.lowercased()
        }
    }

    /// Процессы задания для подтверждения: корень первым, потомки по убыванию памяти.
    private static func targets(_ sub: [Int32], main: Int32?, procs: [Int32: LoadProcess]) -> [AgentTarget] {
        sub.compactMap { q in procs[q].map { AgentTarget(pid: q, name: Kinds.label($0), memMB: $0.mem) } }
            .sorted { ($0.pid == main ? 0 : 1, -$0.memMB) < ($1.pid == main ? 0 : 1, -$1.memMB) }
    }
}
