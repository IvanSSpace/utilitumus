import Foundation

// Половина связи, которая живёт только в утилите: состояние из хранилищ и разбор просьб от лаунчера.

extension BackgroundStore {
    var wireState: LoadBackgroundState {
        // Без полей, которые в связь не идут: так состояние после разбора равно исходному.
        var d = data
        for i in d.agents.indices { d.agents[i].targets = []; d.agents[i].loaded = false }
        for i in d.bots.indices { d.bots[i].spec = .none }
        var j = journal
        for i in j.indices { j[i].kind = ""; j[i].label = "" }
        return LoadBackgroundState(data: d, prompt: prompt, running: running, journal: j)
    }

    /// Просьба из связи: только агент и кнопка, которые модуль сам показал.
    fileprivate func handleRequest(label: String, verb: AgentVerb) -> String? {
        guard label.utf8.count <= LoadStore.maxIDBytes else { return "Непонятная команда" }
        guard !running else { return "Уже выполняется другое действие" }
        guard let agent = data.agents.first(where: { $0.label == label }), agent.verbs.contains(verb) else {
            return "Такого действия на экране уже нет — обнови экран"
        }
        request(agent, verb)
        return nil
    }

    fileprivate func handleRequest(id: String, verb: BotVerb) -> String? {
        guard id.utf8.count <= LoadStore.maxIDBytes else { return "Непонятная команда" }
        guard !running else { return "Уже выполняется другое действие" }
        guard let bot = data.bots.first(where: { $0.id == id }), bot.actions.contains(verb) else {
            return "Такого действия на экране уже нет — обнови экран"
        }
        request(bot, verb)
        return nil
    }

    fileprivate func handleCancel() -> String? {
        guard !running else { return "Уже выполняется другое действие" }
        cancel()
        return nil
    }

    fileprivate func handleConfirm(_ planID: UUID) -> String? {
        guard !running else { return "Уже выполняется другое действие" }
        guard pending?.id == planID else { return "Подтверждение устарело — попробуй ещё раз" }
        confirm(planID)
        return nil
    }
}

extension LoadStore {
    /// Длиннее настоящих меток launchd и id групп и ботов.
    static let maxIDBytes = 1024
    /// Экран открыт один; с запасом на вкладку, открытую ещё раз до закрытия прошлой.
    static let maxWatchers = 4

    var wireState: LoadState {
        LoadState(measure: measure?.forWire,
                  live: LoadLive(measureMillis: live.measureMillis, selfMemMB: live.selfMemMB, selfCPU: live.selfCPU),
                  history: history, stopPrompt: stopPrompt, stopRunning: stopRunning, notice: notice,
                  background: background.wireState)
    }

    /// Самое длинное настоящее действие — метка или id группы до `maxIDBytes` байт в JSON.
    static let maxActionBytes = maxIDBytes + 512

    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: LoadAction.self, limit: Self.maxActionBytes, state: { wireState }) { handle($0) }
    }

    /// Действие из связи: сначала проверка, изменения только после неё. Возвращает текст, если действие не выполнено.
    func handle(_ action: LoadAction) -> String? {
        switch action {
        case .refreshNow:
            refreshNow()
        case .screenAppeared:
            guard watchers < Self.maxWatchers else { return "Экран и так открыт" }
            screenAppeared()
        case .screenDisappeared:
            screenDisappeared()
        case .requestStop(let target):
            return handleRequestStop(target)
        case .cancelStop:
            guard !stopRunning else { return "Остановка уже идёт" }
            cancelStop()
        case .confirmStop(let planID):
            guard !stopRunning else { return "Остановка уже идёт" }
            guard pendingStop?.id == planID else { return "Подтверждение устарело — попробуй ещё раз" }
            confirmStop(planID)
        case .dismissNotice:
            dismissNotice()
        case .requestAgent(let label, let verb):
            return background.handleRequest(label: label, verb: verb)
        case .requestBot(let id, let verb):
            return background.handleRequest(id: id, verb: verb)
        case .cancelBackground:
            return background.handleCancel()
        case .confirmBackground(let planID):
            return background.handleConfirm(planID)
        case .setBackgroundTabOpen(let open):
            background.setTabOpen(open)
        case .reloadJournal:
            background.reloadJournal()
        }
        return nil
    }

    /// Цель должна быть на экране и быть тем же процессом; план строит только модуль, по своему замеру.
    private func handleRequestStop(_ target: LoadStopTarget) -> String? {
        guard !stopRunning else { return "Остановка уже идёт" }
        if case .group(let id) = target, id.utf8.count > Self.maxIDBytes { return "Непонятная команда" }
        guard let shown = measure, shown.offers(target) else { return "Этой строки на экране уже нет — обнови экран" }
        guard target.rows.allSatisfy({ latest?.procs[$0.pid]?.uniqueID == $0.uniqueID }) else {
            return "Процесс сменился — обнови экран"
        }
        guard let plan = stopPlan(for: target) else { return "Это остановить нельзя" }
        pendingStop = plan
        return nil
    }
}

extension LoadMeasure {
    init(_ s: LoadSnapshot) {
        self.init(timestamp: s.timestamp, host: s.host, memory: s.memory, groups: s.groups, map: s.map,
                  advice: s.advice, sessions: s.sessions, disk: s.disk)
    }
}

extension LiveStats {
    func update(from s: LoadSnapshot) {
        timestamp = s.timestamp
        measureMillis = s.measureMillis
        selfMemMB = s.selfMemMB
        selfCPU = s.selfCPU
    }
}
