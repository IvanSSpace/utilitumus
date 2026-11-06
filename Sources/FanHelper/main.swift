import Foundation

// utilitumus-fan — единственный кусок Utilitumus, работающий от root: писать в SMC может только root.
// Это служба launchd в системном домене, её запускает launchd по первому подключению. setuid нет,
// поэтому обычный запуск бинарника прав не даёт. Кто подключается, проверяет сам XPC по подписи
// (FanLink.listenerRequirement): чужой процесс не доходит ни до делегата, ни до команд.
//
// Поверхность намеренно узкая — ни путей, ни шелла, ни окружения, только номер вентилятора и обороты
// (FanHelperXPC). Журнала нет.
//   utilitumus-fan version   версия помощника, без SMC и без службы

#if FAN_TEST_FAKE_SMC
/// Только для тестов: сборка со швом не содержит настоящего SMC и не связана с IOKit.
final class FakeSMC {
    private let environment = ProcessInfo.processInfo.environment
    private var bytes: [String: UInt8] = ["FNum": 2, "F0Md": 0, "F1Md": 0]
    private var floats: [String: Float] = ["F0Mn": 1200, "F0Mx": 6000, "F0Tg": 0, "F1Mn": 1500, "F1Mx": 5500, "F1Tg": 0]

    init?() {
        // Завис в ручном режиме: и цель, и возврат в «Авто» не применяются.
        if environment["FAN_TEST_SMC_STUCK"] != nil { bytes["F0Md"] = 1 }
    }

    func uint8(_ key: String) -> UInt8? { bytes[key] }
    func float(_ key: String) -> Float? { floats[key] }

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

    func version(reply: @escaping (String) -> Void) {
        #if FAN_TEST_FAKE_SMC
        if ProcessInfo.processInfo.environment["FAN_TEST_SILENT"] != nil { return }
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
        // Зажим до перевода во Float: очень большое конечное Double дало бы бесконечность.
        let rpm = Float(min(max(requested, Double(minRPM)), Double(maxRPM)))
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
/// поднимет её снова при следующем подключении, а root-процесс не висит без дела.
final class FanListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = FanService()
    private var connections = 0
    private var idleExit: DispatchWorkItem?

    /// Только на главной очереди.
    func armIdleExit() {
        let work = DispatchWorkItem { exit(0) }
        idleExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FanLink.idleExit, execute: work)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        DispatchQueue.main.async {
            self.connections += 1
            self.idleExit?.cancel()
        }
        connection.exportedInterface = NSXPCInterface(with: FanHelperXPC.self)
        connection.exportedObject = service
        connection.invalidationHandler = {
            DispatchQueue.main.async {
                self.connections -= 1
                if self.connections == 0 { self.armIdleExit() }
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
delegate.armIdleExit()
dispatchMain()
