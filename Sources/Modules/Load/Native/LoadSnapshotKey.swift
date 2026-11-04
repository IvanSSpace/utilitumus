import Foundation
import SwiftUI

/// Всегда-меняющееся из замера: время, память и CPU самой панели, длительность замера.
/// Отдельный маленький объект: подвал экрана наблюдает его, а тяжёлые секции — нет.
@MainActor
final class LiveStats: ObservableObject {
    @Published private(set) var timestamp = Date()
    @Published private(set) var measureMillis = 0.0
    @Published private(set) var selfMemMB = 0.0
    @Published private(set) var selfCPU: Double?

    func update(from s: LoadSnapshot) {
        timestamp = s.timestamp
        measureMillis = s.measureMillis
        selfMemMB = s.selfMemMB
        selfCPU = s.selfCPU
    }
}

/// Отпечаток заметных данных снимка. Два снимка с одним отпечатком на экране выглядят одинаково
/// (числа сгруппированы в корзины: сдвиг на пару MB перерисовку не стоит), поэтому второй не публикуется.
/// Процессы, дерево и защита в отпечаток не входят: они нужны только планам остановки (`LoadStore.latest`).
struct SnapshotKey: Equatable {
    private let value: Int
    private let activity: [SessionActivity]

    /// Корзина: мелочь точнее, крупное грубее.
    private static func q(_ mb: Int) -> Int { mb < 256 ? mb / 8 : mb / 32 }
    private static func q(_ mb: Double) -> Int { q(Int(mb.rounded())) }
    private static func minutes(_ s: Double) -> Int { Int(s / 60) }

    init(_ s: LoadSnapshot) {
        var h = Hasher()
        let m = s.memory
        h.combine(m.totalMB); h.combine(Self.q(m.usedMB)); h.combine(Self.q(m.appMB)); h.combine(Self.q(m.wiredMB))
        h.combine(Self.q(m.compressedMB)); h.combine(Self.q(m.cachedMB)); h.combine(Self.q(m.freeMB))
        h.combine(Self.q(m.swapUsedMB)); h.combine(m.swapTotalMB); h.combine(m.pressure.rawValue)

        for g in s.groups {
            h.combine(g.id); h.combine(g.name); h.combine(g.count); h.combine(Self.q(g.memMB)); h.combine(g.restCount)
            for mem in g.members { h.combine(mem.pid); h.combine(mem.stoppable) }
            for t in g.topMB { h.combine(Self.q(t)) }
            h.combine(g.hints.count)
        }

        for a in s.advice {
            h.combine(a.id); h.combine(a.severity.rawValue); h.combine(a.title); h.combine(a.detail)
            h.combine(Self.q(a.savesMB)); h.combine(a.stopPid)
        }

        let map = s.map
        for v in [map.macosMB, map.programsMB, map.cacheMB, map.wiredMB, map.heldMB, map.swappedMB] { h.combine(Self.q(v)) }
        for r in map.splitApp + map.splitCompressed { h.combine(r.key); h.combine(Self.q(r.mb)) }
        for c in map.freeCandidates {
            h.combine(c.key); h.combine(Self.q(c.ramMB)); h.combine(Self.q(c.compressedMB)); h.combine(c.hint); h.combine(c.stoppableGroup)
        }
        for r in map.appBreakdown { h.combine(r.id); h.combine(Self.q(r.ramMB)); h.combine(Self.q(r.swappedMB)) }
        for r in map.compressedBreakdown { h.combine(r.pid); h.combine(Self.q(r.mb)); h.combine(r.stoppable) }
        for r in map.wiredBreakdown { h.combine(r.pid); h.combine(Self.q(r.mb)) }

        let d = s.sessions
        var acts: [SessionActivity] = []
        func child(_ c: SessionChild) {
            h.combine(c.pid); h.combine(c.name); h.combine(c.kind.rawValue); h.combine(Self.q(c.memMB ?? -1)); h.combine(c.stoppable)
            h.combine(Self.minutes(c.age))
        }
        func session(_ c: ClaudeSession) {
            h.combine(c.pid); h.combine(c.name); h.combine(c.status.rawValue); h.combine(Self.q(c.memMB))
            h.combine(Self.minutes(c.lastActivity)); h.combine(c.isSelf); h.combine(c.stoppable)
            acts.append(c.activity)
            c.children.forEach(child)
        }
        d.claude.forEach(session)
        for host in d.terminals {
            h.combine(host.hostPid); h.combine(host.app)
            for sh in host.shells {
                h.combine(sh.pid); h.combine(sh.foreground); h.combine(sh.cwd); h.combine(sh.stoppable)
                sh.children.forEach(child)
                sh.sessions.forEach(session)
            }
        }
        h.combine(d.tmux.running)
        for t in d.tmux.sessions { h.combine(t.name); h.combine(t.windows); h.combine(t.attached) }
        h.combine(d.docker.running)
        for c in d.docker.containers { h.combine(c.id); h.combine(c.state); h.combine(c.status) }
        for o in d.orphans { h.combine(o.pid); h.combine(Self.q(o.memMB)); h.combine(Self.minutes(o.age)) }
        for p in d.stoppableOrphans.sorted() { h.combine(p) }
        for p in d.ai.parts { h.combine(p.label); h.combine(Self.q(p.memMB)); h.combine(p.count) }

        let k = s.disk
        h.combine(k.model); h.combine(k.wearPct); h.combine(k.sparePct); h.combine(k.mediaErrors)
        h.combine(Int((k.swapGBPerDay * 10).rounded())); h.combine(k.swapSharePct)
        h.combine(Int(((k.swapWritten24hGB ?? -1) * 10).rounded()))

        value = h.finalize()
        activity = acts
    }
}

extension LoadPalette: Equatable {
    static func == (a: LoadPalette, b: LoadPalette) -> Bool { a.slots == b.slots }
}
