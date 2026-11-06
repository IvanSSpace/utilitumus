import AppKit

// Порядок шагов обновления и удержание вентиляторов. Запуск: Tests/run-update-order-check.sh
// UpdateBundle и FanController настоящие, ниже подделаны только их соседи: SMC и служба вентиляторов — запись в память.

// MARK: - Подделки

/// Вентилятор 0 и служба: команды меняют состояние так же, как настоящая служба меняла бы SMC.
final class Bench: @unchecked Sendable {
    static let shared = Bench()
    private let lock = NSLock()
    private var manualNow = false
    private var targetNow: Float = 0
    private var commands: [String] = []
    private var reads = 0
    private var gate: DispatchSemaphore?
    private var blocked = false

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var manual: Bool {
        get { locked { manualNow } }
        set { locked { manualNow = newValue } }
    }
    var target: Float { locked { targetNow } }
    var log: [String] { locked { commands } }
    var readCount: Int { locked { reads } }
    var isBlocked: Bool { locked { blocked } }
    func clearLog() { locked { commands = [] } }
    func countRead() { locked { reads += 1 } }

    /// Следующая `set` застрянет на очереди помощника, пока не вызовут `release`.
    func blockNextSet() { locked { gate = DispatchSemaphore(value: 0) } }
    func release() { locked { gate?.signal(); gate = nil } }

    func deliver(_ command: FanHelperClient.Command) {
        if case .set = command, let gate = locked({ gate }) {
            locked { blocked = true }
            gate.wait()
            locked { blocked = false }
        }
        locked {
            commands.append(command.description)
            switch command {
            case .auto: manualNow = false
            case .set(_, let rpm): manualNow = true; targetNow = Float(rpm)
            }
        }
    }

    func noteLegacy(_ fans: [Int]) { locked { commands.append("legacy auto \(fans)"); manualNow = false } }
}

final class SMC: @unchecked Sendable {
    init?() {}
    func uint8(_ key: String) -> UInt8? {
        switch key {
        case "FNum": Bench.shared.countRead(); return 1
        case "F0Md": return Bench.shared.manual ? 1 : 0
        default: return nil
        }
    }
    func float(_ key: String) -> Float? {
        switch key {
        case "F0Ac": return 2000
        case "F0Mn": return 1200
        case "F0Mx": return 6000
        case "F0Tg": return Bench.shared.target
        case "Tp01": return 60
        default: return nil
        }
    }
}

enum FanHelperClient {
    enum Command: CustomStringConvertible {
        case auto(Int)
        case set(Int, Double)
        var description: String {
            switch self {
            case .auto(let fan): return "auto \(fan)"
            case .set(let fan, let rpm): return "set \(fan) \(Int(rpm))"
            }
        }
    }
    static func send(_ command: Command) -> String? { Bench.shared.deliver(command); return nil }
    /// Как настоящая: через ту же очередь, после уже отправленных.
    static func sendAll(_ commands: [Command], on queue: DispatchQueue, finished: @escaping @Sendable (Command, String?) -> Void) {
        guard !commands.isEmpty else { return }
        queue.async { commands.forEach { Bench.shared.deliver($0); finished($0, nil) } }
    }
}

enum LegacyFanHelper {
    static func restoreAuto(fans: [Int], path: String) -> String? { Bench.shared.noteLegacy(fans); return nil }
    static func restoreAutoWithin(fans: [Int], path: String, on queue: DispatchQueue, finished: @escaping @Sendable (String?) -> Void) {
        guard !fans.isEmpty else { return }
        queue.async { Bench.shared.noteLegacy(fans); finished(nil) }
    }
}

@MainActor
final class FanHelperInstaller {
    enum Status { case notInstalled, installed, outdated, ready }
    static let shared = FanHelperInstaller()
    nonisolated static let installedPath = "/nonexistent"
    var status = Status.ready
    var moduleRunning = false
    var hasLegacySetuid = false
    var serviceAnswered = true
    func refresh() {}
}

@MainActor
final class GameModeController {
    static let shared = GameModeController()
    var isActive = false
    func start() {}
    func stop() {}
    func cancelCurrent() {}
}

enum PrivateLog { static func prepare(file: URL) {} }

// MARK: - Проверки

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let fm = FileManager.default
let good = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let version = "9.9.9"
let staged = root.appendingPathComponent("Utilitumus.app.new")
let target = root.appendingPathComponent("Utilitumus.app")
let data = "Contents/Resources/data.txt"

