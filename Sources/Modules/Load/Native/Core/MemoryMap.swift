import Foundation

/// Доля сегмента полосы памяти: macOS, программа или «прочее».
struct SplitRow: Sendable, Identifiable {
    /// «macos», «rest» или id группы.
    var key: String
    var name: String
    var mb: Int
    /// По нему подбирается цвет: один у программы во всех категориях.
    var colorKey: String
    var id: String { key }
}

/// Кандидат в «Что можно освободить»: группа с её памятью в RAM и сжатой.
struct FreeCandidate: Sendable, Identifiable {
    var key: String
    var name: String
    var ramMB: Int
    var compressedMB: Int
    /// Подсказка, если кнопка «Остановить группу» не освободит и половины.
    var hint: String
    /// Группа, которую можно остановить кнопкой; nil — только подсказка.
    var stoppableGroup: String?
    var id: String { key }
    var totalMB: Int { ramMB + compressedMB }
}

struct RamSplitRow: Sendable, Identifiable {
    var id: String
    var name: String
    var kind: GroupKind
    var ramMB: Int
    var swappedMB: Int
}

struct CompressedRow: Sendable, Identifiable {
    var pid: Int32
    var name: String
    var group: String
    var mb: Int
    var stoppable: Bool
    var id: Int32 { pid }
}

struct WiredRow: Sendable, Identifiable {
    var pid: Int32
    var name: String
    var mb: Double
    var id: Int32 { pid }
}

/// Карта памяти: из чего состоит «занято» и что можно освободить. Разбор по группам — оценки
/// процессов, они с vm_stat один в один не сходятся, поэтому доли подогнаны под итоги.
struct MemoryMap: Sendable {
    var macosMB = 0
    var programsMB = 0
    var cacheMB = 0
    var wiredMB = 0
    var splitApp: [SplitRow] = []
    var splitCompressed: [SplitRow] = []
    var freeCandidates: [FreeCandidate] = []
    var appBreakdown: [RamSplitRow] = []
    var compressedBreakdown: [CompressedRow] = []
    var wiredBreakdown: [WiredRow] = []
    /// Сколько памяти в программах держат процессы всего и сколько из этого сжато или в свопе.
    var heldMB = 0
    var swappedMB = 0

    static let wiredNote = "Ядро macOS, драйверы и видеопамять GPU — на Apple Silicon память общая. Напрямую не освобождается; уменьшается, если закрыть тяжёлые графические приложения"
    static let cachedNote = "Недавно прочитанные файлы. macOS сама отдаст эту память, когда понадобится — это не потеря"
    static let freeNote = "Ничем не занятая память. Мало свободной — это нормально: macOS сразу отдаёт лишнее под кэш файлов."

    private static let splitTop = 8
    private static let candidates = 12
    private static let listTop = 15

    private static func hint(gid: String, kind: GroupKind, name: String) -> String {
        if gid == "system" {
            return "Это сама macOS: WindowServer, Spotlight, Finder и службы. Напрямую не освободить — что помогает, смотри в подсказках группы «Система»"
        }
        switch kind {
        case .app:
            return Kinds.browsers.contains(Kinds.shortAppName(name))
                ? "Закрой лишние вкладки: каждая — отдельный процесс «вкладка». В Chrome помогает «Экономия памяти» (Настройки → Производительность), тяжёлую вкладку видно в «Окно → Диспетчер задач»"
                : "Закрой приложение, если оно сейчас не нужно (⌘Q)"
        case .project:
            return "Процессы проекта без кнопки: останови их там, где запускал, — в терминале или IDE"
        default:
            return "Процессы без проекта и приложения — полный список по кнопке «показать все» в группе"
        }
    }

