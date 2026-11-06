import Darwin
import Foundation

/// Где запущен процесс: проект (папка с `.git` или `package.json`) и полный путь к рабочей папке.
struct ProcessPlace: Sendable, Codable, Equatable {
    /// Имя папки проекта, у домашней папки — пусто.
    var project: String
    /// Рабочая папка с `~` вместо домашней.
    var path: String
    /// Процесс запущен прямо из домашней папки: проекта нет.
    var isHome: Bool

    /// Короткая подпись: имя проекта либо «из домашней папки».
    var title: String { isHome ? "из домашней папки" : project }
}

/// Рабочая папка процесса и проект, которому она принадлежит.
/// Сканер процессов уже читает cwd при каждом замере; здесь — только поиск корня проекта, один раз на папку.
enum ProcessPlaces {
    /// cwd процесса через `proc_pidinfo`, без внешних процессов. Для своих процессов root не нужен;
    /// не вышло (чужой процесс, процесс завершился) — nil.
    static func cwd(ofPid pid: Int32) -> String? {
        var vnode = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size else { return nil }
        return withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
            let path = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return path.isEmpty ? nil : path
        }
    }

    /// Место процесса по его cwd. `/`, пустой путь и nil — места нет (у launchd-служб cwd обычно `/`).
    static func place(cwd: String?, home: String = NSHomeDirectory()) -> ProcessPlace? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        if cwd == home { return ProcessPlace(project: "", path: "~", isHome: true) }
        let short = cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
        let root = projectRoot(of: cwd, home: home)
        let name = root.split(separator: "/").last.map(String.init) ?? cwd
        return ProcessPlace(project: name, path: short, isHome: false)
    }

    // MARK: Корень проекта

    private static let lock = NSLock()
    /// Папка → корень проекта. Кэш общий, чтобы замеры не ходили по диску: запись на папку, а не на процесс.
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let cacheLimit = 2000

    /// Ближайший предок (включая саму папку) с `.git`; нет такого — ближайший с `package.json`; нет и его — сама папка.
    /// Выше домашней папки не поднимаемся: `.git` в `~` — не проект.
    static func projectRoot(of dir: String, home: String = NSHomeDirectory()) -> String {
        lock.lock()
        let hit = cache[dir]
        lock.unlock()
        if let hit { return hit }

        let fm = FileManager.default
        var firstPackage: String?
        var found: String?
        var cur = dir
        while cur != "/", cur != home, !cur.isEmpty {
            if fm.fileExists(atPath: cur + "/.git") { found = cur; break }
            if firstPackage == nil, fm.fileExists(atPath: cur + "/package.json") { firstPackage = cur }
            cur = (cur as NSString).deletingLastPathComponent
        }
        let root = found ?? firstPackage ?? dir

        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[dir] = root
        lock.unlock()
        return root
    }
}
