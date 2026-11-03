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
    var mode: FanMode = .auto
    /// Для `.constant`. 0 — ещё не выбирали, UI подставит минимум вентилятора.
    var rpm: Double = 0
    var sensor: SensorSource = .cpu
    /// Для `.sensor`: до `fromTemp` — минимум оборотов, от `toTemp` — максимум,
    /// между ними линейно.
    var fromTemp: Double = 50
    var toTemp: Double = 85
}

struct FanReading: Identifiable {
    let index: Int
    let actual: Double
    let min: Double
    let max: Double
    let isManual: Bool
    var id: Int { index }
}

struct SensorReading: Identifiable {
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
        didSet { scheduleApply() }
    }
    @Published var configs: [FanConfig] {
        didSet {
            persist()
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
    private var pendingApply: DispatchWorkItem?
    /// Вентиляторы, для которых команда помощнику ещё выполняется.
    private var inFlight: Set<Int> = []
    /// Команды помощнику — строго по одной и по порядку: параллельные «макс» и
    /// «авто» для одного вентилятора доходили до SMC в случайном порядке.
    private nonisolated static let helperQueue = DispatchQueue(label: "utilitumus.fans.helper")

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configsKey),
           let saved = try? JSONDecoder().decode([FanConfig].self, from: data) {
            configs = saved
        } else {
            configs = []
        }
    }

    func start() {
        guard let smc, timer == nil else { return }
        // Набор датчиков у каждого чипа свой — находим, какие есть, один раз.
        let suffixes = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        func discover(_ prefixes: [String]) -> [String] {
            prefixes.flatMap { p in suffixes.map { "\(p)\($0)" } }
                .filter { key in smc.float(key).map(Self.isPlausible) ?? false }
        }
        cpuKeys = discover(["Tp0", "Tp1"])
        gpuKeys = discover(["Tg0", "Tg1"])

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in FanController.shared.tick() }
        }
    }

    /// Вызывается при выходе из приложения: отдать вентиляторы системе.
    /// Синхронно — иначе процесс завершится раньше помощника.
    func restoreAutoBlocking() {
        guard FanHelperInstaller.shared.status != .notInstalled, conflictingApp == nil, let smc else { return }
        let manual = fans.map(\.index).filter { smc.uint8("F\($0)Md") == 1 }
        // Через ту же очередь — после уже отправленных команд, а не наперегонки с ними.
        Self.helperQueue.sync {
            for index in manual { _ = Self.runHelper(["auto", String(index)]) }
        }
    }

    func setAllAuto() {
        fullPower = false
        configs = configs.map { var c = $0; c.mode = .auto; return c }
    }

    // MARK: - Цикл

    private func tick() {
        guard let smc else { return }

        let count = Int(smc.uint8("FNum") ?? 0)
        fans = (0..<count).compactMap { i in
            guard let actual = smc.float("F\(i)Ac"),
                  let lo = smc.float("F\(i)Mn"),
                  let hi = smc.float("F\(i)Mx") else { return nil }
            return FanReading(index: i, actual: Double(actual), min: Double(lo), max: Double(hi),
                              isManual: smc.uint8("F\(i)Md") == 1)
        }
        if configs.count < count {
            configs += Array(repeating: FanConfig(), count: count - configs.count)
        }

        cpuSensors = read(cpuKeys)
        gpuSensors = read(gpuKeys)

        if let cpu = cpuMax {
            if cpu >= Self.safetyTrip { safetyTripped = true }
            else if cpu < Self.safetyRelease { safetyTripped = false }
        }

        conflictingApp = NSWorkspace.shared.runningApplications.first {
            Self.conflictingBundleIDs.contains($0.bundleIdentifier ?? "")
        }

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
        guard FanHelperInstaller.shared.status != .notInstalled, conflictingApp == nil, let smc else { return }
        for fan in fans where fan.index < configs.count && !inFlight.contains(fan.index) {
            let i = fan.index
            let desired = desiredRPM(for: fan, config: configs[i])
            let isManual = smc.uint8("F\(i)Md") == 1
            let target = Double(smc.float("F\(i)Tg") ?? 0)
            let args: [String]
            if let rpm = desired {
                // Дрожание датчика на пару градусов не стоит запуска процесса.
                guard !isManual || abs(target - rpm) >= 50 else { continue }
                args = ["set", String(i), String(Int(rpm))]
            } else {
                guard isManual else { continue }
                args = ["auto", String(i)]
            }
            inFlight.insert(i)
            Self.helperQueue.async {
                let error = Self.runHelper(args)
                Task { @MainActor in
                    let me = FanController.shared
                    me.inFlight.remove(i)
                    me.lastError = error
                    // Пока команда шла, настройку могли поменять — сверить сразу,
                    // не дожидаясь тика.
                    if error == nil { me.apply() }
                }
            }
        }
    }

    /// nil — отдать системе.
    private func desiredRPM(for fan: FanReading, config: FanConfig) -> Double? {
        // Максимум охлаждает сильнее системы — перегрев ему не помеха.
        if fullPower { return fan.max }
        if safetyTripped { return nil }
        switch config.mode {
        case .auto:
            return nil
        case .constant:
            return min(max(config.rpm, fan.min), fan.max)
        case .sensor:
            guard let temp = (config.sensor == .cpu ? cpuMax : gpuMax),
                  config.toTemp > config.fromTemp else { return nil }
            let t = min(max((temp - config.fromTemp) / (config.toTemp - config.fromTemp), 0), 1)
            return fan.min + (fan.max - fan.min) * t
        }
    }

    // MARK: - Вспомогательное

    private func read(_ keys: [String]) -> [SensorReading] {
        keys.compactMap { key in
            guard let v = smc?.float(key).map(Double.init), Self.isPlausible(Float(v)) else { return nil }
            return SensorReading(key: key, value: v)
        }
    }

    private nonisolated static func isPlausible(_ t: Float) -> Bool { t > 0 && t < 150 }

    private func persist() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.configsKey)
        }
    }

    /// Возвращает текст ошибки или nil при успехе.
    private nonisolated static func runHelper(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FanHelperInstaller.installedPath)
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : "Помощник завершился с кодом \(process.terminationStatus)"
        }
        return nil
    }
}
