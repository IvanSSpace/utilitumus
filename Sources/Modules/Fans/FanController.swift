import Foundation
import AppKit

enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto, constant, sensor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Авто"
        case .constant: return "Константа"
        case .sensor: return "По датчику"
        }
    }
}

enum SensorSource: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu
    var id: String { rawValue }
    var title: String { self == .cpu ? "Процессор" : "Видеокарта" }
}

/// Настройка одного вентилятора — как в Macs Fan Control: система сама,
/// фиксированные обороты, или линейно от температуры датчика.
struct FanConfig: Codable, Equatable {
    // По умолчанию — «По датчику» 50–80 °C: выбор пользователя как оптимальный для новых установок.
    // Пока помощник не установлен, вентиляторами всё равно управляет macOS.
    var mode: FanMode = .sensor
    /// Для `.constant`. 0 — ещё не выбирали, UI подставит минимум вентилятора.
    var rpm: Double = 0
    var sensor: SensorSource = .cpu
    /// Для `.sensor`: до `fromTemp` — минимум оборотов, от `toTemp` — максимум,
    /// между ними линейно.
    // 50/80 — выбор пользователя (2026-11-05): тише в простое не нужно, к 80 °C — максимум.
    var fromTemp: Double = 50
    var toTemp: Double = 80
}

struct FanReading: Identifiable, Equatable {
    let index: Int
    let actual: Double
    let min: Double
    let max: Double
    let isManual: Bool
    /// Цель в ручном режиме (F<n>Tg); в «Авто» система держит тут своё.
    let target: Double
    var id: Int { index }
    /// Ручной режим, а до цели ещё далеко: с нуля вентилятор выходит на
    /// максимум за 8–15 с — показываем, что он раскручивается, а не «не работает».
    var isSpinningUp: Bool { isManual && actual < target - 300 }
}

struct SensorReading: Identifiable, Equatable {
    let key: String
    let value: Double
    var id: String { key }
}

/// Читает вентиляторы и датчики из SMC раз в 2 секунды и приводит обороты
/// к настройкам через root-помощник. Всё на main thread: чтение SMC — десятки
/// микросекунд, сам помощник запускается в фоне.
@MainActor
final class FanController: ObservableObject {
    static let shared = FanController()

    /// Выше этой температуры процессора все вентиляторы отдаются системе,
    /// что бы ни стояло в настройках. Возврат — когда остынет ниже `safetyRelease`.
    static let safetyTrip = 95.0
    static let safetyRelease = 85.0

    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var cpuSensors: [SensorReading] = []
    @Published private(set) var gpuSensors: [SensorReading] = []
    @Published private(set) var conflictingApp: NSRunningApplication?
    @Published private(set) var safetyTripped = false
    @Published private(set) var lastError: String?
    /// «Полная мощность»: все вентиляторы на максимум поверх их настроек.
    /// Настройки не трогаем — выключил, и каждый вернулся к своему режиму.
    @Published var fullPower = false {
        didSet {
            Self.log("fullPower → \(fullPower)")
            lastSent = [:]
            scheduleApply()
        }
    }
    @Published var configs: [FanConfig] {
        didSet {
            // Слайдер шлёт событие на каждый пиксель: без изменений — ни записи, ни публикации.
            guard configs != oldValue else { return }
            Self.log("настройки → " + configs.map { "\($0.mode.rawValue)/\(Int($0.rpm))" }.joined(separator: ", "))
            schedulePersist()
            // Новая настройка применяется сразу, без гистерезиса.
            lastSent = [:]
            scheduleApply()
        }
    }

    var cpuMax: Double? { cpuSensors.map(\.value).max() }
    var gpuMax: Double? { gpuSensors.map(\.value).max() }

    private static let configsKey = "FanConfigs"
    private static let conflictingBundleIDs: Set<String> = ["com.crystalidea.macsfancontrol"]