func freshTarget() {
    try? fm.removeItem(at: target)
    try! fm.createDirectory(at: target, withIntermediateDirectories: true)
    try! "старая".write(to: target.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
}
func targetIntact() -> Bool { fm.fileExists(atPath: target.appendingPathComponent("old.txt").path) }

func copyOfGood(_ name: String) -> URL {
    let dir = root.appendingPathComponent(name)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let app = dir.appendingPathComponent("Utilitumus.app")
    try! fm.copyItem(at: good, to: app)
    return app
}

let bench = Bench.shared

func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

/// Ждёт условия; false — не дождались.
@MainActor func until(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        await pause(0.02)
    }
    return condition()
}

/// Шаги обновления в том порядке, в каком они случились, и что было на диске у каждого.
@MainActor final class Steps {
    var order: [String] = []
    var targetIntactAtBefore = false
    var stagedExistsAtBefore = false
    var targetIntactAtFailed = false
}

/// `install` как в Updater: те же действия контроллера, плюс запись шагов.
@MainActor func runInstall(_ app: URL, version v: String = version, afterCopy: (URL) throws -> Void = { _ in }) async -> (Steps, Error?) {
    let steps = Steps()
    let controller = FanController.shared
    do {
        try await UpdateBundle.install(app, expectedVersion: v, target: target, afterCopy: afterCopy, beforeReplace: {
            steps.order.append("before")
            steps.targetIntactAtBefore = targetIntact()
            steps.stagedExistsAtBefore = fm.fileExists(atPath: staged.path)
            controller.holdForUpdate()
        }, replaceFailed: {
            steps.order.append("failed")
            steps.targetIntactAtFailed = targetIntact()
            controller.resumeAfterFailedUpdate()
        })
        return (steps, nil)
    } catch {
        return (steps, error)
    }
}

/// Базовая линия: контроллер под управлением, вентилятор в ручном на `rpm`. Без неё «ничего не послал» ничего бы не значило.
@MainActor func controlled(rpm: Double, _ name: String) async {
    FanController.shared.configs = [FanConfig(mode: .constant, rpm: rpm)]
    let ok = await until { bench.manual && Int(bench.target) == Int(rpm) }
    check(ok, name)
    bench.clearLog()
}

