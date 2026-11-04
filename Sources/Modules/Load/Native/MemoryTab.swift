import SwiftUI

/// Вкладка «Память»: карта памяти, что освободить, история за сутки, диск и все процессы по группам.
struct MemoryTab: View {
    @ObservedObject var store: LoadStore
    let mode: LoadViewMode
    @Binding var drill: MemoryPart?
    var openFull: () -> Void

    @State private var expanded: Set<String> = []
    @State private var showAll: Set<String> = []
    @State private var fullKinds: Set<GroupKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
            if let s = store.snapshot {
                if mode == .full { full(s) } else { simple(s) }
                FooterSection(host: s.host, live: store.live)
            } else {
                ProgressView("Считаю…").frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    @ViewBuilder
    private func full(_ s: LoadSnapshot) -> some View {
        DSSection("Память", trailing: "\(Fmt.gb(Double(s.memory.totalMB))) GB") {
            LoadLine(divider: false) {
                MemoryCard(snapshot: s, palette: store.palette, mode: .full, big: true, drill: $drill) { store.requestStop(process: $0) }
            }
        }
        AdviceSection(items: s.advice, limit: nil, onStop: { store.requestStop(process: $0) })
        DSSection("Память за 24 ч", trailing: historyNote) {
            LoadLine(divider: false) {
                if let h = store.history, !h.points.isEmpty {
                    HistoryChart(window: h, ramMB: s.memory.totalMB, swapTotalMB: s.memory.swapTotalMB,
                                 colors: store.palette.colors(forSeries: h.series))
                        .equatable()
                } else {
                    EmptyNote(text: "Пока пусто: точка пишется раз в минуту.")
                }
            }
        }
        DiskSection(disk: s.disk)
        FreeCandidatesSection(map: s.map, palette: store.palette) { store.requestStop(group: $0) }
        ForEach([GroupKind.project, .app, .system, .other], id: \.self) { kind in
            let list = s.groups.filter { $0.kind == kind }
            if !list.isEmpty || kind != .other {
                GroupsSection(kind: kind, groups: list, snapshot: s, expanded: $expanded, showAll: $showAll, fullKinds: $fullKinds,
                              onStopProcess: { store.requestStop(process: $0) }, onStopGroup: { store.requestStop(group: $0) })
            }
        }
    }

    /// «с 14:05» — если данные за сутки ещё копятся.
    private var historyNote: String? {
        guard let h = store.history, let first = h.firstSample, Double(first) > Double(h.from + 300) else { return nil }
        return "копится с " + Date(timeIntervalSince1970: TimeInterval(first)).formatted(.dateTime.hour().minute())
    }

    @ViewBuilder
    private func simple(_ s: LoadSnapshot) -> some View {
        DSSection("Память") {
            LoadLine(divider: false) {
                MemoryCard(snapshot: s, palette: store.palette, mode: .simple, drill: $drill) { _ in }
            }
            if let h = store.history { LoadLine { HistorySpark(window: h).equatable() } }
            LoadLine { Text(simpleDiskLine(s.disk)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        TopProgramsSection(map: s.map)
        HStack {
            DSButton("Подробности: карта памяти, процессы, история", icon: "chevron.right", style: .plain, small: true, action: openFull)
            Spacer()
        }
    }
}
