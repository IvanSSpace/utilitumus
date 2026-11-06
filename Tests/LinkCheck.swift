import Foundation
import Security

// Проверка связи центра и утилиты. Запуск: Tests/run-link-check.sh
// Без аргументов — чистая логика. С аргументом — роль в связке под launchd: один источник,
// подписи разные (их ставит скрипт).

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func finish() -> Never {
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

let testID = "test.link"

// MARK: - Чистая логика

func pureChecks() {
    check(KitLink.bundleID("awake") == "local.utilitumus.app.awake", "bundleID")
    check(KitLink.machService("awake") == "local.utilitumus.app.awake.xpc", "machService")
    check(KitLink.selfService("awake") == "local.utilitumus.app.awake.self.xpc", "selfService")

    let long = String(repeating: "я", count: 200)
    check(LinkStatus(enabled: true, line: long, needsSetup: 0).line.count == 80, "init обрезает строку статуса до 80")
    let rawStatus = #"{"enabled":true,"line":"\#(long)","needsSetup":2}"#
    let decoded = try? JSONDecoder().decode(LinkStatus.self, from: Data(rawStatus.utf8))
    check(decoded?.line.count == 80, "декодирование обрезает строку статуса до 80")
    check(decoded?.needsSetup == 2 && decoded?.enabled == true, "остальные поля статуса декодируются")

    let hello = LinkHello(id: "awake", version: "1.2.3", protocolVersion: KitLink.protocolVersion)
    let status = LinkStatus(enabled: false, line: "строка", needsSetup: 3)
    check((try? JSONDecoder().decode(LinkHello.self, from: JSONEncoder().encode(hello))) == hello, "LinkHello переживает кодирование")
    check((try? JSONDecoder().decode(LinkStatus.self, from: JSONEncoder().encode(status))) == status, "LinkStatus переживает кодирование")

    let helloData = try! JSONEncoder().encode(hello)
    check((try? LinkClient.decodeHello(helloData)) == hello, "hello текущей версии принимается")
    let future = try! JSONEncoder().encode(LinkHello(id: "awake", version: "9", protocolVersion: 99))
    do {
        _ = try LinkClient.decodeHello(future)
        check(false, "hello с версией 99 отвергается")
    } catch {
        check((error as? LinkError) == .incompatible(99), "hello с версией 99 — incompatible(99)")
    }
    check(KitLink.protocolVersion == 3, "версия протокола 3")
    for old in [1, 2] {
        do {
            _ = try LinkClient.decodeHello(try! JSONEncoder().encode(LinkHello(id: "awake", version: "1", protocolVersion: old)))
            check(false, "hello с версией \(old) отвергается")
        } catch {
            check((error as? LinkError) == .incompatible(old), "hello с версией \(old) — incompatible(\(old))")
        }
    }
    let oldest = KitLink.oldestProtocolVersion, current = KitLink.protocolVersion
    let ranges: [(Int, Int?, Bool, String)] = [
        (current, nil, true, "своя версия без диапазона"),
        (current, oldest, true, "своя версия со своим диапазоном"),
        (current + 1, current, true, "утилита новее, но понимает нашу версию"),
        (current + 1, nil, false, "утилита новее и понимает только свою"),
        (current + 1, current + 1, false, "утилита новее, наша версия ей уже чужая"),
        (oldest - 1, nil, false, "утилита старее нашего диапазона"),
        (oldest - 1, oldest - 1, false, "утилита старее, диапазон тоже"),
        (current, current + 1, false, "диапазон утилиты перевёрнут"),
    ]
    for (version, oldestOfPeer, accepted, name) in ranges {
        let hello = LinkHello(id: "awake", version: "1", protocolVersion: version, oldestProtocolVersion: oldestOfPeer)
        check(KitLink.isCompatible(hello) == accepted, "диапазон версий: \(name) (\(version), \(oldestOfPeer.map(String.init) ?? "нет")) — \(accepted ? "принят" : "отвергнут")")
        check(((try? LinkClient.decodeHello(JSONEncoder().encode(hello))) != nil) == accepted, "диапазон версий: decodeHello то же для «\(name)»")
    }
    let oldStatus = #"{"enabled":true,"line":"x","needsSetup":0}"#
    let tolerant = try? JSONDecoder().decode(LinkStatus.self, from: Data(oldStatus.utf8))
    check(tolerant?.attention == false && tolerant?.quickActions == [] && tolerant?.setupSteps == [], "статус без новых полей читается: они необязательны")
    check((try? LinkClient.decodeHello(Data("{не json".utf8))) == nil, "битый JSON в hello — ошибка, не падение")
    check((try? LinkClient.decodeStatus(Data("{не json".utf8))) == nil, "битый JSON в status — ошибка, не падение")

    let one = KitLink.requirement(identifier: "local.utilitumus")
    let marker = #"info["UtilitumusSecurityEpoch"] >= "1" and info["UtilitumusSecurityEpoch"] < "a""#
    check(one == "(identifier \"local.utilitumus\" and certificate leaf = H\"\(KitSigning.trustedLeafHashes[0])\" and \(marker))", "требование: точный identifier, leaf и метка выпуска")
    let two = KitLink.requirement(identifier: "x.y", hashes: ["aa", "bb"])
    check(two == "(identifier \"x.y\" and certificate leaf = H\"aa\" and \(marker)) or (identifier \"x.y\" and certificate leaf = H\"bb\" and \(marker))", "несколько хэшей — через or")
    // Два слушателя утилиты: центр и копия из Finder различаются службой, а не процессом по pid.
    let specs = LinkServer.specs(id: "awake")
    let hubSpec = specs.first { $0.role == .hub }, copySpec = specs.first { $0.role == .selfCopy }
    check(specs.count == 2 && hubSpec != nil && copySpec != nil, "слушателей два: центр и копия утилиты")
    check(hubSpec?.service == KitLink.machService("awake") && copySpec?.service == KitLink.selfService("awake") && hubSpec?.service != copySpec?.service, "службы разные")
    check(hubSpec?.requirement == KitLink.requirement(identifier: "local.utilitumus"), "служба центра: требование только к центру")
    check(hubSpec?.requirement.contains("local.utilitumus.app.awake") == false, "служба центра: копия утилиты (её identifier) не проходит требование")
    check(copySpec?.requirement == KitLink.requirement(identifier: "local.utilitumus.app.awake"), "служба копии: требование только к самой утилите")
    check(copySpec?.requirement.contains(#"identifier "local.utilitumus""#) == false, "служба копии: центр не проходит требование")
    for spec in specs {
        var requirement: SecRequirement?
        check(SecRequirementCreateWithString(spec.requirement as CFString, [], &requirement) == errSecSuccess, "требование \(spec.role) разбирается системой")
        // Чужой собеседник: этот процесс не подписан нашим сертификатом, поэтому не должен пройти ни одно требование.
        var me: SecCode?
        var passes = false
        if SecCodeCopySelf([], &me) == errSecSuccess, let me, let requirement { passes = SecCodeCheckValidity(me, [], requirement) == errSecSuccess }
        check(!passes, "чужой процесс не проходит требование \(spec.role)")
    }
    func methods(_ proto: Protocol) -> Set<String> {
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(proto, true, true, &count) else { return [] }
        defer { free(list) }
        return Set((0..<Int(count)).map { NSStringFromSelector(list[$0].name!) })
    }
    check(methods(LinkSelfXPC.self) == ["openWindowWithReply:"], "интерфейс копии утилиты: только «покажи окно» (\(methods(LinkSelfXPC.self)))")
    let hubMethods = methods(LinkXPC.self)
    check(["moduleAction:reply:", "watch:reply:", "quitWithReason:reply:", "setEnabled:reply:", "performSetupStep:reply:"].allSatisfy(hubMethods.contains),
          "интерфейс центра: действия, подписка и выход здесь")
    check(hubMethods.contains("openWindowWithReply:"), "интерфейс центра: окно тоже")
    check(!methods(LinkSelfXPC.self).contains("quitWithReason:reply:") && !methods(LinkSelfXPC.self).contains("moduleAction:reply:") && !methods(LinkSelfXPC.self).contains("watch:reply:"),
          "интерфейс копии: ни действий, ни экрана, ни выхода")

    // Сравнение метки числовое: «225» >= «9» истинно, как у checkEpoch и install.sh. Проверка на системном бандле,
    // чьё значение в Info.plist известно.
    let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    if let number = (NSDictionary(contentsOf: calculator.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String).flatMap(Int.init), number >= 10 {
        func holds(_ text: String) -> Bool {
            var code: SecStaticCode?, req: SecRequirement?
            guard SecStaticCodeCreateWithPath(calculator as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
            return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        check(holds(#"info["CFBundleVersion"] >= "9""#), "сравнение метки числовое: \(number) >= 9")
        check(!holds(#"info["CFBundleVersion"] >= "\(number + 1)""#), "сравнение метки: \(number) >= \(number + 1) ложно")
    }
    check(KitSigning.peerRequirement(identifier: "x", leafHash: "aa").hasSuffix(#"info["UtilitumusSecurityEpoch"] >= "1" and info["UtilitumusSecurityEpoch"] < "a""#), "требование собеседника: метка своей или новее")

    var parsed: SecRequirement?
    check(SecRequirementCreateWithString(KitLink.requirement(identifier: "x.y", hashes: [String(repeating: "a", count: 40), String(repeating: "b", count: 40)]) as CFString, [], &parsed) == errSecSuccess, "требование с двумя хэшами разбирается системой")
}

// MARK: - Журнал вызовов на стороне сервиса

func record(_ call: String, in dir: String, file name: String = "calls.log") {
    guard let file = fopen(dir + "/" + name, "a") else { return }
    fputs(call + "\n", file)
    fclose(file)
}
func recordedCalls(in dir: String, file name: String = "calls.log") -> [String] {
    ((try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

// MARK: - Настоящий сервер: LinkServer и зависающий по просьбе обработчик

@MainActor final class TestHandler: LinkHandler {
    let dir: String
    var enabled = false
    init(dir: String) { self.dir = dir }

    /// Завис как приложение: главный поток занят, ответа нет 10 с.
    private func hangIfAsked(_ call: String) {
        if (try? String(contentsOfFile: dir + "/hang", encoding: .utf8)) == call {
            Thread.sleep(forTimeInterval: 10)
        }
    }
    func linkHello() -> LinkHello {
        record("hello", in: dir)
        hangIfAsked("hello")
        return LinkHello(id: testID, version: "1.2.3", protocolVersion: KitLink.protocolVersion)
    }
    func linkStatus() -> LinkStatus {
        record("status", in: dir)
        hangIfAsked("status")
        return LinkStatus(enabled: enabled, line: "\(getpid())", needsSetup: 1)
    }
    /// Содержимое для связи непрозрачно: байты не JSON и проходят как есть.
    func linkModuleState() -> Data {
        record("moduleState", in: dir)
        return Data([0, 255, 1])
    }
    func linkModuleAction(_ action: Data) -> Data {
        record("moduleAction", in: dir)
        hangIfAsked("moduleAction")
        return Data(action.reversed())
    }
    func linkPerformSetupStep(_ id: String) -> Data {
        record("performSetupStep(\(id))", in: dir)
        return LinkWire.encoded(LinkReply(state: linkStatus(), error: nil))
    }
    func linkScreenOpen(_ open: Bool) { record("screenOpen(\(open))", in: dir) }
    func linkWatcherLost() { record("watcherLost", in: dir) }
    func linkSetEnabled(_ on: Bool) {
        record("setEnabled(\(on))", in: dir)
        enabled = on
        KitLink.postStatusChanged(testID)
    }
    func linkOpenWindow() { record("openWindow", in: dir) }
    func linkQuit(_ reason: LinkQuitReason) {
        record("quit(\(reason))", in: dir)
        exit(0)
    }
}

func runServer(dir: String, peer: String) -> Never {
    let server = MainActor.assumeIsolated { LinkServer(id: testID, handler: TestHandler(dir: dir), hubIdentifier: peer) }
    server.resume()
    RunLoop.main.run()
    exit(0)
}

// MARK: - Подменённый сервис: принимает всех, пишет всё, что до него дошло

final class FakeService: NSObject, LinkXPC, NSXPCListenerDelegate {
    let dir: String
    let mode: String
    var unanswered: [Any] = []
    init(dir: String, mode: String) { self.dir = dir; self.mode = mode }
    func setMenuIcon(_ on: Bool, reply: @escaping @Sendable () -> Void) { record("setMenuIcon(\(on))", in: dir); reply() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        record("connection", in: dir, file: "connections.log")
        connection.exportedInterface = NSXPCInterface(with: LinkXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func hello(reply: @escaping @Sendable (Data) -> Void) {
        record("hello", in: dir)
        let good = LinkHello(id: testID, version: "1", protocolVersion: KitLink.protocolVersion)
        switch mode {
        case "silent": unanswered.append(reply)  // держим блок: ответа просто нет
        case "v99": reply(try! JSONEncoder().encode(LinkHello(id: testID, version: "1", protocolVersion: 99)))
        case "next": reply(try! JSONEncoder().encode(LinkHello(id: testID, version: "1", protocolVersion: KitLink.protocolVersion + 1, oldestProtocolVersion: KitLink.protocolVersion)))
        case "garbage": reply(Data("{не json".utf8))
        default: reply(try! JSONEncoder().encode(good))
        }
    }
    func status(reply: @escaping @Sendable (Data) -> Void) {
        record("status", in: dir)
        reply(try! JSONEncoder().encode(LinkStatus(enabled: true, line: "подмена", needsSetup: 0)))
    }
    func moduleState(reply: @escaping @Sendable (Data) -> Void) {
        record("moduleState", in: dir)
        reply(Data())
    }
    func moduleAction(_ action: Data, reply: @escaping @Sendable (Data) -> Void) {
        record("moduleAction", in: dir)
        reply(Data())
    }
    func performSetupStep(_ id: String, reply: @escaping @Sendable (Data) -> Void) {
        record("performSetupStep", in: dir)
        reply(Data())
    }
    func watch(_ level: Int, reply: @escaping @Sendable () -> Void) {
        record("watch", in: dir)
        reply()
    }
    func setEnabled(_ enabled: Bool, reply: @escaping @Sendable () -> Void) {
        record("setEnabled(\(enabled))", in: dir)
        reply()
    }
    func openWindow(reply: @escaping @Sendable () -> Void) {
        record("openWindow", in: dir)
        reply()
    }
    func quit(reason: Int, reply: @escaping @Sendable () -> Void) {
        record("quit", in: dir)
        reply()
    }
}

func runFake(dir: String, mode: String) -> Never {
    let fake = FakeService(dir: dir, mode: mode)
    let listener = NSXPCListener(machServiceName: KitLink.machService(testID))
    listener.delegate = fake
    listener.resume()
    RunLoop.main.run()
    exit(0)
}

// MARK: - Клиент: сценарии

func errorCode(_ error: Error) -> Int { (error as NSError).code }
func onMainThread() -> Bool { Thread.isMainThread }

/// Что принёс DistributedNotificationCenter: наблюдатель вызывается на главной очереди.
@MainActor final class NoteBox {
    var received = false
    var hasData = false
}

/// Таймер главного потока: насколько надолго занят главный поток, пока ждём ответа.
@MainActor final class TickWatch {
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var maxGap = 0.0
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.maxGap = max(self.maxGap, now - self.last)
                self.last = now
            }
        }
    }
    deinit { timer?.invalidate() }
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Вызов зависает на `call` (сервер спит 10 с): клиент должен сдаться сам и не занять главный поток.
@MainActor func hangingCall(dir: String, call: String) async {
    try! call.write(toFile: dir + "/hang", atomically: true, encoding: .utf8)
    let client = LinkClient(id: testID)
    if call == "moduleAction" { _ = try? await client.hello() }
    let ticks = TickWatch()
    let started = ProcessInfo.processInfo.systemUptime
    var caught: Error?
    do {
        if call == "moduleAction" { _ = try await client.moduleAction(Data([1])) } else { _ = try await client.status() }
    } catch { caught = error }
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    check((caught as? LinkError) == .timeout, "завис \(call): клиент получил timeout (\(String(describing: caught)))")
    check(elapsed <= 2.5, String(format: "завис \(call): timeout за %.2f с, не больше 2,5", elapsed))
    check(ticks.maxGap <= 0.3, String(format: "завис \(call): пропуск тиков главного потока %.3f с, не больше 0,3", ticks.maxGap))
}

/// После отказа подменённому сервису не ушло ничего, кроме hello.
func onlyHello(in dir: String, _ label: String) {
    let calls = recordedCalls(in: dir)
    check(!calls.isEmpty && calls.allSatisfy { $0 == "hello" }, "\(label): до сервиса дошёл только hello (\(calls))")
}

@MainActor func clientScenario(_ scenario: String, dir: String) async {
    check(onMainThread(), "сценарий на главном потоке")
    switch scenario {
    case "basic":
        let note = NoteBox()
        let observer = DistributedNotificationCenter.default().addObserver(forName: KitLink.statusChanged(testID), object: nil, queue: .main) { received in
            let hasData = received.userInfo != nil
            MainActor.assumeIsolated {
                note.received = true
                note.hasData = hasData
            }
        }
        let client = LinkClient(id: testID)
        do {
            try await client.setEnabled(true)
            check(onMainThread(), "ответ на главном потоке")
            let calls = recordedCalls(in: dir)
            check(calls == ["hello", "setEnabled(true)"], "первый вызов соединения — hello, команда после него (\(calls))")
            let status = try await client.status()
            check(status.enabled && status.needsSetup == 1 && Int32(status.line) != nil, "status получен: \(status)")
            try await client.openWindow()
            check(recordedCalls(in: dir).filter { $0 == "hello" }.count == 1, "повторного рукопожатия на том же соединении нет")
            check(recordedCalls(in: dir).last == "openWindow", "openWindow дошёл до обработчика")
            let state = try await client.moduleState()
            check(state == Data([0, 255, 1]), "moduleState: байты модуля проходят как есть")
            let reply = try await client.moduleAction(Data([1, 2, 3]))
            check(reply == Data([3, 2, 1]), "moduleAction: действие дошло, ответ вернулся как есть")
            let hello = try await client.hello()
            check(hello == LinkHello(id: testID, version: "1.2.3", protocolVersion: KitLink.protocolVersion), "hello получен: \(hello)")
        } catch {
            check(false, "связь с настоящим сервером: \(error)")
        }
        for _ in 0..<40 where !note.received { await pause(0.05) }
        check(note.received, "statusChanged доставлен")
        check(!note.hasData, "statusChanged без данных")
        DistributedNotificationCenter.default().removeObserver(observer)

    case "rogue":
        let client = LinkClient(id: testID)
        for (name, call) in [("hello", { _ = try await client.hello() }), ("setEnabled", { try await client.setEnabled(true) }),
                            ("moduleState", { _ = try await client.moduleState() }),
                            ("moduleAction", { _ = try await client.moduleAction(Data([1])) })] as [(String, () async throws -> Void)] {
            do {
                try await call()
                check(false, "rogue: \(name) не должен пройти")
            } catch {
                print("     rogue: \(name) — \(error)")
                check((error as? LinkError) != .timeout, "rogue: \(name) отвергнут сразу, код \(errorCode(error))")
            }
        }
        check(recordedCalls(in: dir).isEmpty, "rogue: обработчик сервера не вызывался (\(recordedCalls(in: dir)))")

    case "selfcopy":
        // Процесс с identifier самой утилиты (Finder). Служба центра его не пускает совсем; своя служба пускает
        // и умеет одно: окно. Раньше его определяли по pid уже после соединения.
        let client = LinkClient(id: testID)
        for (name, call) in [("hello", { _ = try await client.hello() }), ("setEnabled", { try await client.setEnabled(true) }),
                            ("moduleState", { _ = try await client.moduleState() }),
                            ("moduleAction", { _ = try await client.moduleAction(Data([1])) }),
                            ("watch", { client.setWatch(.screen); _ = try await client.status() }),
                            ("quit", { try await client.quit(.uninstall) }),
                            ("openWindow", { try await client.openWindow() })] as [(String, () async throws -> Void)] {
            do {
                try await call()
                check(false, "копия утилиты: \(name) на службе центра не должен пройти")
            } catch {
                check((error as? LinkError) != .timeout, "копия утилиты: \(name) на службе центра отвергнут сразу (\(error))")
            }
        }
        check(recordedCalls(in: dir).isEmpty, "копия утилиты: служба центра ничего не получила (\(recordedCalls(in: dir)))")
        do {
            try await LinkSelfClient.openWindow(id: testID)
            check(true, "копия утилиты: окно через свою службу")
        } catch {
            check(false, "копия утилиты: окно через свою службу (\(error))")
        }
        await pause(0.2)
        check(recordedCalls(in: dir) == ["openWindow"], "копия утилиты: на сервере только openWindow (\(recordedCalls(in: dir)))")

    case "hub-on-self":
        // Центр на службу копии не ходит: её требование — только сама утилита.
        do {
            try await LinkSelfClient.openWindow(id: testID)
            check(false, "центр на службе копии не должен пройти")
        } catch {
            check((error as? LinkError) != .timeout, "центр на службе копии отвергнут сразу (\(error))")
        }
        check(recordedCalls(in: dir).isEmpty, "центр на службе копии: обработчик не вызывался (\(recordedCalls(in: dir)))")

    case "rejected":
        let client = LinkClient(id: testID)
        for attempt in 1...2 {
            do {
                try await client.setEnabled(true)
                check(false, "подмена: команда не должна пройти")
            } catch {
                check((error as? LinkError) == .rejected, "подмена: попытка \(attempt) — rejected (\(error))")
            }
        }
        await pause(0.3)  // сообщение, если бы ушло, успело бы дойти
        onlyHello(in: dir, "подмена")
        let connections = recordedCalls(in: dir, file: "connections.log").count
        check(connections == 2, "подмена: после отказа соединение закрыто, новая попытка — новое (\(connections))")

    case "rejected-race":
        // Отказ подписи пришёл, а главный поток занят: команда, поданная в этот промежуток,
        // не должна уйти по соединению, которое уже отвергнуто.
        let client = LinkClient(id: testID)
        let first = Task { @MainActor in try? await client.hello() }
        await Task.yield()
        usleep(500_000)  // именно занять главный поток, а не отпустить его
        let second = try? await client.hello()
        check(second == nil, "подмена, занятый главный поток: второй вызов не прошёл")
        _ = await first.value
        await pause(0.3)
        let hellos = recordedCalls(in: dir).filter { $0 == "hello" }.count
        let connections = recordedCalls(in: dir, file: "connections.log").count
        check(hellos == 1, "подмена, занятый главный поток: по отвергнутому соединению ничего не ушло (hello: \(hellos), соединений: \(connections))")

    case "silent":
        let client = LinkClient(id: testID)
        do {
            try await client.setEnabled(true)
            check(false, "сервис молчит: команда не должна пройти")
        } catch {
            check((error as? LinkError) == .timeout, "сервис молчит: timeout (\(error))")
        }
        await pause(0.3)
        onlyHello(in: dir, "сервис молчит")

    case "v99":
        let client = LinkClient(id: testID)
        do {
            try await client.setEnabled(true)
            check(false, "чужая версия: команда не должна пройти")
        } catch {
            check((error as? LinkError) == .incompatible(99), "чужая версия: incompatible(99) (\(error))")
        }
        await pause(0.3)
        onlyHello(in: dir, "чужая версия")

    case "next":
        let client = LinkClient(id: testID)
        do {
            try await client.setEnabled(true)
            check(recordedCalls(in: dir) == ["hello", "setEnabled(true)"], "утилита на версию новее, понимает нашу: команда прошла (\(recordedCalls(in: dir)))")
        } catch {
            check(false, "утилита на версию новее: \(error)")
        }

    case "garbage":
        let client = LinkClient(id: testID)
        do {
            try await client.setEnabled(true)
            check(false, "битый ответ: команда не должна пройти")
        } catch {
            check(true, "битый ответ: ошибка (\(type(of: error)))")
        }
        await pause(0.3)
        onlyHello(in: dir, "битый ответ")

    case "hang-hello":
        await hangingCall(dir: dir, call: "hello")

    case "hang-status":
        await hangingCall(dir: dir, call: "status")

    case "hang-action":
        await hangingCall(dir: dir, call: "moduleAction")

    case "killed":
        // Вызов уже в пути, когда сервер убит: иначе клиенту незачем видеть ошибку, launchd просто поднимет новый.
        let client = LinkClient(id: testID, timeout: 3)
        do {
            guard let pid = Int32(try await client.status().line) else { return check(false, "pid сервера") }
            try! "status".write(toFile: dir + "/hang", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { kill(pid, SIGKILL) }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await client.status()
                check(false, "kill -9: вызов не должен пройти")
            } catch {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                check((error as? LinkError) != .timeout, String(format: "kill -9: ошибка за %.2f с, код %d", elapsed, errorCode(error)))
            }
            try? FileManager.default.removeItem(atPath: dir + "/hang")
            // launchd придерживает до 10 с перезапуск процесса, прожившего меньше 10 с.
            let restart = ProcessInfo.processInfo.systemUptime
            var newPid: Int32?
            while newPid == nil, ProcessInfo.processInfo.systemUptime - restart < 20 {
                newPid = Int32((try? await client.status())?.line ?? "")
                if newPid == nil { await pause(0.2) }
            }
            let waited = ProcessInfo.processInfo.systemUptime - restart
            check(newPid != nil && newPid != pid, String(format: "после kill -9 launchd поднял новый процесс, вызов успешен за %.2f с", waited))
            print("     старый pid \(pid), новый \(newPid.map(String.init) ?? "нет")")
        } catch {
            check(false, "kill -9: подготовка \(error)")
        }

    case "killed-idle":
        // Убит между вызовами: новый процесс не должен получить команду без рукопожатия.
        let client = LinkClient(id: testID, timeout: 3)
        do {
            guard let pid = Int32(try await client.status().line) else { return check(false, "pid сервера") }
            kill(pid, SIGKILL)
            await pause(0.3)
            var answered = false
            for _ in 0..<80 where !answered {
                answered = (try? await client.status()) != nil
                if !answered { await pause(0.2) }
            }
            let calls = recordedCalls(in: dir)
            check(answered, "убит между вызовами: новый вызов успешен")
            check(calls.count > 2 && calls[2] == "hello" && calls.last == "status", "убит между вызовами: новый процесс сначала получил hello (\(calls))")
        } catch {
            check(false, "убит между вызовами: подготовка \(error)")
        }

    case "quit":
        let client = LinkClient(id: testID)
        do {
            guard let pid = Int32(try await client.status().line) else { return check(false, "pid сервера") }
            try await client.quit(.uninstall)
            check(true, "quit подтверждён ответом")
            for _ in 0..<40 where kill(pid, 0) == 0 { await pause(0.05) }
            check(kill(pid, 0) != 0, "quit: процесс вышел")
            check(recordedCalls(in: dir).last == "quit(uninstall)", "quit: причина дошла (\(recordedCalls(in: dir).last ?? "нет"))")
        } catch {
            check(false, "quit: \(error)")
        }

    default:
        check(false, "неизвестный сценарий \(scenario)")
    }
}

// MARK: - Вход

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "pure" {
case "pure":
    pureChecks()
    finish()
case "server":
    guard args.count == 5, args[3] == "--peer" else { fatalError("server <папка> --peer <identifier>") }
    runServer(dir: args[2], peer: args[4])
case "fake":
    runFake(dir: args[2], mode: args[3])
case "client":
    let scenario = args[2], dir = args[3]
    Task { @MainActor in
        await clientScenario(scenario, dir: dir)
        finish()
    }
    RunLoop.main.run()
default:
    fatalError("неизвестная роль")
}
