import Combine
import Foundation

/// Занята ли утилита работой, которую перезапуск оборвал бы. Утилита решает это сама в `mayRestart`, но наружу не сообщает;
/// то же самое центр читает из её состояния на экране. Новый вид занятости в `mayRestart` надо добавить и сюда.
/// Не разобралось (чужая версия) — считается свободной: иначе такую утилиту не обновить никогда. Без человека такую не
/// перезапускают, см. `readable`.
enum UpdateBusy {
    /// Центр понял состояние этой утилиты, то есть ответ `reason` чего-то стоит.
    static func readable(_ module: Module, state: Data) -> Bool {
        func can<T: Decodable>(_ type: T.Type) -> Bool { (try? JSONDecoder().decode(type, from: state)) != nil }
        switch module {
        case .voice: return can(VoiceState.self)
        case .awake: return can(AwakeState.self)
        case .load: return can(LoadState.self)
        case .stash: return can(StashState.self)
        case .bots: return can(BotsState.self)
        case .sound, .fans, .mixer, .mouse, .browser, .clipboard, .keyboard: return true
        }
    }

    static func reason(_ module: Module, state: Data) -> String? {
        func read<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: state) }
        switch module {
        case .voice:
            guard let voice = read(VoiceState.self) else { return nil }
            if voice.recording { return "идёт диктовка" }
            let loading = voice.models.contains {
                switch $0.status {
                case .downloading, .verifying: return true
                default: return false
                }
            }
            return loading ? "скачивается модель" : nil
        case .awake:
            return read(AwakeState.self)?.isActive == true ? "Mac сейчас не засыпает по твоей просьбе" : nil
        case .load:
            guard let load = read(LoadState.self) else { return nil }
            return load.stopRunning || load.background.running ? "выполняется остановка" : nil
        case .stash:
            return read(StashState.self)?.busy != nil ? "закрывает или возвращает программы" : nil
        case .bots:
            return read(BotsState.self)?.running == true ? "выполняется команда бота" : nil
        case .sound, .fans, .mixer, .mouse, .browser, .clipboard, .keyboard:
            return nil
        }
    }
}

/// Строка списка обновлений.
struct UpdateRow: Identifiable, Equatable {
    enum Phase: Equatable {
        case ready, queued, working, done
        case failed(String)
        case waiting(String)
        /// Версия центра, которая нужна.
        case needsHub(String)
    }

    let module: Module
    let from: String
    let to: String
    let notes: [String]
    let phase: Phase
    var id: Module { module }
}

/// «Обновить всё»: по одной утилите, через ту же установку, что кнопка в Сторе. Живёт отдельно от окна и листа:
/// их закрытие очередь не трогает. Только установленные: у остальных в Сторе обычное предложение поставить.
@MainActor
final class UpdateAll: ObservableObject {
    static let shared = UpdateAll()

    private enum Outcome: Equatable {
        case done(from: String, to: String)
        case failed(String)
        case waiting(String)
    }

    @Published var listShown = false
    @Published private(set) var queue: [Module] = []
    @Published private(set) var current: Module?
    @Published private var outcomes: [Module: Outcome] = [:]
    @Published private(set) var checking = false
    /// Сколько всего в этом проходе: для общего хода.
    @Published private(set) var total = 0

    /// Как часто спрашивать занятую утилиту. Обновляется после двух «свободна» подряд: не сразу за концом диктовки,
    /// когда следующая фраза уже на подходе.
    var recheckInterval: Duration = .seconds(30)
    /// Сколько висит «Обновлено», если список закрыт.
    var doneNoticeTime: Duration = .seconds(6)

    private let store = StoreModel.shared
    private let satellites = SatelliteRegistry.shared
    private var subs: [AnyCancellable] = []
    private var draining = false
    private var watching = false
    private var clearDone: Task<Void, Never>?
    /// Поставлены автообновлением: без плашки, без ожидания с опросом, со своими отказами и паузой после сбоя.
    private var silent: Set<Module> = []
    /// Центр выходит: нового не начинать.
    private var quitting = false
    private var auto: AutoUpdate { .shared }