    /// Сегмент vm_stat по группам: macOS, 8 самых больших программ, прочее (с группой «без признаков») —
    /// в сумме ровно `total`.
    private static func split(_ raw: [String: Double], total: Int, names: [String: String]) -> [SplitRow] {
        let top = raw.filter { $0.key != "system" && $0.key != "other" && $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(splitTop).map(\.key)
        let rest = raw.values.reduce(0, +) - (raw["system"] ?? 0) - top.reduce(0) { $0 + (raw[$1] ?? 0) }
        let mbs = fit([raw["system"] ?? 0] + top.map { raw[$0] ?? 0 } + [max(0, rest)], total: total)
        var rows = [SplitRow(key: "macos", name: "macOS", mb: mbs[0], colorKey: "system")]
        for (i, g) in top.enumerated() {
            rows.append(SplitRow(key: g, name: names[g] ?? g, mb: mbs[i + 1], colorKey: g))
        }
        rows.append(SplitRow(key: "rest", name: "прочее", mb: mbs.last ?? 0, colorKey: "rest"))
        return rows
    }

    static func build(procs: [Int32: LoadProcess], assigned: [Int32: Assignment], groups: [ProcessGroup],
                      memory: MemoryTotals, stoppable canStop: (LoadProcess) -> Bool) -> MemoryMap {
        var ram: [String: Double] = [:], cmp: [String: Double] = [:]
        for (pid, a) in assigned {
            guard let p = procs[pid] else { continue }
            ram[a.groupID, default: 0] += p.inRAM
            cmp[a.groupID, default: 0] += p.swapped
        }
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let kinds = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.kind) })
        let sizes = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Double($0.memMB)) })
        let stoppable = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.stoppableMB) })

        var map = MemoryMap()
        map.splitApp = split(ram, total: memory.appMB, names: names)
        map.splitCompressed = split(cmp, total: memory.compressedMB, names: names)
        map.macosMB = map.splitApp[0].mb + map.splitCompressed[0].mb
        map.programsMB = memory.appMB + memory.compressedMB - map.macosMB
        map.cacheMB = memory.cachedMB
        map.wiredMB = memory.wiredMB

        let ramSum = ram.values.reduce(0, +), cmpSum = cmp.values.reduce(0, +)
        let kRam = ramSum > 0 ? Double(memory.appMB) / ramSum : 0
        let kCmp = cmpSum > 0 ? Double(memory.compressedMB) / cmpSum : 0
        var cands: [FreeCandidate] = []
        for gid in ram.keys {
            let r = Int((ram[gid, default: 0] * kRam).rounded()), c = Int((cmp[gid, default: 0] * kCmp).rounded())
            guard r + c > 0 else { continue }
            let stoppableGroup = gid != "system" && (stoppable[gid] ?? 0) > 0
            let covered = stoppableGroup && 2 * (stoppable[gid] ?? 0) >= (sizes[gid] ?? 0)
            let name = gid == "system" ? "macOS" : names[gid] ?? gid
            cands.append(FreeCandidate(
                key: gid == "system" ? "macos" : gid, name: name, ramMB: r, compressedMB: c,
                hint: covered ? "" : hint(gid: gid, kind: kinds[gid] ?? .other, name: names[gid] ?? ""),
                stoppableGroup: stoppableGroup ? gid : nil))
        }
        cands.sort { $0.totalMB != $1.totalMB ? $0.totalMB > $1.totalMB : $0.key < $1.key }
        map.freeCandidates = Array(cands.prefix(candidates))

        // Разбор по клику на сегмент полосы.
        var split: [String: (Double, Double)] = [:]
        for (pid, a) in assigned {
            guard let p = procs[pid] else { continue }
            let cur = split[a.groupID] ?? (0, 0)
            split[a.groupID] = (cur.0 + p.inRAM, cur.1 + p.swapped)
        }
        map.appBreakdown = split.map { gid, v in
            RamSplitRow(id: gid, name: names[gid] ?? Attribution.groupName(gid), kind: kinds[gid] ?? .other,
                        ramMB: Int(v.0.rounded()), swappedMB: Int(v.1.rounded()))
        }.sorted { $0.ramMB != $1.ramMB ? $0.ramMB > $1.ramMB : $0.id < $1.id }
        map.appBreakdown = Array(map.appBreakdown.prefix(listTop))

        let byGroup = assigned.mapValues { names[$0.groupID] ?? "" }
        map.compressedBreakdown = procs.values.filter { $0.swapped.rounded() > 0 }
            .sorted { $0.swapped != $1.swapped ? $0.swapped > $1.swapped : $0.pid < $1.pid }
            .prefix(listTop)
            .map { CompressedRow(pid: $0.pid, name: Kinds.label($0), group: byGroup[$0.pid] ?? "",
                                 mb: Int($0.swapped.rounded()), stoppable: canStop($0)) }
        map.wiredBreakdown = procs.values.filter { ($0.wiredMB ?? 0) >= 1 }
            .sorted { ($0.wiredMB ?? 0) != ($1.wiredMB ?? 0) ? ($0.wiredMB ?? 0) > ($1.wiredMB ?? 0) : $0.pid < $1.pid }
            .prefix(10).map { WiredRow(pid: $0.pid, name: Kinds.label($0), mb: ($0.wiredMB ?? 0)) }

        map.heldMB = groups.reduce(0) { $0 + $1.memMB }
        map.swappedMB = Int(procs.values.reduce(0.0) { $0 + $1.swapped }.rounded())
        return map
    }
}
