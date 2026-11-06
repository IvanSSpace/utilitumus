import SwiftUI

/// Вкладка «Обзор»: итоги, память, что выключить. В «Просто» — только главное.
struct OverviewTab<Model: LoadModel>: View {
    @ObservedObject var store: Model
    let mode: LoadViewMode
    @Binding var drill: MemoryPart?
    var openMemory: () -> Void
    var openBackground: () -> Void
    @State private var aiOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
            if let s = store.measure {
                if mode == .full { full(s) } else { simple(s) }
                FooterSection(host: s.host, live: store.live)
            } else {
                ProgressView("Считаю…").frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    @ViewBuilder
    private func full(_ s: LoadMeasure) -> some View {
        let m = s.memory
        DSSection("Итоги") {
            LoadLine(divider: false) {
                FlowGrid(minWidth: 130, spacing: 16, rowSpacing: 12) {
                    KPITile(title: "Занято", value: Fmt.gb(Double(m.usedMB)), unit: "GB",
                            subtitle: "из \(Fmt.gb(Double(m.totalMB))) GB · \(Fmt.percent(Double(m.usedMB), of: Double(m.totalMB)))")
                    KPITile(title: "Сжато", value: Fmt.gb(Double(m.compressedMB)), unit: "GB",
                            subtitle: "\(Fmt.percent(Double(m.compressedMB), of: Double(m.usedMB))) занятого")
                    KPITile(title: "Своп", value: Fmt.gb(Double(m.swapUsedMB)), unit: "GB",
                            subtitle: "из \(Fmt.gb(Double(m.swapTotalMB))) GB · \(Fmt.percent(Double(m.swapUsedMB), of: Double(m.swapTotalMB)))",
                            warn: LoadText.swapIsHot(m))
                    AIMemoryKPI(ai: s.sessions.ai, open: $aiOpen)
                    let freeable = s.advice.filter { $0.stopPid != nil }
                    let freeMB = Double(freeable.reduce(0) { $0 + $1.savesMB })
                    KPITile(title: "Освободить", value: freeable.isEmpty ? "—" : freeMB < 1024 ? String(Int(freeMB)) : Fmt.gb(freeMB),
                            unit: freeMB < 1024 ? "MB" : "GB", subtitle: freeable.isEmpty ? "нечего" : "по " + Fmt.plural(freeable.count, "подсказке", "подсказкам", "подсказкам"))
                }
            }
            if aiOpen { LoadLine { AIDrillPanel(ai: s.sessions.ai) } }
        }
        DSSection("Память", trailing: "\(Fmt.gb(Double(m.totalMB))) GB") {
            LoadLine(divider: false) {
                MemoryCard(snapshot: s, palette: store.palette, mode: .full, drill: $drill) { store.requestStop(.process($0)) }
            }
        }
        AdviceSection(items: s.advice, limit: 5, onStop: { store.requestStop(.process($0)) }, onMore: openMemory, moreTitle: "в «Памяти»")
        SessionsCompactSection(sessions: s.sessions.claude, now: s.timestamp.timeIntervalSince1970)
        BackgroundCompactSection(background: store.background, open: openBackground)
    }

    @ViewBuilder
    private func simple(_ s: LoadMeasure) -> some View {
        DSSection("Память") {
            LoadLine(divider: false) {
                MemoryCard(snapshot: s, palette: store.palette, mode: .simple, drill: $drill) { _ in }
            }
            if let h = store.history { LoadLine { HistorySpark(window: h).equatable() } }
            LoadLine { Text(simpleDiskLine(s.disk)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        TopProgramsSection(map: s.map)
        AdviceSection(items: s.advice, limit: 3, onStop: { store.requestStop(.process($0)) }, onMore: openMemory, moreTitle: "в «Подробно»")
        SessionsSimpleSection(sessions: s.sessions.claude) { store.requestStop(.session($0.rowID)) }
    }
}

/// Строка внизу: сколько занимает сама панель и на чём идёт.
struct FooterSection: View {
    let host: HostInfo
    /// Меняется каждый замер: наблюдает только эта строка, а не весь экран.
    @ObservedObject var live: LiveStats

    var body: some View {
        let h = host
        VStack(alignment: .leading, spacing: 2) {
            Text("Utilitumus · \(Fmt.mb(live.selfMemMB)) · CPU \(live.selfCPU.map { String(format: "%.1f%%", $0) } ?? "—") · замер \(Int(live.measureMillis.rounded())) мс")
            Text("\(h.chip) · \(Fmt.gb(Double(h.ramMB))) GB · macOS \(h.macOS) · аптайм \(Fmt.duration(h.uptime))")
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 6)
    }
}