    private init() {
        subs.append(satellites.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    // MARK: Что показать

    /// Флаг ставится до первой паузы: второе нажатие уже видит занятость.
    var running: Bool { current != nil || !queue.isEmpty }

    /// Идёт ли то, что запустил человек: только это видно на плашке.
    var visiblyRunning: Bool { (queue + (current.map { [$0] } ?? [])).contains { !silent.contains($0) } }

    /// Строки для плашки: без тех, что обновятся сами, иначе плашка мигала бы до и во время прохода.
    var noticeRows: [UpdateRow] {
        rows.filter { row in
            switch row.phase {
            case .ready: return !auto.willHandle(row.module)
            case .queued, .working: return !silent.contains(row.module)
            default: return true
            }
        }
    }

    /// «Нужен центр новее» в конце: с этими сейчас ничего не сделать.
    var rows: [UpdateRow] {
        let all = Module.allCases.compactMap(row)
        let held = all.filter { if case .needsHub = $0.phase { return true }; return false }
        return all.filter { !held.contains($0) } + held
    }

    private func row(_ module: Module) -> UpdateRow? {
        if case .done(let from, let to)? = outcomes[module] {
            return UpdateRow(module: module, from: from, to: to, notes: [], phase: .done)
        }
        guard let installed = satellites.entries[module]?.installedVersion else { return nil }
        if let held = satellites.needsNewerHub(module) {
            return UpdateRow(module: module, from: installed, to: held.version, notes: held.notes, phase: .needsHub(held.minHub))
        }
        guard satellites.hasUpdate(module), let app = satellites.catalogApp(module) else { return nil }
        let phase: UpdateRow.Phase
        if current == module {
            phase = .working
        } else if queue.contains(module) {
            phase = .queued
        } else {
            switch outcomes[module] {
            case .failed(let message)?: phase = .failed(message)
            case .waiting(let reason)?: phase = .waiting(reason)
            default: phase = .ready
            }
        }
        return UpdateRow(module: module, from: installed, to: app.version, notes: app.notes, phase: phase)
    }

    /// Что можно начать прямо сейчас: кнопка «Обновить всё (N)».
    var startable: [Module] {
        rows.compactMap { row in
            switch row.phase {
            case .ready, .failed: return row.module
            default: return nil
            }
        }
    }

    /// Сделано в этом проходе из `total`.
    var finished: Int { max(0, total - queue.count - (current == nil ? 0 : 1)) }

    func count(_ matches: (UpdateRow.Phase) -> Bool) -> Int { rows.filter { matches($0.phase) }.count }

    var doneCount: Int { count { $0 == .done } }
    var failedCount: Int { count { if case .failed = $0 { return true }; return false } }
    var waitingCount: Int { count { if case .waiting = $0 { return true }; return false } }

    // MARK: Действия

    func showList() {
        listShown = true
        if !running { Task { await check() } }
    }

    /// Закрытие листа ничего не отменяет. Готовые строки уходят, несделанное остаётся на виду в панели.
    func listClosed() {
        if !running { clearDoneRows() }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        await satellites.update()
        checking = false
    }

    /// Человек вернулся в центр, а каталог читали давно.
    func checkIfStale() {
        if let read = satellites.catalogReadAt, Date().timeIntervalSince(read) < 3600 { return }
        Task { await check() }
    }

    func start() {
        guard !running else { return }
        let modules = startable
        guard !modules.isEmpty else { return }
        clearDone?.cancel()
        outcomes = outcomes.filter { if case .waiting = $0.value { return true }; return false }
        total = modules.count
        queue = modules
        drain()
    }

    /// Проход автообновления: те же очередь и установка, что у кнопки. Только когда человек ничего не запустил.
    func startAutomatic(_ modules: [Module]) {
        guard !running, !quitting, !modules.isEmpty else { return }
        silent = Set(modules)
        for module in modules { outcomes[module] = nil }
        total = modules.count
        queue = modules
        drain()
    }

    /// Выход во время установки мог бы оставить утилиту остановленной: launchd загрузит её только при следующем входе.
    /// Очередь снимается, идущая установка отменяется: до остановки утилиты ничего не тронуто, после неё работает откат.
    /// Срок на случай зависшей связи: окно выхода не должно висеть вечно.
    func stopForQuit(deadline: TimeInterval = 15, done: @escaping @MainActor () -> Void) {
        quitting = true
        queue.removeAll()
        store.cancelOperations()
        // Таймер, а не задача: `terminate` мог быть вызван из блока главной очереди (`Updater.relaunch`), и тогда задачи главного
        // актора стоят до конца выхода. Срок сработает и в этом случае.
        let end = Date().addingTimeInterval(deadline)
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !self.installing || Date() >= end else { return }
                timer.invalidate()
                done()
                // Обычно сюда уже не дойти: процесс завершился внутри `done`.
                self.quitting = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Идёт ли что-то через установщик, в том числе кнопка в Сторе и переход при запуске.
    var installing: Bool { running || Module.allCases.contains(where: store.isOperating) }

    func retry(_ module: Module) {
        guard current != module, !queue.contains(module) else { return }
        silent.remove(module)
        clearDone?.cancel()
        outcomes[module] = nil
        if !running { total = 0; clearDoneRows() }
        enqueue(module)
    }

    // MARK: Очередь

    private func enqueue(_ module: Module) {
        guard !quitting else { return }
        total += 1
        queue.append(module)
        drain()
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        // Задача не привязана к виду: закрытие окна её не касается.
        Task {
            while !queue.isEmpty {
                let module = queue.removeFirst()
                current = module
                await update(module)
                current = nil
            }
            draining = false
            silent = []
            passFinished()
        }
    }

    private func update(_ module: Module) async {
        // Кнопка в Сторе, удаление или переход успели раньше: подождать и посмотреть, что осталось делать.
        while store.isOperating(module) { try? await Task.sleep(for: .seconds(0.25)) }
        guard let installed = satellites.entries[module]?.installedVersion,
              satellites.hasUpdate(module), let app = satellites.catalogApp(module) else {
            outcomes[module] = nil
            return
        }
        let automatic = silent.contains(module)
        // Настройку могли выключить, а человек мог успеть обновить кнопкой, пока шла очередь.
        if automatic, !auto.willHandle(module) { return }
        // Занята она или нет, не понять: перезапустить такую может только человек.
        if automatic, await satellites.stateUnreadable(module) {
            auto.leaveForPerson(module, version: app.version)
            return
        }
        // Скачивать незачем, если всё равно ждать. Перед самой остановкой установщик спросит ещё раз.
        if let reason = await satellites.busyReason(module) {
            if !automatic { wait(module, reason) }
            return
        }
        if quitting { return }
        let failure = automatic
            ? await store.updateFromQueue(module, app: app, checkStaged: AutoUpdatePolicy.checkStaged)
            : await store.updateFromQueue(module, app: app)
        if automatic, let failure, auto.handledQuietly(failure, module: module, app: app) { return }
        switch failure {
        case nil:
            if satellites.hasUpdate(module) {
                outcomes[module] = .failed("Версия не сменилась, попробуй ещё раз")
                if automatic { auto.noteFailure(module, version: app.version) }
            } else if automatic {
                auto.noteUpdated(module, from: installed, to: app.version)
            } else {
                outcomes[module] = .done(from: installed, to: app.version)
            }
        case SatelliteInstallError.busy(let reason)?:
            wait(module, reason)
        case let error? where error is CancellationError || (error as? URLError)?.code == .cancelled:
            outcomes[module] = .failed("Обновление отменено")
            if automatic { auto.noteFailure(module, version: app.version) }
        case let error?:
            outcomes[module] = .failed(StoreModel.failureMessage(error, fallback: "Не удалось обновить"))
            if automatic { auto.noteFailure(module, version: app.version) }
        }
    }

    private func wait(_ module: Module, _ reason: String) {
        outcomes[module] = .waiting(reason)
        watchWaiting()
    }

    /// Опрос только пока есть кто ждёт, и только пока центр запущен. После перезапуска это снова обычное обновление в списке.
    private func watchWaiting() {
        guard !watching else { return }
        watching = true
        Task {
            var free: Set<Module> = []
            while true {
                let waiting = rows.compactMap { row -> Module? in
                    if case .waiting = row.phase { return row.module }
                    return nil
                }
                // Модуль удалили или обновили кнопкой: ждать больше нечего.
                for module in outcomes.keys where !waiting.contains(module) {
                    if case .waiting = outcomes[module] { outcomes[module] = nil }
                }
                if waiting.isEmpty { break }
                try? await Task.sleep(for: recheckInterval)
                for module in waiting where outcomes[module] != nil && !store.isOperating(module) {
                    if let reason = await satellites.busyReason(module) {
                        free.remove(module)
                        if case .waiting = outcomes[module] { outcomes[module] = .waiting(reason) }
                    } else if !free.insert(module).inserted, case .waiting = outcomes[module] {
                        free.remove(module)
                        outcomes[module] = nil
                        if !running { total = 0; clearDoneRows() }
                        enqueue(module)
                    }
                }
            }
            watching = false
        }
    }

    private func passFinished() {
        // Успех не требует внимания: короткая отметка и тишина. Открытый список покажет итог, пока его не закроют.
        guard !listShown, failedCount == 0, waitingCount == 0 else { return }
        clearDone = Task {
            try? await Task.sleep(for: doneNoticeTime)
            if !Task.isCancelled, !listShown, !running { clearDoneRows() }
        }
    }

    #if KIT_TEST_DEFAULTS
    /// Стенд начинает сценарий с чистого листа.
    func forgetForStand(_ module: Module) { outcomes[module] = nil }
    #endif

    private func clearDoneRows() {
        outcomes = outcomes.filter { if case .done = $0.value { return false }; return true }
    }
}
