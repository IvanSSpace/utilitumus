import Foundation

/// В какую группу попал процесс и почему.
struct Assignment: Sendable {
    var groupID: String
    var why: String
    var path: String?
}

/// Атрибуция процессов: каждый попадает в группу проекта, приложения, системы или «прочего».
/// Правила как в lambscape (attrib.py).
final class Attribution {
    /// Результат «своих» признаков зависит только от cwd, exe и аргументов — считаем один раз на процесс.
    private struct OwnKey: Hashable {
        let pid: Int32
        let uniqueID: UInt64
        let cwd: String?
    }

    private var ownCache: [OwnKey: Assignment?] = [:]
    private var cachedRoots: [String] = []

    static func groupName(_ id: String) -> String {
        let (kind, name) = split(id)
        return name.isEmpty ? (kind == .system ? "Система" : "Прочее") : name
    }

    static func split(_ id: String) -> (GroupKind, String) {
        let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = GroupKind(rawValue: String(parts.first ?? "")) ?? .other
        return (kind, parts.count > 1 ? String(parts[1]) : "")
    }

    // MARK: Проект по пути

    private static func prefixes(_ roots: [String]) -> [String] {
        roots.map { ($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/" }
    }

    private static func findProject(in text: String, prefixes: [String], anywhere: Bool) -> (name: String, path: String)? {
        for r in prefixes {
            let tail: Substring
            if anywhere {
                guard let range = text.range(of: r) else { continue }
                tail = text[range.upperBound...]
            } else {
                guard text.hasPrefix(r) else { continue }
                tail = text.dropFirst(r.count)
            }
            let name = tail.prefix { $0 != "/" && $0 != "\0" }
            if !name.isEmpty { return (String(name), r + name) }
        }
        return nil
    }

    /// Папка первого уровня под корнем проектов: («lambscape», «/…/projects/lambscape»).
    static func project(of path: String?, roots: [String]) -> (name: String, path: String)? {
        guard let path, !path.isEmpty else { return nil }
        return findProject(in: path, prefixes: prefixes(roots), anywhere: false)
    }

    /// Проект сессии Claude: папка под корнем, иначе сама папка cwd (домашняя — «~»).
    static func sessionProject(cwd: String?, roots: [String]) -> (name: String, path: String)? {
        let hit = project(of: cwd, roots: roots)
        guard hit == nil, let cwd, !cwd.isEmpty, cwd != "/" else { return hit }
        let name = cwd == NSHomeDirectory() ? "~" : String(cwd.split(separator: "/").last ?? "")
        return (name, cwd)
    }

    // MARK: Назначение групп

    private func ownAssignment(_ p: LoadProcess, prefixes: [String]) -> Assignment? {
        let key = OwnKey(pid: p.pid, uniqueID: p.uniqueID, cwd: p.cwd)
        if let hit = ownCache[key] { return hit }
        var result: Assignment?
        let candidates: [(String?, String, Bool)] = [
            (p.cwd, "cwd в проекте", false), (p.exe, "exe в проекте", false),
            (p.args.isEmpty ? nil : p.args.joined(separator: "\0"), "args в проекте", true),
        ]
        for (value, why, anywhere) in candidates {
            if let value, let hit = Self.findProject(in: value, prefixes: prefixes, anywhere: anywhere) {
                result = Assignment(groupID: "project:\(hit.name)", why: why, path: hit.path)
                break
            }
        }
        if result == nil, let app = Kinds.appName(of: p.exe), !Kinds.isSystemPath(p.exe) {
            result = Assignment(groupID: "app:\(app)", why: "приложение", path: nil)
        }
        ownCache[key] = .some(result)
        return result
    }

    func assign(_ procs: [Int32: LoadProcess], tree: ProcessTree, roots: [String]) -> [Int32: Assignment] {
        // Кэш не копит мёртвые процессы вечно.
        if roots != cachedRoots || ownCache.count > 4000 {
            ownCache.removeAll()
            cachedRoots = roots
        }
        var out: [Int32: Assignment] = [:]
        let me = getuid()

        // 1. claude и все его потомки — проект по cwd сессии.
        for s in procs.values where s.user == me && Kinds.isClaude(s) {
            guard let proj = Self.sessionProject(cwd: s.cwd, roots: roots) else { continue }
            for pid in tree.subtree(of: s.pid) where out[pid] == nil {
                out[pid] = Assignment(groupID: "project:\(proj.name)",
                                      why: pid == s.pid ? "сессия claude" : "потомок claude \(s.pid)", path: proj.path)
            }
        }

        // 2–3. свои признаки: cwd / exe / args в проекте, exe в .app.
        let prefixes = Self.prefixes(roots)
        var own: [Int32: Assignment] = [:]
        for (pid, p) in procs where out[pid] == nil {
            if let hit = ownAssignment(p, prefixes: prefixes) { own[pid] = hit }
        }
        for (pid, p) in procs where out[pid] == nil {
            if let hit = own[pid] {
                out[pid] = hit
                continue
            }
            // без своих признаков — от ближайшего предка, но не через launchd и не через хост терминала
            var q = procs[p.ppid]
            var steps = 0
            var inherited = false
            while let a = q, a.pid > 1, Kinds.terminalApp(a) == nil, steps < 64 {
                if let hit = own[a.pid] {
                    out[pid] = Assignment(groupID: hit.groupID, why: "наследует от \(a.pid)", path: hit.path)
                    inherited = true
                    break
                }
                q = procs[a.ppid]
                steps += 1
            }
            if !inherited {
                out[pid] = pid == 0 || Kinds.isSystemPath(p.exe)
                    ? Assignment(groupID: "system", why: "системный путь", path: nil)
                    : Assignment(groupID: "other", why: "без признаков", path: nil)
            }
        }
        return out
    }
}

/// Целые доли `total` пропорционально `values`, в сумме ровно `total`: округление вниз, а недостающие
/// единицы — строкам с самой большой дробной частью. Делить не по чему — всё в последнюю строку («прочее»).
func fit(_ values: [Double], total: Int) -> [Int] {
    let sum = values.reduce(0, +)
    guard sum > 0 else { return Array(repeating: 0, count: max(values.count - 1, 0)) + [total] }
    let exact = values.map { $0 * Double(total) / sum }
    var out = exact.map { Int($0) }
    let missing = max(0, total - out.reduce(0, +))
    let order = out.indices.sorted { Double(out[$0]) - exact[$0] < Double(out[$1]) - exact[$1] }
    for i in order.prefix(missing) { out[i] += 1 }
    return out
}
