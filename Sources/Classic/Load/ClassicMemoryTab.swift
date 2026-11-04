import SwiftUI

/// Вкладка «Память»: карта памяти, что освободить, история за сутки, диск и все процессы по группам.
struct ClassicMemoryTab: View {
    @ObservedObject var store: LoadStore
    let mode: LoadViewMode
    @Binding var drill: MemoryPart?
    var openFull: () -> Void

    @State private var expanded: Set<String> = []
    @State private var showAll: Set<String> = []

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
        Section {
            ClassicMemoryCard(snapshot: s, palette: store.palette, mode: .full, big: true, drill: $drill) { store.requestStop(process: $0) }
        } header: {
            HStack {
                Text("Память")
                Text("\(Fmt.gb(Double(s.memory.totalMB))) GB").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        ClassicAdviceSection(items: s.advice, limit: nil, onStop: { store.requestStop(process: $0) })
        Section {
            if let h = store.history, !h.points.isEmpty {
                ClassicHistoryChart(window: h, ramMB: s.memory.totalMB, swapTotalMB: s.memory.swapTotalMB,
                             colors: store.palette.colors(forSeries: h.series))
            } else {
                ClassicEmptyNote(text: "Пока пусто: точка пишется раз в минуту.")
            }
        } header: {
            HStack {
                Text("Память за 24 ч")
                Spacer()
                if let first = store.history?.firstSample, Double(first) > Double((store.history?.from ?? 0) + 300) {
                    Text("данные копятся с \(Date(timeIntervalSince1970: TimeInterval(first)), format: .dateTime.hour().minute())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        ClassicDiskSection(disk: s.disk)
        ClassicFreeCandidatesSection(map: s.map, palette: store.palette) { store.requestStop(group: $0) }
        ForEach([GroupKind.project, .app, .system, .other], id: \.self) { kind in
            let list = s.groups.filter { $0.kind == kind }
            if !list.isEmpty || kind != .other {
                ClassicGroupsSection(kind: kind, groups: list, snapshot: s, expanded: $expanded, showAll: $showAll,
                              onStopProcess: { store.requestStop(process: $0) }, onStopGroup: { store.requestStop(group: $0) })
            }
        }
    }

    @ViewBuilder
    private func simple(_ s: LoadSnapshot) -> some View {
        Section("Память") {
            ClassicMemoryCard(snapshot: s, palette: store.palette, mode: .simple, drill: $drill) { _ in }
            if let h = store.history { ClassicHistorySpark(window: h) }
            Text(simpleDiskLine(s.disk)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        ClassicTopProgramsSection(map: s.map)
        Section {
            Button("Подробности: карта памяти, процессы, история…", action: openFull).buttonStyle(.link)
        }
    }
}
