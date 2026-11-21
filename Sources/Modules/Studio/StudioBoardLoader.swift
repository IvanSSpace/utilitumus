import Foundation

/// Опрос Студии и действия с экрана. Работает в утилите: токен знает только `StudioRunner`, отсюда он не виден.
/// Опрос идёт, пока экран открыт и сервер работает, и ровно столько: закрыли экран или сервер ушёл — задача снята.
@MainActor
final class StudioBoardLoader {
    private let runner: StudioRunner
    /// Пауза между опросами `/api/state`. Страница опрашивает раз в 4 с, мы так же.
    var interval: TimeInterval
    /// Дело выбранной утилиты перечитывается на каждом третьем опросе, как у страницы.
    static let detailEvery = 3

    private var task: Task<Void, Never>?
    private var tick = 0
    private var noticeSeq = 0
    private var selected: String?
    /// Значки живут, пока запущена утилита: сервер отдаёт их из своего кэша, они меняются раз в выпуск.
    private var icons: [String: Data] = [:]
    private var iconTried = Set<String>()
    private var working = Set<String>()
    /// Опрос видел снимок хотя бы раз.
    private(set) var polls = 0

    init(runner: StudioRunner, interval: TimeInterval = 4) {
        self.runner = runner
        self.interval = interval
    }

    var isPolling: Bool { task != nil }

    // MARK: Опрос

    /// Экран открыт, сервер работает: опрашивать. Повторный вызов ничего не меняет.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let pause = self.interval
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        tick = 0
    }

    /// Прочитать состояние и, по расписанию, дело выбранной утилиты.
    func refresh() async {
        switch await runner.api("GET", "/api/state") {
        case .failure(let failure):
            runner.updateBoard { $0.problem = failure.line }
            return
        case .success(let data):
            guard let parsed = StudioBoardParser.state(from: data) else {
                runner.updateBoard { $0.problem = "Студия ответила непонятно" }
                return
            }
            polls += 1
            let shown = selected
            runner.updateBoard {
                $0.units = parsed.units
                $0.hubTasks = parsed.hubTasks
                $0.orcaError = parsed.orcaError
                $0.problem = nil
                $0.icons = icons.filter { id, _ in parsed.units.contains { $0.id == id } }
                $0.selected = shown.flatMap { id in parsed.units.contains { $0.id == id } ? id : nil }
                $0.working = working.sorted()
            }
            if let shown, parsed.units.contains(where: { $0.id == shown }) {
                if tick % Self.detailEvery == 0 { await loadDetail(shown) }
            } else if shown != nil {
                selected = nil
            }
            tick += 1
            await loadIcons(parsed.units)
        }
    }

    /// Значок каждой утилиты берётся один раз (ошибка тоже считается попыткой: плашка с буквой остаётся).
    private func loadIcons(_ units: [StudioUnit]) async {
        for unit in units where unit.hasIcon && !iconTried.contains(unit.id) {
            iconTried.insert(unit.id)
            guard case .success(let png) = await runner.api("GET", "/icons/\(unit.id).png", maxBytes: 512 * 1024),
                  let small = StudioBoardParser.icon(from: png) else { continue }
            icons[unit.id] = small
            runner.updateBoard { $0.icons[unit.id] = small }
        }
    }

    /// Дела, которые сейчас грузятся: частый выбор с провода не плодит запросы к серверу.
    private var loadingDetail = Set<String>()

    private func loadDetail(_ id: String) async {
        guard loadingDetail.insert(id).inserted else { return }
        defer { loadingDetail.remove(id) }
        guard case .success(let data) = await runner.api("GET", "/api/unit/\(id)", maxBytes: 256 * 1024),
              let detail = StudioBoardParser.detail(from: data, id: id), selected == id else { return }
        runner.updateBoard { $0.detail = detail }
    }

    /// Утилита выбрана экраном (nil — снята). Дело подгружается сразу, не дожидаясь опроса.
    func select(_ id: String?) {
        selected = id
        runner.updateBoard {
            $0.selected = id
            if $0.detail?.id != id { $0.detail = nil }
        }
        if let id { Task { await loadDetail(id) } }
    }

    /// Сервер ушёл или модуль выключили: всё, что знали, забыть.
    func reset() {
        stop()
        selected = nil
        loadingDetail = []
        icons = [:]
        iconTried = []
        working = []
        polls = 0
    }

    // MARK: Действия

    private func notify(_ text: String, error: Bool) {
        noticeSeq += 1
        let notice = StudioNotice(id: noticeSeq, text: text, isError: error)
        runner.updateBoard { $0.notice = notice }
    }

    private func setWorking(_ key: String, _ on: Bool) {
        if on { working.insert(key) } else { working.remove(key) }
        let now = working.sorted()
        runner.updateBoard { $0.working = now }
    }

    /// Действие: проверка на месте (текст отказа или nil), сам вызов идёт в фоне, итог приходит уведомлением в снимке.
    func perform(_ action: StudioAction) -> String? {
        guard runner.state.phase == .running else { return "Студия не запущена" }
        switch action {
        case .openSession(let id): return unitCall(id, "open", key: id)
        case .stand(let id): return unitCall(id, "stand", key: id)
        case .release(let id): return unitCall(id, "release", key: id)
        case .rotate(let id): return unitCall(id, "rotate", key: id)
        case .task(let id, let raw): return textCall(id, "task", raw)
        case .handToHub(let id, let raw): return textCall(id, "hub", raw)
        case .commitCases: return call("POST", "/api/commit", body: nil, key: "commit", unit: nil, messageKey: "message")
        default: return "Непонятная команда"
        }
    }

    private func known(_ id: String) -> Bool {
        StudioUnitID.isValid(id) && (runner.state.board?.unit(id) != nil)
    }

    private func unitCall(_ id: String, _ verb: String, key: String) -> String? {
        guard known(id) else { return "Нет такой утилиты" }
        return call("POST", "/api/unit/\(id)/\(verb)", body: nil, key: key, unit: id, messageKey: "message")
    }

    private func textCall(_ id: String, _ verb: String, _ raw: String) -> String? {
        guard known(id) else { return "Нет такой утилиты" }
        guard let text = StudioText.task(raw) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Напиши задачу"
                : "Задача длиннее \(StudioText.maxLength) знаков"
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return "Задача не ушла" }
        return call("POST", "/api/unit/\(id)/\(verb)", body: body, key: id, unit: id, messageKey: "message")
    }

    /// Одно действие на утилиту сразу: второе нажатие, пока первое идёт, отклоняется (сервер всё равно ставит их в очередь).
    private func call(_ method: String, _ path: String, body: Data?, key: String, unit: String?, messageKey: String) -> String? {
        guard !working.contains(key) else { return "Это действие ещё идёт" }
        setWorking(key, true)
        Task { [weak self] in
            guard let self else { return }
            // Действия мастера ждут Orca до двух с половиной минут (подъём, `terminal wait`).
            let result = await self.runner.api(method, path, body: body, maxBytes: 16 * 1024, timeout: 180)
            self.setWorking(key, false)
            switch result {
            case .success(let data):
                self.notify(StudioBoardParser.message(from: data, key: messageKey) ?? "Готово", error: false)
            case .failure(let failure):
                self.notify(failure.line, error: true)
            }
            // Дела и очередь могли поменяться: перечитываем, не ждём очередного опроса.
            if self.runner.state.phase == .running {
                await self.refresh()
                if let unit, self.selected == unit { await self.loadDetail(unit) }
            }
        }
        return nil
    }
}
