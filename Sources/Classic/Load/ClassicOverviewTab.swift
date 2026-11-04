import SwiftUI

/// Вкладка «Обзор»: итоги, память, что выключить. В «Просто» — только главное.
struct ClassicOverviewTab: View {
    @ObservedObject var store: LoadStore
    let mode: LoadViewMode
    @Binding var drill: MemoryPart?
    var openMemory: () -> Void
    var openBackground: () -> Void
    @State private var aiOpen = false

    var body: some View {
        Form {
            if let s = store.snapshot {
                if mode == .full { full(s) } else { simple(s) }
                ClassicFooterSection(snapshot: s)
            } else {
                ProgressView("Считаю…").frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func full(_ s: LoadSnapshot) -> some View {
        let m = s.memory
        Section {
            HStack(alignment: .top, spacing: 16) {
                ClassicKPITile(title: "Занято", value: Fmt.gb(Double(m.usedMB)), unit: "GB",
                        subtitle: "из \(Fmt.gb(Double(m.totalMB))) GB · \(Fmt.percent(Double(m.usedMB), of: Double(m.totalMB)))")
                ClassicKPITile(title: "Сжато", value: Fmt.gb(Double(m.compressedMB)), unit: "GB",
                        subtitle: "\(Fmt.percent(Double(m.compressedMB), of: Double(m.usedMB))) занятого")
                ClassicKPITile(title: "Своп", value: Fmt.gb(Double(m.swapUsedMB)), unit: "GB",
                        subtitle: "из \(Fmt.gb(Double(m.swapTotalMB))) GB · \(Fmt.percent(Double(m.swapUsedMB), of: Double(m.swapTotalMB)))",
                        warn: ClassicLoadScreen.swapIsHot(m))
                ClassicAIMemoryKPI(ai: s.sessions.ai, open: $aiOpen)
                let freeable = s.advice.filter { $0.stopPid != nil }
                let freeMB = Double(freeable.reduce(0) { $0 + $1.savesMB })
                ClassicKPITile(title: "Можно освободить", value: freeable.isEmpty ? "—" : freeMB < 1024 ? String(Int(freeMB)) : Fmt.gb(freeMB),
                        unit: freeMB < 1024 ? "MB" : "GB", subtitle: freeable.isEmpty ? "нечего" : "по " + Fmt.plural(freeable.count, "подсказке", "подсказкам", "подсказкам"))
            }
            .padding(.vertical, 4)
            if aiOpen { ClassicAIDrillPanel(ai: s.sessions.ai) }
        }
        Section {
            ClassicMemoryCard(snapshot: s, palette: store.palette, mode: .full, drill: $drill) { store.requestStop(process: $0) }
        } header: {
            HStack {
                Text("Память")
                Text("\(Fmt.gb(Double(m.totalMB))) GB").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        ClassicAdviceSection(items: s.advice, limit: 5, onStop: { store.requestStop(process: $0) }, onMore: openMemory, moreTitle: "в «Памяти»")
        ClassicSessionsCompactSection(sessions: s.sessions.claude, now: s.timestamp.timeIntervalSince1970)
        ClassicBackgroundCompactSection(background: store.background, open: openBackground)
    }

    @ViewBuilder
    private func simple(_ s: LoadSnapshot) -> some View {
        Section("Память") {
            ClassicMemoryCard(snapshot: s, palette: store.palette, mode: .simple, drill: $drill) { _ in }
            if let h = store.history { ClassicHistorySpark(window: h) }
            Text(simpleDiskLine(s.disk)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        ClassicTopProgramsSection(map: s.map)
        ClassicAdviceSection(items: s.advice, limit: 3, onStop: { store.requestStop(process: $0) }, onMore: openMemory, moreTitle: "в «Подробно»")
        ClassicSessionsSimpleSection(sessions: s.sessions.claude) { store.requestStop(session: $0) }
    }
}

/// Строка внизу: сколько занимает сама панель и на чём идёт.
struct ClassicFooterSection: View {
    let snapshot: LoadSnapshot

    var body: some View {
        Section {
            let s = snapshot, h = s.host
            VStack(alignment: .leading, spacing: 2) {
                Text("Utilitumus · \(Fmt.mb(s.selfMemMB)) · CPU \(s.selfCPU.map { String(format: "%.1f%%", $0) } ?? "—") · замер \(Int(s.measureMillis.rounded())) мс")
                Text("\(h.chip) · \(Fmt.gb(Double(h.ramMB))) GB · macOS \(h.macOS) · аптайм \(Fmt.duration(h.uptime))")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