    private let smc = SMC()
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var timer: Timer?
    private var powerObservers: [NSObjectProtocol] = []
    /// Мак спит или экран погас — им никто не пользуется: вентиляторы отдаём
    /// системе. Иначе ручной режим держит обороты и во сне — SMC сам их не сбросит.
    private var asleep = false
    private var screensAsleep = false
    private var isIdle: Bool { asleep || screensAsleep }
    /// «По датчику»: вентиляторы, которые сейчас на кривой. Ниже нижней
    /// температуры отдаём их системе (она умеет их останавливать); с запасом
    /// 3 °C, чтобы на границе не дёргать режим туда-сюда.
    private var sensorEngaged: Set<Int> = []
    /// Между start() и stop(). Отложенные tick/apply после stop() ничего не делают,
    /// иначе они снова взяли бы вентиляторы под ручное управление.
    private var isRunning = false
    /// Обновление подменяет бандл: после подмены служба может не принять этот процесс, и взятый в ручной режим вентилятор
    /// вернуть будет нечем. Живёт до выхода, переживает stop() и start(): снимает только `resumeAfterFailedUpdate`.
    private var holdingForUpdate = false
    /// Прежний setuid-помощник уже просили вернуть «Авто» за этот запуск модуля.
    private var legacyRestoreTried = false
    /// Последняя отправленная помощником цель по вентиляторам: от неё считается гистерезис.
    private var lastSent: [Int: (rpm: Double, at: Date)] = [:]
    /// Сглаженные температуры для кривой «По датчику»; безопасность смотрит на сырые.
    private var cpuSmoother = TempSmoother()
    private var gpuSmoother = TempSmoother()
    private var smoothedCPU: Double?
    private var smoothedGPU: Double?
    private var lastSmoothAt = Date.distantPast
    private var pendingApply: DispatchWorkItem?
    private var pendingPersist: DispatchWorkItem?
    /// Вентиляторы, для которых команда помощнику ещё выполняется.
    private var inFlight: Set<Int> = []
    /// Команды помощнику — строго по одной и по порядку: параллельные «макс» и
    /// «авто» для одного вентилятора доходили до SMC в случайном порядке.
    private nonisolated static let helperQueue = DispatchQueue(label: "utilitumus.fans.helper")

    private init() {
        if let data = Kit.defaults.data(forKey: Self.configsKey),
           let saved = try? JSONDecoder().decode([FanConfig].self, from: data) {
            // Прежние умолчания (50/85, 70/90), которые пользователь не трогал, — на новые 50/80.
            configs = saved.map { c in
                guard (c.fromTemp == 50 && c.toTemp == 85) || (c.fromTemp == 70 && c.toTemp == 90) else { return c }
                var n = c; n.fromTemp = 50; n.toTemp = 80; return n
            }
            if configs != saved { persist() }
        } else {
            configs = []
        }
    }

