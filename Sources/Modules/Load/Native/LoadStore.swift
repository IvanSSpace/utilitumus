import AppKit
import SwiftUI

/// Результат последнего действия «Остановить» — показывается баннером на экране.
struct LoadNotice: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var isError: Bool
}

/// Что `LoadStore` просит у движка. Проверки подставляют свой, который ничего не запускает и не останавливает.
protocol LoadMeasuring: Sendable {
    func recordHistory() async -> HistoryWindow
    func measure() async -> LoadSnapshot
    func historyWindow() async -> HistoryWindow
    func refreshNow() async -> LoadSnapshot
    func execute(_ plan: StopPlan) async -> StopResult
    func releaseHistory() async
}

extension LoadMeasuring {
    func releaseHistory() async {}
}

extension LoadEngine: LoadMeasuring {
    func measure() -> LoadSnapshot { measure(light: false) }
}

/// Состояние модуля «Нагрузка».
///
/// - Пока модуль включён (`start`), раз в минуту пишется история — экран при этом может быть закрыт.
/// - Пока экран открыт (`screenAppeared`), данные обновляются каждые 3 с.
///
/// Вся работа — в `LoadEngine` (актор): сюда доезжают только готовые снимки.
@MainActor
final class LoadStore: LoadModel {
    static let shared = LoadStore()

    static let liveInterval: Duration = .seconds(3)

    /// Снимок для экрана: публикуется, только когда заметные данные изменились (см. `SnapshotKey`),
    /// иначе каждые 3 с перерисовывался бы весь экран. Свежайший снимок — `latest`.
    @Published private(set) var snapshot: LoadSnapshot?
    /// Всегда-меняющееся (время замера, память и CPU самой панели): отдельно, чтобы не трогать тяжёлые секции.
    let live = LiveStats()
    /// Самый свежий снимок: по нему строятся планы остановки (там нужны актуальные процессы), экран его не наблюдает.
    private(set) var latest: LoadSnapshot?
    private var publishedKey: SnapshotKey?
    private var publishedAt = Date.distantPast
    @Published private(set) var history: HistoryWindow?
    @Published private(set) var palette = LoadPalette()
    /// План остановки, ждущий подтверждения.
    @Published var pendingStop: StopPlan?
    @Published private(set) var stopRunning = false
    @Published var notice: LoadNotice?

    let engine: any LoadMeasuring
    /// Вкладка «Фоновое»: агенты launchd и боты.
    let background: BackgroundStore
    private var historyLoop: Task<Void, Never>?
    private var liveLoop: Task<Void, Never>?
    private(set) var watchers = 0
    /// Считать ли сейчас. У встроенного модуля — окно видно; в утилите окна центра у неё нет, там решает аренда экрана.
    var visibleGate: @MainActor () -> Bool = { LoadStore.windowIsVisible() }
    private var noticeTimer: Task<Void, Never>?

    /// Идёт ли запись истории.
    var isRunning: Bool { historyLoop != nil }

    private convenience init() { self.init(engine: LoadEngine()) }

    /// Свой движок и своя вкладка «Фоновое» — для проверок: они не должны ничего останавливать по-настоящему.
    init(engine: any LoadMeasuring, background: BackgroundStore? = nil) {
        self.engine = engine
        self.background = background ?? BackgroundStore()
        self.background.onFinish = { [weak self] r in self?.backgroundFinished(r) }
    }

    // MARK: Для экрана

    var measure: LoadMeasure? { snapshot.map(LoadMeasure.init) }
    var stopPrompt: LoadStopPrompt? { pendingStop?.prompt }

    func dismissNotice() { notice = nil }

    // MARK: Модуль включён / выключен

