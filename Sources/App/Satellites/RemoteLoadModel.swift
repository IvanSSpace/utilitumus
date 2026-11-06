import Combine
import Foundation

/// Вкладка «Фоновое», когда модуль ведёт утилита. Данные берёт у общей модели, действия шлёт через неё.
@MainActor
final class RemoteLoadBackground: LoadBackgroundModel {
    fileprivate unowned var owner: RemoteLoadModel!

    var data: BackgroundData { owner.state.background.data }
    var prompt: LoadBackgroundPrompt? { owner.state.background.prompt }
    var running: Bool { owner.state.background.running }
    var journal: [ActionLog.Entry] { owner.state.background.journal }

    func setTabOpen(_ open: Bool) { owner.send(.setBackgroundTabOpen(open)) }
    func reloadJournal() { owner.send(.reloadJournal) }
    func request(_ agent: AgentItem, _ verb: AgentVerb) { owner.send(.requestAgent(label: agent.label, verb: verb)) }
    func request(_ bot: BotItem, _ verb: BotVerb) { owner.send(.requestBot(id: bot.id, verb: verb)) }
    func cancel() { owner.send(.cancelBackground) }
    func confirm(_ planID: UUID) { owner.send(.confirmBackground(planID: planID)) }
}

/// Модель вкладки «Нагрузка», когда модуль ведёт утилита. Планов остановки у центра нет: подтверждение
/// называет утилите только id плана, который она сама показала. Замеры идут, пока открыта вкладка:
/// аренду экрана ведёт `RemoteModulePage`, поэтому `screenAppeared` и `screenDisappeared` здесь пустые.
@MainActor
final class RemoteLoadModel: RemoteModuleModel<LoadState, LoadAction>, LoadModel {
    let background = RemoteLoadBackground()
    let live = LiveStats()
    @Published private(set) var palette = LoadPalette()
    private var sub: AnyCancellable?

    init(id: String, canRead: @escaping () -> Bool, link: RemoteModuleLink? = nil) {
        super.init(id: id,
                   initial: LoadState(measure: nil, live: LoadLive(measureMillis: 0, selfMemMB: 0, selfCPU: nil), history: nil,
                                      stopPrompt: nil, stopRunning: false, notice: nil,
                                      background: LoadBackgroundState(data: BackgroundData(), prompt: nil, running: false, journal: [])),
                   link: link, canRead: canRead,
                   optimistic: { state, action in
                       // Закрыть окно подтверждения и баннер можно сразу; остальное показывается по ответу утилиты.
                       switch action {
                       case .cancelStop: state.stopPrompt = nil
                       case .dismissNotice: state.notice = nil
                       case .cancelBackground: state.background.prompt = nil
                       default: break
                       }
                   })
        background.owner = self
        sub = $state.dropFirst().sink { [weak self] new in
            guard let self else { return }
            live.update(from: new.live)
            if new.measure?.map != state.measure?.map, let map = new.measure?.map {
                var p = palette
                p.update(from: map)
                if p != palette { palette = p }
            }
            background.objectWillChange.send()
        }
    }

    var measure: LoadMeasure? { state.measure }
    var history: HistoryWindow? { state.history }
    var stopPrompt: LoadStopPrompt? { state.stopPrompt }
    var stopRunning: Bool { state.stopRunning }
    var notice: LoadNotice? { state.notice }

    func refreshNow() { send(.refreshNow) }
    func screenAppeared() {}
    func screenDisappeared() {}
    func requestStop(_ target: LoadStopTarget) { send(.requestStop(target)) }
    func cancelStop() { send(.cancelStop) }
    func confirmStop(_ planID: UUID) { send(.confirmStop(planID: planID)) }
    func dismissNotice() { send(.dismissNotice) }

    // Карточка та же, что у встроенного: память из последнего замера, которого без открытой вкладки нет.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        guard let memory = measure?.memory else { return DashState(text: "открой для замера", actionTitle: "Обновить") }
        return DashState(text: "память \(Fmt.gb(Double(memory.usedMB))) из \(Fmt.gb(Double(memory.totalMB))) ГБ", actionTitle: "Обновить")
    }

    override func performDashboardAction() -> Bool {
        refreshNow()
        return true
    }
}