    func start() {
        guard let smc, !isRunning else { return }
        isRunning = true
        FanHelperInstaller.shared.moduleRunning = true
        FanHelperInstaller.shared.refresh()
        // Набор датчиков у каждого чипа свой — находим, какие есть, один раз.
        let suffixes = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        func discover(_ prefixes: [String]) -> [String] {
            prefixes.flatMap { p in suffixes.map { "\(p)\($0)" } }
                .filter { key in smc.float(key).map(Self.isPlausible) ?? false }
        }
        cpuKeys = discover(["Tp0", "Tp1"])
        gpuKeys = discover(["Tg0", "Tg1"])

        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (FanController) -> Void) {
            powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(FanController.shared) }
            })
        }
        // Перед сном — «Авто» синхронно: после засыпания приложение уже ничего
        // не сможет отправить, а ручной режим SMC держит и во сне.
        observe(NSWorkspace.willSleepNotification) { me in
            Self.log("сон → вентиляторы системе")
            me.asleep = true
            me.restoreAutoBlocking()
        }
        // После сна SMC мог сбросить режимы — выставить сразу, не дожидаясь такта.
        observe(NSWorkspace.didWakeNotification) { me in
            Self.log("пробуждение")
            me.asleep = false
            FanHelperInstaller.shared.refresh()
            me.tick()
        }
        observe(NSWorkspace.screensDidSleepNotification) { me in
            Self.log("экран погас → вентиляторы системе")
            me.screensAsleep = true
            me.apply()
        }
        observe(NSWorkspace.screensDidWakeNotification) { me in
            Self.log("экран включился")
            me.screensAsleep = false
            me.tick()
        }

        GameModeController.shared.start()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in FanController.shared.tick() }
        }
    }

    /// Вызывается при выходе из приложения: отдать вентиляторы системе.
    /// Синхронно — иначе процесс завершится раньше, чем команды уйдут, но не дольше `quitBudget` на все вентиляторы.
    func restoreAutoBlocking() {
        if pendingPersist != nil { persist() }
        guard FanHelperInstaller.shared.status != .notInstalled, conflictingApp == nil, let smc else { return }
        // Команда в пути могла быть `set`: в SMC её ещё не видно, а вентилятор она возьмёт в ручной режим.
        let releasing = fans.map(\.index).filter { inFlight.contains($0) || smc.uint8("F\($0)Md") == 1 }
        // Службы при setuid-установке нет, XPC ничего бы не дал. Убрать вместе с поддержкой setuid.
        if FanHelperInstaller.shared.status == .outdated, FanHelperInstaller.shared.hasLegacySetuid {
            LegacyFanHelper.restoreAutoWithin(fans: releasing, path: FanHelperInstaller.installedPath, on: Self.helperQueue) { error in
                Self.log("прежний помощник auto \(releasing) → \(error ?? "ok")")
            }
            return
        }
        // Через ту же очередь — после уже отправленных команд, а не наперегонки с ними.
        FanHelperClient.sendAll(releasing.map { .auto($0) }, on: Self.helperQueue) { Self.logHelper($0, $1) }
    }

    /// Выключение модуля или выход: вентиляторы системе, опрос и управление
    /// прекращаются. Повторный вызов и вызов без start() ничего не делают.
    func stop() {
        guard isRunning else { return }
        persist()
        GameModeController.shared.stop()
        // Сначала вернуть «Авто» (синхронно, после уже отправленных команд),
        // и только потом гасить цикл: иначе нечем будет проверить, что вернулось.
        restoreAutoBlocking()
        FanHelperInstaller.shared.moduleRunning = false
        isRunning = false
        legacyRestoreTried = false
        timer?.invalidate()
        timer = nil
        powerObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        powerObservers = []
        asleep = false
        screensAsleep = false
        sensorEngaged = []
        lastSent = [:]
        cpuSmoother.reset(); gpuSmoother.reset()
        smoothedCPU = nil; smoothedGPU = nil
        pendingApply?.cancel()
        pendingApply = nil
        // «Полная мощность» не должна сама включиться при возврате модуля.
        fullPower = false
        fans = []
        cpuSensors = []
        gpuSensors = []
        conflictingApp = nil
        safetyTripped = false
        lastError = nil
    }

    /// Перед подменой бандла: отдать вентиляторы системе и больше ими не управлять.
    /// Сам `restoreAutoBlocking` флагу не подчиняется: он только отпускает вентиляторы, и при выходе это последний шанс.
    func holdForUpdate() {
        Self.log("обновление → вентиляторы системе, управление на паузе")
        holdingForUpdate = true
        restoreAutoBlocking()
    }

    /// Подмена не удалась, приложение работает дальше: управление возвращается сразу, не дожидаясь такта.
    func resumeAfterFailedUpdate() {
        Self.log("обновление не удалось → управление снова включено")
        holdingForUpdate = false
        tick()
    }

    /// Режим «Максимум в играх» включился или выключился.
    func gameModeChanged() { lastSent = [:]; scheduleApply() }

    func setAllAuto() {
        fullPower = false
        GameModeController.shared.cancelCurrent()
        configs = configs.map { var c = $0; c.mode = .auto; return c }
    }

    // MARK: - Цикл

    /// Снимок SMC за один такт. Читается на фоновой очереди: десятки ключей —
    /// это десятки системных вызовов, на главном потоке они давали заметный рывок.
    private struct Sample {
        var count: Int
        var fans: [FanReading]
        var cpu: [SensorReading]
        var gpu: [SensorReading]
    }

    private nonisolated static let readQueue = DispatchQueue(label: "utilitumus.fans.read", qos: .userInitiated)
    private var reading = false
    /// Во время чтения попросили ещё одно (например, после команды помощнику):
    /// то чтение могло начаться до команды, поэтому после него читаем заново.
    private var rereadRequested = false

    private nonisolated static func sample(_ smc: SMC, cpuKeys: [String], gpuKeys: [String]) -> Sample {
        let count = Int(smc.uint8("FNum") ?? 0)
        let fans: [FanReading] = (0..<count).compactMap { i in
            guard let actual = smc.float("F\(i)Ac"),
                  let lo = smc.float("F\(i)Mn"),
                  let hi = smc.float("F\(i)Mx") else { return nil }
            return FanReading(index: i, actual: Double(actual), min: Double(lo), max: Double(hi),
                              isManual: smc.uint8("F\(i)Md") == 1,
                              target: Double(smc.float("F\(i)Tg") ?? 0))
        }
        func read(_ keys: [String]) -> [SensorReading] {
            keys.compactMap { key in
                guard let v = smc.float(key).map(Double.init), isPlausible(Float(v)) else { return nil }
                return SensorReading(key: key, value: v)
            }
        }
        return Sample(count: count, fans: fans, cpu: read(cpuKeys), gpu: read(gpuKeys))
    }

    private func tick() {
        guard isRunning, let smc else { return }
        guard !reading else { rereadRequested = true; return }
        reading = true
        let cpuKeys = self.cpuKeys, gpuKeys = self.gpuKeys
        Self.readQueue.async {
            let s = Self.sample(smc, cpuKeys: cpuKeys, gpuKeys: gpuKeys)
            Task { @MainActor in FanController.shared.finishTick(s) }
        }
    }

    private func finishTick(_ s: Sample) {
        reading = false
        defer {
            if rereadRequested { rereadRequested = false; tick() }
        }
        // Модуль выключили, пока шло чтение, — снимок устарел.
        guard isRunning else { return }

        if s.fans != fans { fans = s.fans }
        if configs.count < s.count {
            configs += Array(repeating: FanConfig(), count: s.count - configs.count)
        }
        if s.cpu != cpuSensors { cpuSensors = s.cpu }
        if s.gpu != gpuSensors { gpuSensors = s.gpu }

        // Внеочередное чтение после команды помощнику в среднее не берём.
        let now = Date()
        if now.timeIntervalSince(lastSmoothAt) >= 1.5 {
            lastSmoothAt = now
            smoothedCPU = cpuMax.map { cpuSmoother.add($0) }
            smoothedGPU = gpuMax.map { gpuSmoother.add($0) }
        }

        if let cpu = cpuMax {
            if cpu >= Self.safetyTrip { safetyTripped = true }
            else if cpu < Self.safetyRelease { safetyTripped = false }
        }

        let conflict = Self.conflictingBundleIDs.lazy
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .first
        if conflict?.processIdentifier != conflictingApp?.processIdentifier { conflictingApp = conflict }

        apply()
    }

    private func scheduleApply() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in FanController.shared.apply() } }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Сверяет нужное состояние с тем, что реально стоит в SMC, и правит
    /// расхождения. Сверка с железом, а не с памятью «что уже отправили»:
    /// режим мог сбросить сон/пробуждение, чужая программа, перезапуск
    /// приложения — такое расхождение само больше не исправилось бы.
    private func apply() {
        // Пока вентиляторами рулит другая программа — не воюем с ней.
        guard isRunning, !holdingForUpdate, conflictingApp == nil, let smc else { return }
        guard FanHelperInstaller.shared.status == .ready else {
            if FanHelperInstaller.shared.status == .outdated { releaseStuckFans(smc) }
            return
        }
        for fan in fans where fan.index < configs.count && !inFlight.contains(fan.index) {
            let i = fan.index
            let desired = desiredRPM(for: fan, config: configs[i])
            let isManual = smc.uint8("F\(i)Md") == 1
            let target = Double(smc.float("F\(i)Tg") ?? 0)
            let command: FanHelperClient.Command
            if let rpm = desired {
                // Дрожание датчика на пару градусов не стоит записи в SMC.
                guard !isManual || abs(target - rpm) >= 50 else { continue }
                // Шум датчика качает цель на десятки об/мин, а команда помощнику дорога:
                // в «По датчику» шлём не чаще порога/таймера. Остальное — сразу.
                let urgent = configs[i].mode != .sensor || fullPower || GameModeController.shared.isActive
                    || safetyTripped || !isManual
                let last = lastSent[i]
                guard FanGate.shouldSend(desired: rpm, lastSent: last?.rpm, lastSentAt: last?.at,
                                         now: Date(), urgent: urgent) else { continue }
                lastSent[i] = (rpm.rounded(), Date())
                command = .set(i, Double(Int(rpm)))
            } else {
                lastSent[i] = nil
                guard isManual else { continue }
                command = .auto(i)
            }
            Self.log("fan\(i) Md=\(smc.uint8("F\(i)Md").map(String.init) ?? "?") Tg=\(Int(target)) Ac=\(Int(fan.actual)) хотим=\(desired.map { String(Int($0)) } ?? "авто") fullPower=\(fullPower)")
            send(command, fan: i)
        }
    }

    private func send(_ command: FanHelperClient.Command, fan i: Int) {
        inFlight.insert(i)
        Self.helperQueue.async {
            let error = Self.runHelper(command)
            Task { @MainActor in
                let me = FanController.shared
                me.inFlight.remove(i)
                me.lastError = error
                // Перечитать SMC сразу: экран не ждёт такта (до 2 с казалось,
                // что вентилятор не включился), а если настройку успели
                // поменять, пока шла команда, — tick тут же сверит заново.
                if error == nil { me.tick() }
            }
        }
    }

    /// Помощник устарел, управлять нельзя, но застрявший ручной режим надо вернуть: приложение могло упасть
    /// с вентилятором в ручном режиме, и больше его никто не отпустит.
    private func releaseStuckFans(_ smc: SMC) {
        if FanHelperInstaller.shared.hasLegacySetuid {
            // Один раз за запуск: прежний помощник — лишний процесс с root, и это только починка после сбоя.
            guard !legacyRestoreTried, !fans.isEmpty else { return }
            legacyRestoreTried = true
            let manual = fans.map(\.index).filter { smc.uint8("F\($0)Md") == 1 }
            guard !manual.isEmpty else { return }
            let path = FanHelperInstaller.installedPath
            Self.helperQueue.async {
                let error = LegacyFanHelper.restoreAuto(fans: manual, path: path)
                Self.log("прежний помощник auto \(manual) → \(error ?? "ok")")
                Task { @MainActor in FanController.shared.tick() }
            }
            return
        }
        guard FanHelperInstaller.shared.serviceAnswered else { return }
        for fan in fans where !inFlight.contains(fan.index) && smc.uint8("F\(fan.index)Md") == 1 {
            send(.auto(fan.index), fan: fan.index)
        }
    }

    /// nil — отдать системе.
    private func desiredRPM(for fan: FanReading, config: FanConfig) -> Double? {
        // Маком не пользуются — никакие режимы не держат вентиляторы.
        if isIdle { return nil }
        // Максимум охлаждает сильнее системы — перегрев ему не помеха.
        if fullPower || GameModeController.shared.isActive { return fan.max }
        if safetyTripped { return nil }
        switch config.mode {
        case .auto:
            return nil
        case .constant:
            return min(max(config.rpm, fan.min), fan.max)
        case .sensor:
            guard let temp = (config.sensor == .cpu ? (smoothedCPU ?? cpuMax) : (smoothedGPU ?? gpuMax)),
                  config.toTemp > config.fromTemp else { return nil }
            // Холодно — решает система: в простое она останавливает вентиляторы,
            // а минимум кривой держал бы их крутиться всегда.
            if temp >= config.fromTemp { sensorEngaged.insert(fan.index) }
            else if temp < config.fromTemp - 3 { sensorEngaged.remove(fan.index) }
            guard sensorEngaged.contains(fan.index) else { return nil }
            let t = min(max((temp - config.fromTemp) / (config.toTemp - config.fromTemp), 0), 1)
            return fan.min + (fan.max - fan.min) * t
        }
    }

    // MARK: - Вспомогательное

    private nonisolated static func isPlausible(_ t: Float) -> Bool { t > 0 && t < 150 }

    /// Запись в UserDefaults — не на каждое движение слайдера, а когда он затих.
    private func schedulePersist() {
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persist() }
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persist() {
        pendingPersist?.cancel()
        pendingPersist = nil
        if let data = try? JSONEncoder().encode(configs) {
            Kit.defaults.set(data, forKey: Self.configsKey)
        }
    }

    /// Возвращает текст ошибки или nil при успехе.
    private nonisolated static func runHelper(_ command: FanHelperClient.Command) -> String? {
        let error = FanHelperClient.send(command)
        logHelper(command, error)
        return error
    }

    private nonisolated static func logHelper(_ command: FanHelperClient.Command, _ error: String?) {
        log("helper \(command) → \(error ?? "ok")")
    }

    /// Журнал управления вентиляторами: что и когда отправили, что увидели в SMC.
    /// ~/Library/Logs/Utilitumus/fans.log — разбирать «иногда не включается».
    nonisolated static func log(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utilitumus/fans.log")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        let data = Data("\(stamp) \(line)\n".utf8)
        // Журнал не растёт бесконечно: больше 512 КБ — начать заново.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        // Каталог 0700, файл 0600 — журнал не должны читать другие пользователи мака.
        PrivateLog.prepare(file: url)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        }
    }
}
