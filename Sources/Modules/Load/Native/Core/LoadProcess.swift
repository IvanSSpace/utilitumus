import Foundation

/// Один процесс на момент замера. Для чужих и root-процессов ядро отдаёт только
/// ppid, имя и путь — память у них берётся из кэша `top` (`RootMemory`) или неизвестна.
struct LoadProcess: Sendable, Identifiable {
    let pid: Int32
    let ppid: Int32
    /// uid пользователя, не путать с `uniqueID`.
    let user: UInt32
    /// p_uniqueid: в отличие от pid не переиспользуется — по нему узнаём «тот же ли это процесс».
    let uniqueID: UInt64
    /// Unix-время запуска; 0 — неизвестно (чужие процессы).
    let startTime: TimeInterval
    let name: String
    let exe: String
    /// Последняя часть пути exe, посчитана один раз на процесс.
    let exeName: String
    /// Это сессия claude (не `claude -p`) — признак зависит только от exe, имени и аргументов.
    let isClaude: Bool
    /// Хост вкладок терминала («Orca», «iTerm2», «Terminal») или nil.
    let terminal: String?
    let cwd: String?
    let args: [String]
    let tty: String?
    /// phys_footprint, MB: «Память» из Монитора активности. nil — неизвестно, а не 0.
    let memMB: Double?
    /// Сейчас в RAM (resident); у root не виден.
    let residentMB: Double?
    let wiredMB: Double?
    /// Сжато или в свопе (CMPRS из `top`); nil — `top` процесс не видел.
    let compressedMB: Double?
    /// Есть ли доступ к деталям (свои процессы).
    let readable: Bool
    let pgid: Int32
    let tpgid: Int32
    /// Загрузка ядра в %, 100 = одно ядро целиком. nil — первый замер или нет доступа.
    let cpuPercent: Double?

    var id: Int32 { pid }

    /// Память для сумм: неизвестная считается нулём.
    var mem: Double { memMB ?? 0 }

    /// Сколько сжато или в свопе. Точно — CMPRS из `top`; иначе оценка footprint − resident
    /// (у GPU-хелперов она завышена видеопамятью).
    var swapped: Double {
        if let compressedMB { return compressedMB }
        return residentMB.map { max(0, mem - $0) } ?? 0
    }

    /// Сколько памяти сейчас в RAM: resident, а у root — footprint без сжатого.
    var inRAM: Double { residentMB ?? max(0, mem - swapped) }

    /// Возраст процесса в секундах; nil, если время запуска неизвестно.
    func age(now: TimeInterval) -> Double? { startTime > 0 ? now - startTime : nil }
}

/// Родители и дети по ppid.
struct ProcessTree: Sendable {
    let children: [Int32: [Int32]]
    private let parents: [Int32: Int32]

    init(_ procs: [Int32: LoadProcess]) {
        var kids: [Int32: [Int32]] = [:]
        var parents: [Int32: Int32] = [:]
        for p in procs.values where p.pid != p.ppid {
            kids[p.ppid, default: []].append(p.pid)
            parents[p.pid] = p.ppid
        }
        // Порядок детей стабилен: иначе остановка и подписи «прыгали» бы между замерами.
        children = kids.mapValues { $0.sorted() }
        self.parents = parents
    }

    /// Процесс и все потомки: сначала самые глубокие, корень последним — порядок остановки.
    func subtree(of root: Int32) -> [Int32] {
        var order = [root]
        var seen: Set<Int32> = [root]
        var i = 0
        while i < order.count {
            for k in children[order[i]] ?? [] where seen.insert(k).inserted { order.append(k) }
            i += 1
        }
        return order.reversed()
    }

    /// Цепочка предков: родитель, дед, … до launchd.
    func ancestors(of pid: Int32, in procs: [Int32: LoadProcess]) -> [Int32] {
        var out: [Int32] = []
        var cur = procs[pid]
        while let p = cur, p.ppid != p.pid, !out.contains(p.ppid) {
            out.append(p.ppid)
            cur = procs[p.ppid]
        }
        return out
    }
}