    /// Запуск модуля: история раз в минуту. Повторный вызов ничего не делает.
    func start() {
        guard historyLoop == nil else { return }
        historyLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let engine = self?.engine else { return }
                let window = await engine.recordHistory()
                guard !Task.isCancelled else { return }
                self?.history = window
                try? await Task.sleep(for: .seconds(LoadHistory.interval))
            }
        }
    }

    /// Остановка модуля: ни истории, ни замеров. Повторный вызов ничего не делает.
    func stop() {
        historyLoop?.cancel()
        historyLoop = nil
        liveLoop?.cancel()
        liveLoop = nil
        watchers = 0
        let engine = engine
        Task { await engine.releaseHistory() }
    }

    // MARK: Экран открыт / закрыт

    func screenAppeared() {
        watchers += 1
        guard liveLoop == nil else { return }
        liveLoop = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if visibleGate() {
                    let s = await engine.measure()
                    guard !Task.isCancelled else { return }
                    apply(s)
                    if first { history = await engine.historyWindow() }
                }
                // Второй замер через секунду: у первого нет CPU %, он считается по разнице двух замеров.
                try? await Task.sleep(for: first ? .seconds(1) : Self.liveInterval)
                first = false
            }
        }
    }

    func screenDisappeared() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        liveLoop?.cancel()
        liveLoop = nil
    }

    /// Окно скрыто или свёрнуто — считать нечего.
    static func windowIsVisible() -> Bool {
        guard NSApp != nil else { return true }
        return NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    /// Не чаще чем раз в столько тихий снимок всё же публикуется: мелкие сдвиги (CPU, возраст) не залипают.
    private static let quietRepublish: TimeInterval = 9

    func apply(_ s: LoadSnapshot, force: Bool = false) {
        latest = s
        live.update(from: s)
        let key = SnapshotKey(s)
        let changed = force || key != publishedKey || snapshot == nil || Date().timeIntervalSince(publishedAt) >= Self.quietRepublish
        if changed {
            var p = palette
            p.update(from: s.map)
            // Палитра — значение целиком: публикуем, только если появились новые цвета.
            if p != palette { palette = p }
            snapshot = s
            publishedKey = key
            publishedAt = Date()
        }
        background.update(from: s, force: force)
    }

    func refreshNow() {
        background.forget()
        Task {
            let s = await engine.refreshNow()
            apply(s, force: true)
        }
    }

    // MARK: Остановка

    func requestStop(_ target: LoadStopTarget) {
        pendingStop = stopPlan(for: target)
    }

    func cancelStop() {
        guard !stopRunning else { return }
        pendingStop = nil
    }

    func confirmStop(_ planID: UUID) {
        guard let plan = pendingStop, plan.id == planID, !stopRunning else { return }
        stopRunning = true
        Task {
            let result = await engine.execute(plan)
            stopRunning = false
            pendingStop = nil
            show(LoadNotice(text: result.message, isError: !result.ok))
            apply(await engine.measure(), force: true)
        }
    }

    /// Действие над агентом или ботом выполнено: баннер и свежий замер (launchctl list обновится не сразу — второй замер позже).
    private func backgroundFinished(_ r: StopResult) {
        show(LoadNotice(text: r.message, isError: !r.ok))
        Task {
            apply(await engine.refreshNow(), force: true)
            try? await Task.sleep(for: .seconds(1.5))
            apply(await engine.refreshNow(), force: true)
        }
    }

    private func show(_ n: LoadNotice) {
        notice = n
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(n.isError ? 15 : 8))
            guard !Task.isCancelled else { return }
            if self?.notice?.id == n.id { self?.notice = nil }
        }
    }
}

#if KIT_TEST_DEFAULTS
extension LoadStore {
    /// Стенд: встроенный экран в том же состоянии, что показывает утилита. Замеры не запускаются.
    func testPin(_ state: LoadState, palette pinned: LoadPalette) {
        if let m = state.measure {
            let s = LoadSnapshot(timestamp: m.timestamp, host: m.host, memory: m.memory, procs: [:], tree: ProcessTree([:]), assigned: [:],
                                 groups: m.groups, map: m.map, advice: m.advice, sessions: m.sessions, disk: m.disk, fence: [:],
                                 launchd: [:], roots: [], selfPid: 0, selfMemMB: state.live.selfMemMB, selfCPU: state.live.selfCPU,
                                 measureMillis: state.live.measureMillis)
            latest = s
            snapshot = s
        }
        live.update(from: state.live)
        palette = pinned
        history = state.history
        notice = state.notice
        background.testPin(state.background)
    }
}
#endif
