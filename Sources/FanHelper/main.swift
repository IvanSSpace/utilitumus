import Foundation
import os

// utilitumus-fan — единственный кусок Utilitumus, работающий от root: писать в SMC может только root.
// Это служба launchd в системном домене, её запускает launchd по первому подключению. setuid нет,
// поэтому обычный запуск бинарника прав не даёт. Кто подключается, проверяет сам XPC по подписи
// (FanLink.listenerRequirement): чужой процесс не доходит ни до делегата, ни до команд.
//
// Поверхность намеренно узкая — ни путей, ни шелла, ни окружения, только номер вентилятора и обороты
// (FanHelperXPC). Журнал короткий: только отказы возврата «Авто» (stderr и os_log).
//   utilitumus-fan version   версия помощника, без SMC и без службы

#if FAN_TEST_FAKE_SMC
/// Только для тестов: сборка со швом не содержит настоящего SMC и не связана с IOKit.
final class FakeSMC {
    private let environment = ProcessInfo.processInfo.environment
    private var bytes: [String: UInt8] = ["FNum": 2, "F0Md": 0, "F1Md": 0]
    private var floats: [String: Float] = ["F0Mn": 1200, "F0Mx": 6000, "F0Tg": 0, "F1Mn": 1500, "F1Mx": 5500, "F1Tg": 0]

    init?() {
        // Завис в ручном режиме: и цель, и возврат в «Авто» не применяются.
        if environment["FAN_TEST_SMC_STUCK"] != nil { bytes["F0Md"] = 1; bytes["F1Md"] = 1 }
        // Вентиляторы остались в ручном режиме от прошлого запуска службы, запись работает.
        if environment["FAN_TEST_SMC_MANUAL"] != nil { bytes["F0Md"] = 1; bytes["F1Md"] = 1 }
    }