@MainActor func scenario() async {
    let controller = FanController.shared
    let installer = FanHelperInstaller.shared

    controller.configs = [FanConfig(mode: .constant, rpm: 3000)]
    controller.start()
    check(await until { bench.log.contains("set 0 3000") }, "без обновления такт шлёт set: стенд не слеп")
    bench.clearLog()

    // Обновление удалось: порядок, «Авто» до подмены, и дальше ни одной команды.
    freshTarget()
    let (ok, okError) = await runInstall(copyOfGood("ok"))
    check(okError == nil, "подписанная сборка ставится: \(okError?.localizedDescription ?? "")")
    check(ok.order == ["before"], "успех: beforeReplace один раз, replaceFailed нет: \(ok.order)")
    check(ok.targetIntactAtBefore, "beforeReplace раньше подмены: цель ещё старая")
    check(ok.stagedExistsAtBefore, "beforeReplace после stage: копия уже лежит")
    check(!targetIntact(), "после install цель заменена")
    check(await until { bench.log == ["auto 0"] }, "«Авто» ушёл: \(bench.log)")
    check(!bench.manual, "вентилятор отдан системе")

    bench.clearLog()
    let readsBefore = bench.readCount
    await pause(2.5)
    check(bench.readCount > readsBefore, "такты идут: чтение SMC продолжается")
    check(bench.log.isEmpty && !bench.manual, "под удержанием такт ничего не шлёт: \(bench.log)")
    controller.fullPower = true
    await pause(0.5)
    check(bench.log.isEmpty && !bench.manual, "под удержанием «Полная мощность» ничего не шлёт: \(bench.log)")
    controller.fullPower = false
    controller.configs = [FanConfig(mode: .constant, rpm: 3100)]
    await pause(0.5)
    check(bench.log.isEmpty && !bench.manual, "под удержанием новая настройка ничего не шлёт: \(bench.log)")
    controller.gameModeChanged()
    await pause(0.5)
    check(bench.log.isEmpty && !bench.manual, "под удержанием смена игрового режима ничего не шлёт: \(bench.log)")
    controller.stop()
    controller.start()
    await pause(0.5)
    check(bench.log.isEmpty && !bench.manual, "выключение и включение модуля удержание не снимают: \(bench.log)")

    // Служба устарела, вентилятор застрял: и эта ветка apply молчит.
    bench.manual = true
    installer.status = .outdated
    controller.gameModeChanged()
    await pause(0.5)
    check(bench.log.isEmpty, "под удержанием починка застрявшего через службу молчит: \(bench.log)")
    installer.hasLegacySetuid = true
    controller.gameModeChanged()
    await pause(0.5)
    check(bench.log.isEmpty, "под удержанием прежний помощник молчит: \(bench.log)")
    installer.hasLegacySetuid = false
    installer.status = .ready

    // Удержание не мешает отпустить: при выходе это последний шанс.
    controller.stop()
    check(await until { bench.log == ["auto 0"] && !bench.manual }, "под удержанием выход отдаёт «Авто»: \(bench.log)")
    controller.start()
    bench.clearLog()

    // Снятие возвращает управление сразу: сразу после такта таймера следующий через 2 с, быстрее — только сам tick().
    let readsAtStart = bench.readCount
    check(await until { bench.readCount > readsAtStart }, "такт таймера пришёл")
    await pause(0.05)
    let readsAligned = bench.readCount
    controller.resumeAfterFailedUpdate()
    check(await until(0.5) { bench.readCount > readsAligned }, "снятие читает SMC сразу, не ждёт такта")
    check(await until(0.5) { bench.log == ["set 0 3100"] && bench.manual }, "снятие возвращает управление: \(bench.log)")

    // Stage не прошёл: beforeReplace не было, управление не прерывалось.
    await controlled(rpm: 3200, "управление снова на месте")
    freshTarget()
    let (badStage, badStageError) = await runInstall(copyOfGood("version"), version: "1.0.0")
    check(badStageError != nil, "не та версия: отказ")
    check(badStage.order.isEmpty, "stage не прошёл: ни beforeReplace, ни replaceFailed: \(badStage.order)")
    check(targetIntact(), "stage не прошёл: цель цела")
    check(bench.log.isEmpty && bench.manual, "stage не прошёл: вентиляторы не тронуты: \(bench.log)")
    await controlled(rpm: 3300, "stage не прошёл: управление работает")

    // Commit не прошёл: копию подменили после stage.
    freshTarget()
    let (badCommit, badCommitError) = await runInstall(copyOfGood("swap")) { copy in
        try "подмена".write(to: copy.appendingPathComponent(data), atomically: false, encoding: .utf8)
    }
    check(badCommitError?.localizedDescription.contains("не от автора") == true, "commit не прошёл: отказ подписи: \(badCommitError?.localizedDescription ?? "nil")")
    check(badCommit.order == ["before", "failed"], "commit не прошёл: beforeReplace, затем replaceFailed: \(badCommit.order)")
    check(badCommit.targetIntactAtBefore && badCommit.stagedExistsAtBefore, "commit не прошёл: beforeReplace был до подмены")
    check(badCommit.targetIntactAtFailed && targetIntact(), "commit не прошёл: цель цела")
    check(!fm.fileExists(atPath: staged.path), "commit не прошёл: копии не осталось")
    check(await until { bench.log == ["auto 0", "set 0 3300"] && bench.manual }, "commit не прошёл: сначала «Авто», потом управление снова берёт вентилятор: \(bench.log)")
    await controlled(rpm: 3400, "commit не прошёл: новые настройки применяются")

    // Set уже в очереди, когда пришло удержание: в SMC его не видно, а отпустить надо и этот вентилятор.
    controller.configs = [FanConfig(mode: .auto)]
    check(await until { !bench.manual }, "вентилятор отдан системе перед проверкой")
    bench.clearLog()
    bench.blockNextSet()
    controller.configs = [FanConfig(mode: .constant, rpm: 3500)]
    check(await until { bench.isBlocked }, "set застрял на очереди помощника")
    check(!bench.manual, "в SMC его ещё не видно")
    controller.holdForUpdate()
    bench.release()
    check(await until { bench.log.count == 2 }, "обе команды дошли: \(bench.log)")
    check(bench.log == ["set 0 3500", "auto 0"], "«Авто» идёт после застрявшего set: \(bench.log)")
    check(!bench.manual, "застрявший set не оставил вентилятор в ручном")
    await pause(0.5)
    check(bench.log.count == 2 && !bench.manual, "завершение set не запускает новых команд: \(bench.log)")
}

// Журнал контроллера пишется в домашнюю папку: под настоящей проверка не идёт.
guard fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: CommandLine.arguments[3]).resolvingSymlinksInPath().path else {
    print("FAIL домашняя папка не подменена: \(fm.homeDirectoryForCurrentUser.path)")
    exit(1)
}

// Пока запущен Macs Fan Control, такт контроллера уступает ему и ничего не шлёт: порядок шагов не проверить.
guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty else {
    print("skip Macs Fan Control запущен: такт уступает ему, проверку не запустить")
    exit(0)
}

// Настройки контроллера идут мимо подменённой папки, в домен этого бинарника (не приложения): не оставляем его ни до, ни после.
let defaultsDomain = ProcessInfo.processInfo.processName
UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)

Task { @MainActor in
    await scenario()
    UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
    // Дождаться cfprefsd: иначе он создаст файл уже после того, как скрипт его уберёт.
    UserDefaults.standard.synchronize()
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
