import SwiftUI

/// Экран модуля «Нагрузка»: шапка `DSPage` (давление и своп в строке, «Обновить»), вкладки, «Просто / Подробно» и содержимое.
struct LoadScreen<Model: LoadModel>: View {
    @Environment(\.pageActive) private var pageActive
    @ObservedObject var store: Model
    @ObservedObject var background: Model.Background
    @AppStorage("LoadViewMode") private var modeRaw = LoadViewMode.full.rawValue
    @AppStorage("LoadTab") private var tabRaw = LoadTab.overview.rawValue
    @State private var drill: MemoryPart?

    @MainActor init(model: Model) {
        store = model
        background = model.background
    }

    private var mode: LoadViewMode { LoadViewMode(rawValue: modeRaw) ?? .full }
    private var tab: LoadTab {
        let t = LoadTab(rawValue: tabRaw) ?? .overview
        // «Фоновое» скрыто, пока нет ни агентов, ни ботов; выбор при этом не стираем — вкладка вернётся сама.
        return t == .background && !background.hasContent ? .overview : t
    }

    var body: some View {
        DSPage(module: .load, subtitle: subtitle,
               primary: DSAction("Обновить", icon: "arrow.clockwise") { store.refreshNow() }) {
            controls
            if let notice = store.notice { noticeBanner(notice) }
            content
        }
        // Страница длиннее окна: открываться должна с шапки, а не с прокрученного места.
        .defaultScrollAnchor(.top)
        // Живой опрос идёт только пока страница показана (не в кэше страниц).
        .onPageActive { active in
            if active {
                store.screenAppeared(); background.setTabOpen(tab == .background)
            } else {
                store.screenDisappeared(); background.setTabOpen(false)
            }
        }
        .onChange(of: tab) { background.setTabOpen(pageActive && $1 == .background) }
        .sheet(item: Binding(get: { store.stopPrompt }, set: { if $0 == nil { store.cancelStop() } })) { plan in
            StopConfirmSheet(store: store, plan: plan).dsThemed()
        }
        .sheet(item: Binding(get: { background.prompt }, set: { if $0 == nil { background.cancel() } })) { plan in
            BackgroundConfirmSheet(background: background, plan: plan).dsThemed()
        }
    }

    /// «Давление: норма · Своп 2.1/4 GB» — строка под названием.
    private var subtitle: String {
        guard let m = store.measure?.memory else { return "Считаю…" }
        return "Давление: \(LoadText.pressureWord(m.pressure)) · Своп \(Fmt.gb(Double(m.swapUsedMB)))/\(Fmt.gb(Double(m.swapTotalMB))) GB"
            + (LoadText.swapIsHot(m) ? " · много" : "")
    }

    /// Вкладки и «Просто / Подробно».
    private var controls: some View {
        HStack(spacing: 12) {
            DSSegmented(LoadTab.allCases.filter { $0 != .background || background.hasContent },
                        selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue })) { $0.title }
            Spacer(minLength: 8)
            DSSegmented(LoadViewMode.allCases, selection: Binding(get: { mode }, set: { modeRaw = $0.rawValue })) { $0.title }
                .help("Просто — главное. Подробно — карта памяти, процессы, история, диск")
        }
    }

    private func noticeBanner(_ n: LoadNotice) -> some View {
        HStack(spacing: 10) {
            Label(n.text, systemImage: n.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(n.isError ? Color.orange : Color.green)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            DSButton("Закрыть", style: .plain, small: true) { store.dismissNotice() }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            OverviewTab(store: store, mode: mode, drill: $drill,
                        openMemory: { modeRaw = LoadViewMode.full.rawValue; tabRaw = LoadTab.memory.rawValue },
                        openBackground: { modeRaw = LoadViewMode.full.rawValue; tabRaw = LoadTab.background.rawValue })
        case .sessions:
            SessionsTab(store: store, mode: mode)
        case .background:
            BackgroundTab(background: background, mode: mode) { modeRaw = LoadViewMode.full.rawValue }
        case .memory:
            MemoryTab(store: store, mode: mode, drill: $drill) { modeRaw = LoadViewMode.full.rawValue }
        }
    }
}

extension LoadScreen where Model == LoadStore {
    /// Встроенный экран: модель — сам модуль.
    @MainActor init(store: LoadStore? = nil) {
        self.init(model: store ?? LoadStore.shared)
    }
}