    func uint8(_ key: String) -> UInt8? { bytes[key] }
    /// Датчики читаются из файлов стенда при каждом чтении: температуру меняет скрипт. Нет файла — датчика нет.
    func float(_ key: String) -> Float? {
        let file = key == "Tp01" ? "temp-cpu" : key == "Tg05" ? "temp-gpu" : nil
        if let file {
            let text = try? String(contentsOfFile: (environment["FAN_TEST_DIR"] ?? ".") + "/" + file, encoding: .utf8)
            return text.flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return floats[key]
    }

    func setUInt8(_ key: String, _ value: UInt8) -> Bool {
        record("\(key)=\(value)")
        if environment["FAN_TEST_SMC_STUCK"] == nil { bytes[key] = value }
        return true
    }

    func setFloat(_ key: String, _ value: Float) -> Bool {
        record("\(key)=\(value)")
        if environment["FAN_TEST_SMC_STUCK"] == nil { floats[key] = value }
        return true
    }

    private func record(_ line: String) {
        let path = (environment["FAN_TEST_DIR"] ?? ".") + "/smc-writes.log"
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
typealias HelperSMC = FakeSMC
#else
typealias HelperSMC = SMC
#endif

func serviceLog(_ text: String) {
    FileHandle.standardError.write(Data(("utilitumus-fan: " + text + "\n").utf8))
    os_log("%{public}@", log: OSLog(subsystem: FanLink.label, category: "service"), text)
}

/// SMC применяет запись не мгновенно: сразу после неё ещё читается старое
/// значение. Ждём до секунды, пока условие не станет правдой.
func waitUntil(_ condition: () -> Bool) -> Bool {
    for _ in 0..<20 {
        if condition() { return true }
        usleep(50_000)
    }
    return false
}

/// Команды идут строго по одной на главной очереди, из всех соединений.
final class FanService: NSObject, FanHelperXPC {
    private lazy var smc = HelperSMC()
    /// Сторож: клиент, который взял вентилятор в ручной режим, обязан повторять удержание. Не повторяет (убит, завис,
    /// потерял связь) — вентиляторы возвращаются в «Авто» сами, иначе ручной режим держал бы обороты вечно.
    /// Клиент подключается на одну команду, поэтому закрытие соединения сигналом не служит: считается время
    /// последнего удержания. Только на главной очереди.
    private var holdWatchdog: DispatchWorkItem?
    private var releaseRetries = 0
    /// Защита от перегрева (FanLink.thermalTrip). Температуру смотрим только пока есть удержание, не чаще `thermalPoll`.
    private var thermal = ThermalGuard()
    private var sensorKeys: [String] = []
    private var thermalCheckedAt = Date.distantPast
    private var thermalWork: DispatchWorkItem?

    /// При каждом запуске живого удержания нет, а вентилятор мог остаться ручным: служба упала, и сторож упал вместе с ней.
    /// Клиент подтвердит удержание сам при следующем повторе. Главная очередь.
    func recoverAtStart() {
        #if FAN_TEST_FAKE_SMC
        if ProcessInfo.processInfo.environment["FAN_TEST_NO_START_RELEASE"] != nil { return }
        #endif
        guard holdWatchdog == nil else { return }
        releaseManualFans()
    }

    func version(reply: @escaping (String) -> Void) {
        #if FAN_TEST_FAKE_SMC
        if ProcessInfo.processInfo.environment["FAN_TEST_SILENT"] != nil { return }
        if ProcessInfo.processInfo.environment["FAN_TEST_SLOW_HELLO"] != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { reply(FanLink.helperVersion) }
            return
        }
        #endif
        reply(FanLink.helperVersion)
    }

    func setAuto(_ fan: Int, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { reply(self.auto(fan)) }
    }

    func setRPM(_ fan: Int, _ rpm: Double, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { reply(self.hold(fan, rpm)) }
    }

    /// Номер проверяется по числу вентиляторов в SMC, клиенту не верим.
    private func controllable(_ fan: Int) -> Result<HelperSMC, Refusal> {
        guard let smc else { return .failure(Refusal("AppleSMC недоступен")) }
        guard fan >= 0, let count = smc.uint8("FNum"), fan < Int(count) else {
            return .failure(Refusal("нет вентилятора \(fan)"))
        }
        return .success(smc)
    }

    private func auto(_ fan: Int) -> String? {
        let smc: HelperSMC
        switch controllable(fan) {
        case .success(let found): smc = found
        case .failure(let refusal): return refusal.text
        }
        guard smc.setUInt8("F\(fan)Md", 0) else { return "SMC отклонил запись (нужен root?)" }
        guard waitUntil({ smc.uint8("F\(fan)Md") == 0 }) else { return "режим не сменился" }
        return nil
    }

    /// Каждый вентилятор в ручном режиме — в «Авто», что бы ни стояло в настройках. Сторож не спрашивает, кто взял вентилятор.
    /// Не вышло — ещё несколько попыток. Ответ: `true`, если ручных вентиляторов не осталось; выходить службе можно только тогда.
    @discardableResult
    func releaseManualFans() -> Bool {
        watchdogStop()
        thermalWork?.cancel()
        thermalWork = nil
        guard let smc, let count = smc.uint8("FNum") else { return true }
        var failed = false
        for fan in 0..<Int(count) where smc.uint8("F\(fan)Md") == 1 {
            if auto(fan) != nil { failed = true }
        }
        guard failed else { releaseRetries = 0; return true }
        guard releaseRetries < 3 else {
            releaseRetries = 0
            serviceLog("не удалось вернуть «Авто» за \(3 + 1) попытки")
            return false
        }
        releaseRetries += 1
        watchdogArm(after: FanLink.holdRetry)
        return false
    }

    private func hottestSensor(_ smc: HelperSMC) -> Double? {
        if sensorKeys.isEmpty {
            let suffixes = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            sensorKeys = (FanLink.cpuSensorPrefixes + FanLink.gpuSensorPrefixes).flatMap { p in suffixes.map { "\(p)\($0)" } }
                .filter { key in smc.float(key).map(FanLink.isPlausibleTemperature) ?? false }
        }
        return ThermalGuard.hottest(sensorKeys.map { smc.float($0) })
    }

    /// `true` — перегрев. Без `force` показания не старше `thermalPoll` берутся из памяти. При переходе в перегрев вентиляторы отдаются системе.
    private func thermalTripped(force: Bool) -> Bool {
        guard let smc else { return false }
        let now = Date()
        if !force, now.timeIntervalSince(thermalCheckedAt) < FanLink.thermalPoll { return thermal.tripped }
        thermalCheckedAt = now
        let was = thermal.tripped
        let hot = thermal.update(hottest: hottestSensor(smc))
        if hot && !was {
            serviceLog("перегрев: вентиляторы возвращены системе, удержание не принимается, пока не остынет")
            releaseManualFans()
        }
        return hot
    }

    private func thermalWatchArm() {
        guard thermalWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.thermalWork = nil
            if !self.thermalTripped(force: true), self.holdWatchdog != nil { self.thermalWatchArm() }
        }
        thermalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FanLink.thermalPoll, execute: work)
    }

