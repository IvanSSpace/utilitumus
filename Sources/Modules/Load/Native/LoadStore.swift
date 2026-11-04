import AppKit
import SwiftUI

/// Результат последнего действия «Остановить» — показывается баннером на экране.
struct LoadNotice: Identifiable {
    let id = UUID()
    var text: String
    var isError: Bool
}

/// Состояние модуля «Нагрузка».
///
/// - Пока модуль включён (`start`), раз в минуту пишется история — экран при этом может быть закрыт.
/// - Пока экран открыт (`screenAppeared`), данные обновляются каждые 3 с.
///
/// Вся работа — в `LoadEngine` (актор): сюда доезжают только готовые снимки.
@MainActor
final class LoadStore: ObservableObject {
    static let shared = LoadStore()

    static let liveInterval: Duration = .seconds(3)

    @Published private(set) var snapshot: LoadSnapshot?
    @Published private(set) var history: HistoryWindow?
    @Published private(set) var palette = LoadPalette()
    /// План остановки, ждущий подтверждения.
    @Published var pendingStop: StopPlan?
    @Published private(set) var stopRunning = false
    @Published var notice: LoadNotice?

    let engine: LoadEngine
    /// Вкладка «Фоновое»: агенты launchd и боты.
    let background = BackgroundStore()
    private var historyLoop: Task<Void, Never>?
    private var liveLoop: Task<Void, Never>?
    private var watchers = 0
    private var noticeTimer: Task<Void, Never>?

    /// Идёт ли запись истории.
    var isRunning: Bool { historyLoop != nil }

    private convenience init() { self.init(engine: LoadEngine()) }

    /// Свой движок — для проверок с отдельным файлом истории.
    init(engine: LoadEngine) {
        self.engine = engine
        background.onFinish = { [weak self] r in self?.backgroundFinished(r) }
    }

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
    }

    // MARK: Экран открыт / закрыт

    func screenAppeared() {
        watchers += 1
        guard liveLoop == nil else { return }
        liveLoop = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if Self.windowIsVisible() {
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
    private static func windowIsVisible() -> Bool {
        guard NSApp != nil else { return true }
        return NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    func apply(_ s: LoadSnapshot) {
        var p = palette
        p.update(from: s.map)
        palette = p
        snapshot = s
        background.update(from: s)
    }

    func refreshNow() {
        background.forget()
        Task {
            let s = await engine.refreshNow()
            apply(s)
        }
    }

    // MARK: Остановка

    func requestStop(process pid: Int32) {
        pendingStop = snapshot?.stopPlan(process: pid)
    }

    func requestStop(group id: String) {
        pendingStop = snapshot?.stopPlan(group: id)
    }

    func cancelStop() {
        guard !stopRunning else { return }
        pendingStop = nil
    }

    func confirmStop() {
        guard let plan = pendingStop, !stopRunning else { return }
        stopRunning = true
        Task {
            let result = await engine.execute(plan)
            stopRunning = false
            pendingStop = nil
            show(LoadNotice(text: result.message, isError: !result.ok))
            apply(await engine.measure())
        }
    }

    /// Действие над агентом или ботом выполнено: баннер и свежий замер (launchctl list обновится не сразу — второй замер позже).
    private func backgroundFinished(_ r: StopResult) {
        show(LoadNotice(text: r.message, isError: !r.ok))
        Task {
            apply(await engine.refreshNow())
            try? await Task.sleep(for: .seconds(1.5))
            apply(await engine.refreshNow())
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
