import Foundation

/// Процесс в составе группы. Сам процесс берётся из `LoadSnapshot.procs` по pid.
struct GroupMember: Sendable, Identifiable {
    var pid: Int32
    /// Округлённая память; nil — неизвестна (root вне кэша `top`).
    var memMB: Int?
    var why: String
    /// Можно ли остановить его кнопкой (не системный, не чужой, не сама панель).
    var stoppable: Bool
    var id: Int32 { pid }
}

struct SystemHint: Sendable, Identifiable {
    var title: String
    var how: String
    var savesMB: Int
    var id: String { title }
}

/// Группа процессов: проект, приложение, система или прочее.
struct ProcessGroup: Sendable, Identifiable {
    var id: String
    var kind: GroupKind
    var name: String
    var path: String?
    var memMB: Int
    var count: Int
    /// Все процессы группы: по убыванию памяти, с неизвестной памятью — в конце.
    var members: [GroupMember]
    /// Пять самых тяжёлых и «ещё N»: сумма строк и остатка ровно `memMB` (округление подогнано).
    var topMB: [Int]
    var restCount: Int
    var restMB: Int
    /// Сколько памяти группы освободит кнопка «Остановить группу».
    var stoppableMB: Double
    var hints: [SystemHint] = []

    var top: ArraySlice<GroupMember> { members.prefix(topMB.count) }
}

enum Grouping {
    /// Группы снимка по убыванию памяти. Процессы с неизвестной памятью считаются в count и «ещё», но в top не попадают.
    static func groups(procs: [Int32: LoadProcess], assigned: [Int32: Assignment],
                       stoppable: (LoadProcess) -> Bool) -> [ProcessGroup] {
        struct Acc {
            var path: String?
            var mem = 0.0
            var members: [(pid: Int32, mem: Double?, why: String, stop: Bool)] = []
        }
        var acc: [String: Acc] = [:]
        for (pid, a) in assigned {
            guard let p = procs[pid] else { continue }
            // Изменяем на месте: копия Acc на каждый процесс делала бы разбор квадратичным.
            acc[a.groupID, default: Acc(path: a.path)].mem += p.mem
            acc[a.groupID]!.members.append((pid, p.memMB, a.why, stoppable(p)))
        }
        var out: [ProcessGroup] = []
        for (id, g) in acc {
            let (kind, _) = Attribution.split(id)
            let sorted = g.members.sorted {
                switch ($0.mem, $1.mem) {
                case let (a?, b?): return a != b ? a > b : $0.pid < $1.pid
                case (nil, _?): return false
                case (_?, nil): return true
                default: return $0.pid < $1.pid
                }
            }
            let known = sorted.filter { $0.mem != nil }.prefix(5)
            let total = Int(g.mem.rounded())
            let topSum = known.reduce(0.0) { $0 + ($1.mem ?? 0) }
            let parts = fit(known.map { $0.mem ?? 0 } + [max(0, g.mem - topSum)], total: total)
            out.append(ProcessGroup(
                id: id, kind: kind, name: Attribution.groupName(id), path: g.path, memMB: total, count: sorted.count,
                members: sorted.map { GroupMember(pid: $0.pid, memMB: $0.mem.map { Int($0.rounded()) }, why: $0.why, stoppable: $0.stop) },
                topMB: Array(parts.dropLast()), restCount: sorted.count - known.count, restMB: parts.last ?? 0,
                stoppableMB: sorted.filter(\.stop).reduce(0.0) { $0 + ($1.mem ?? 0) }))
        }
        return out.sorted { $0.memMB != $1.memMB ? $0.memMB > $1.memMB : $0.id < $1.id }
    }

    /// Что на деле помогает с памятью «Системы» — только для того, что сейчас запущено.
    static func systemHints(_ procs: [Int32: LoadProcess]) -> [SystemHint] {
        let finderBase = 150.0, spotlightLimit = 200.0
        var by: [String: Double] = [:]
        for p in procs.values { by[p.name, default: 0] += p.mem }
        let spotlight = by.filter { $0.key.hasPrefix("mds") || $0.key.hasPrefix("mdworker") }.values.reduce(0, +)
        var hints: [SystemHint] = []
        if let finder = by["Finder"], finder > finderBase {
            hints.append(SystemHint(title: "Перезапусти Finder",
                                    how: "Option + правый клик по Finder в Dock → «Перезапустить»: окна Finder закроются, файлы не пострадают",
                                    savesMB: Int((finder - finderBase).rounded())))
        }
        if let wallpaper = by["WallpaperDynamicExtension"] {
            hints.append(SystemHint(title: "Статичные обои вместо динамических",
                                    how: "Системные настройки → Обои: выбери обычную картинку — динамическим обоям нужен отдельный процесс",
                                    savesMB: Int(wallpaper.rounded())))
        }
        if spotlight > spotlightLimit {
            hints.append(SystemHint(title: "Spotlight индексирует код",
                                    how: "Системные настройки → Spotlight → Конфиденциальность: добавь папки с проектами и node_modules",
                                    savesMB: Int((spotlight - spotlightLimit).rounded())))
        }
        if by["WindowServer"] != nil {
            hints.append(SystemHint(title: "Меньше окон — меньше WindowServer",
                                    how: "Его память растёт с числом окон и экранов: закрой лишние окна, особенно браузерные, и отключи ненужный монитор",
                                    savesMB: 0))
        }
        return hints
    }
}