    private func watchdogStop() {
        holdWatchdog?.cancel()
        holdWatchdog = nil
    }

    private func watchdogArm(after seconds: TimeInterval) {
        watchdogStop()
        let work = DispatchWorkItem { [weak self] in self?.releaseManualFans() }
        holdWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hold(_ fan: Int, _ requested: Double) -> String? {
        let smc: HelperSMC
        switch controllable(fan) {
        case .success(let found): smc = found
        case .failure(let refusal): return refusal.text
        }
        guard requested.isFinite,
              let minRPM = smc.float("F\(fan)Mn"), let maxRPM = smc.float("F\(fan)Mx") else {
            return "некорректные обороты"
        }
        if thermalTripped(force: false) { return "перегрев: вентиляторы у системы, удержание не принято" }
        // Зажим до перевода во Float: очень большое конечное Double дало бы бесконечность.
        let rpm = Float(min(max(requested, Double(minRPM)), Double(maxRPM)))
        // Сторож заводится до записи: режим мог встать, а цель нет.
        releaseRetries = 0
        watchdogArm(after: FanLink.holdTimeout)
        thermalWatchArm()
        guard smc.setUInt8("F\(fan)Md", 1), smc.setFloat("F\(fan)Tg", rpm) else {
            return "SMC отклонил запись (нужен root?)"
        }
        // Ждём и режим, и цель: иначе приложение сразу перечитывает старую цель
        // и шлёт команду снова и снова, пока SMC её не применит.
        guard waitUntil({ smc.uint8("F\(fan)Md") == 1 && abs((smc.float("F\(fan)Tg") ?? -1) - rpm) < 1 }) else {
            return "режим или цель не применились"
        }
        return nil
    }

    private struct Refusal: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }
}

/// Сюда доходят только прошедшие проверку подписи. Без соединений служба выходит: launchd
/// поднимет её снова при следующем подключении, а root-процесс не висит без дела. Перед выходом вентиляторы
/// в ручном режиме отдаются системе.
final class FanListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = FanService()
    private var connections = 0
    private var idleExit: DispatchWorkItem?
    private var exitAttempts = 0

    /// Только на главной очереди. Пока хоть один вентилятор остался ручным, служба не выходит: ждёт и пробует снова,
    /// не больше `FanLink.exitRetries` раз. Потом выход с кодом 1, чтобы launchd поднял её и она попробовала ещё (при `exit(0)` он бы не поднял).
    func armIdleExit(after delay: TimeInterval = FanLink.idleExit) {
        idleExit?.cancel()
        let work = DispatchWorkItem {
            if self.service.releaseManualFans() { exit(0) }
            self.exitAttempts += 1
            if self.exitAttempts > FanLink.exitRetries {
                serviceLog("выход с вентилятором в ручном режиме после \(self.exitAttempts) проверок")
                exit(1)
            }
            serviceLog("вентилятор ещё в ручном режиме: выход отложен, проверка \(self.exitAttempts) из \(FanLink.exitRetries)")
            self.armIdleExit(after: FanLink.holdRetry)
        }
        idleExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        DispatchQueue.main.async {
            self.connections += 1
            self.exitAttempts = 0
            self.idleExit?.cancel()
        }
        connection.exportedInterface = NSXPCInterface(with: FanHelperXPC.self)
        connection.exportedObject = service
        connection.invalidationHandler = {
            DispatchQueue.main.async {
                self.connections -= 1
                if self.connections == 0 { self.exitAttempts = 0; self.armIdleExit() }
            }
        }
        connection.resume()
        return true
    }
}

let arguments = CommandLine.arguments.dropFirst()
if arguments.elementsEqual(["version"]) {
    print(FanLink.helperVersion)
    exit(0)
}
// Наличие переменной ничего не значит: из оболочки там `0`, из `open` — другое имя (отчёт о пробе, п. 2).
guard arguments.isEmpty, ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == FanLink.label else {
    FileHandle.standardError.write(Data("usage: utilitumus-fan version; службу запускает только launchd\n".utf8))
    exit(64)
}

let delegate = FanListenerDelegate()
let listener = NSXPCListener(machServiceName: FanLink.service)
listener.setConnectionCodeSigningRequirement(FanLink.listenerRequirement)
listener.delegate = delegate
listener.resume()
DispatchQueue.main.async { delegate.service.recoverAtStart() }
delegate.armIdleExit()
dispatchMain()
