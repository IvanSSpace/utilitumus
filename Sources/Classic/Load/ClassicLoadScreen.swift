import SwiftUI

/// Экран модуля «Нагрузка»: шапка (давление, своп, «Просто / Подробно»), вкладки и содержимое.
/// Заменяет веб-страницу lambscape в `ClassicModuleDetail`.
struct ClassicLoadScreen: View {
    @ObservedObject var store: LoadStore
    @ObservedObject var background: BackgroundStore
    @AppStorage("LoadViewMode") private var modeRaw = LoadViewMode.full.rawValue
    @AppStorage("LoadTab") private var tabRaw = LoadTab.overview.rawValue
    @State private var drill: MemoryPart?

    @MainActor init(store: LoadStore? = nil) {
        let s = store ?? LoadStore.shared
        self.store = s
        background = s.background
    }

    private var mode: LoadViewMode { LoadViewMode(rawValue: modeRaw) ?? .full }
    private var tab: LoadTab {
        let t = LoadTab(rawValue: tabRaw) ?? .overview
        // «Фоновое» скрыто, пока нет ни агентов, ни ботов; выбор при этом не стираем — вкладка вернётся сама.
        return t == .background && !background.hasContent ? .overview : t
    }

    static func pressureWord(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: return "норма"
        case .warn: return "высокое"
        case .critical: return "критическое"
        }
    }

    static func swapIsHot(_ m: MemoryTotals) -> Bool {
        m.swapTotalMB > 0 && Double(m.swapUsedMB) / Double(m.swapTotalMB) > 0.7
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SegmentedControl(LoadTab.allCases.filter { $0 != .background || background.hasContent },
                             selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue })) { $0.title }
                .frame(maxWidth: 440)
            .padding(.bottom, 8)
            if let notice = store.notice { noticeBanner(notice) }
            content
        }
        .navigationTitle("Нагрузка")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    store.refreshNow()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .help("Обновить: собрать данные заново, не дожидаясь опроса")
            }
        }
        .onAppear { store.screenAppeared() }
        .onDisappear { store.screenDisappeared() }
        .sheet(item: Binding(get: { store.pendingStop }, set: { if $0 == nil { store.cancelStop() } })) { plan in
            StopConfirmSheet(store: store, plan: plan)
        }
        .sheet(item: Binding(get: { background.pending }, set: { if $0 == nil { background.cancel() } })) { plan in
            ClassicBackgroundConfirmSheet(background: background, plan: plan)
        }
    }

    private var subtitle: String {
        guard let h = store.snapshot?.host else { return "Память и процессы" }
        return "\(h.chip) · \(Fmt.gb(Double(h.ramMB))) GB"
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let m = store.snapshot?.memory {
                HStack(spacing: 6) {
                    Circle().fill(color(m.pressure)).frame(width: 9, height: 9)
                    Text("Давление: \(Self.pressureWord(m.pressure))")
                }
                .help("Давление памяти macOS")
                HStack(spacing: 6) {
                    if Self.swapIsHot(m) { Circle().fill(.orange).frame(width: 7, height: 7) }
                    Text("Своп \(Fmt.gb(Double(m.swapUsedMB)))/\(Fmt.gb(Double(m.swapTotalMB))) GB").monospacedDigit()
                }
                .help("Своп: занято / всего")
            } else {
                Text("Считаю…").foregroundStyle(.secondary)
            }
            Spacer()
            SegmentedControl(LoadViewMode.allCases, selection: Binding(get: { mode }, set: { modeRaw = $0.rawValue })) { $0.title }
            .help("Просто — главное. Подробно — карта памяти, процессы, история, диск")
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func color(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: return .green
        case .warn: return .orange
        case .critical: return .red
        }
    }

    private func noticeBanner(_ n: LoadNotice) -> some View {
        HStack {
            Label(n.text, systemImage: n.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(n.isError ? Color.orange : Color.green)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Закрыть") { store.notice = nil }.buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            ClassicOverviewTab(store: store, mode: mode, drill: $drill,
                        openMemory: { modeRaw = LoadViewMode.full.rawValue; tabRaw = LoadTab.memory.rawValue },
                        openBackground: { modeRaw = LoadViewMode.full.rawValue; tabRaw = LoadTab.background.rawValue })
        case .sessions:
            ClassicSessionsTab(store: store, mode: mode)
        case .background:
            ClassicBackgroundTab(background: background, mode: mode) { modeRaw = LoadViewMode.full.rawValue }
        case .memory:
            ClassicMemoryTab(store: store, mode: mode, drill: $drill) { modeRaw = LoadViewMode.full.rawValue }
        }
    }
}
