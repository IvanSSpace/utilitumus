import CryptoKit
import Foundation

// Основа модулей: модель центра, хост утилиты, протокол. Запуск: Tests/run-satellite-base-check.sh
// Роли: pure — модель на управляемой связи и помощники; live <папка> <pid> — настоящая утилита-проба под launchd;
// lease — процесс, который держит экран и ждёт, пока его убьют; foreign и state — как у всех проверок.

let id = LinkIdentity.id(probeName)

// MARK: - Управляемая связь

@MainActor final class ScriptedLink {
    var reads: [CheckedContinuation<Data, Error>] = []
    var actions: [(sent: Data, reply: CheckedContinuation<Data, Error>)] = []
    var watches: [LinkWatch] = []
    var ping: (@MainActor () -> Void)?

    var link: RemoteModuleLink {
        RemoteModuleLink(
            state: { try await withCheckedThrowingContinuation { self.reads.append($0) } },
            action: { sent in try await withCheckedThrowingContinuation { self.actions.append((sent, $0)) } },
            setWatch: { self.watches.append($0) },
            onPing: { self.ping = $0 })
    }

    func answerRead(_ state: ProbeState) { answerRead(0, state) }
    func answerRead(_ index: Int, _ state: ProbeState) { reads.remove(at: index).resume(returning: LinkWire.encoded(state)) }
    func failRead(_ index: Int = 0) { reads.remove(at: index).resume(throwing: LinkError.timeout) }
    func answerAction(_ state: ProbeState, error: String? = nil) { answerAction(0, state, error: error) }
    func answerAction(_ index: Int, _ state: ProbeState, error: String? = nil) {
        actions.remove(at: index).reply.resume(returning: LinkWire.encoded(LinkReply(state: state, error: error)))
    }
    func failAction(_ index: Int = 0) { actions.remove(at: index).reply.resume(throwing: LinkError.timeout) }
}

func level(_ value: Int) -> ProbeState {
    var state = ProbeState()
    state.level = value
    return state
}

let probeOptimistic: (inout ProbeState, ProbeAction) -> Void = { state, action in
    if case .setLevel(let value) = action { state.level = value }
    if case .setLine(let line) = action { state.line = line }
}

@MainActor func scripted(coalesce: ((ProbeAction) -> String?)? = nil, canRead: @escaping () -> Bool = { true }, base: LinkWatch = .none) -> (RemoteModuleModel<ProbeState, ProbeAction>, ScriptedLink) {
    let script = ScriptedLink()
    let model = RemoteModuleModel<ProbeState, ProbeAction>(
        id: "test.scripted", initial: ProbeState(), baseWatch: base, link: script.link, canRead: canRead,
        optimistic: probeOptimistic, coalesceKey: coalesce ?? { _ in nil })
    return (model, script)
}

/// Дать запущенным задачам дойти до связи и обратно.
@MainActor func settle() async { await pause(0.02) }

// MARK: - Помощники связи

struct ManyKeys: Codable, Equatable {
    var zeta = 1, yankee = 2, xray = 3, whiskey = 4, victor = 5, uniform = 6, tango = 7, sierra = 8, romeo = 9, quebec = 10
    var nested = ["c": 1, "b": 2, "a": 3]
}
struct Unencodable: Encodable {
    func encode(to encoder: Encoder) throws { throw EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: "нет")) }
}

func wireChecks() {
    let many = ManyKeys()
    let first = LinkWire.encoded(many)
    let text = String(decoding: first, as: UTF8.self)
    check(text.hasPrefix(#"{"nested":{"a":3,"b":2,"c":1},"quebec":10,"romeo""#), "sortedKeys: ключи по порядку, и во вложенных тоже: \(text.prefix(40))")
    check((0..<200).allSatisfy { _ in LinkWire.encoded(ManyKeys()) == first }, "sortedKeys: 200 кодирований байт в байт")
    check(LinkWire.encoded(Unencodable()).isEmpty, "не кодируется — пустые байты, без падения")

    check(LinkIdentity.id("sound") == "test.sound" && LinkIdentity.label("sound") == "local.utilitumus.test.sound", "личность выводится из имени модуля в сборке со швом")
    check(ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] == "local.utilitumus.test.kit.\(probeName)", "домен настроек выведен из имени модуля")

    let current = KitLink.protocolVersion
    check(KitLink.isCompatible(LinkHello(id: id, version: "1", protocolVersion: current + 1, oldestProtocolVersion: current)), "диапазон версий: утилита новее, но понимает нашу — принята")
    check(!KitLink.isCompatible(LinkHello(id: id, version: "1", protocolVersion: current + 1)), "диапазон версий: утилита новее и понимает только свою — отказ")
    check(!KitLink.isCompatible(LinkHello(id: id, version: "1", protocolVersion: KitLink.oldestProtocolVersion - 1)), "диапазон версий: утилита старее нашего диапазона — отказ")

    func accepted(_ text: String, limit: Int = 1024) -> ProbeAction? {
        LinkWire.decodeAction(ProbeAction.self, from: Data(text.utf8), limit: limit)
    }
    check(accepted(#"{"setLevel":{"_0":5}}"#) == .setLevel(5), "действие принято")
    check(accepted(#"{"pair":{"a":1,"b":"x"}}"#) == .pair(a: 1, b: "x"), "действие с двумя полями принято")
    check(accepted(#"{"setLevel":{"_0":5}}"#, limit: 5) == nil, "длиннее предела — отказ")
    for (name, payload) in [
        ("чужой ключ рядом", #"{"setLevel":{"_0":5},"x":1}"#),
        ("два действия", #"{"setLevel":{"_0":5},"setAttention":{"_0":true}}"#),
        ("чужой ключ внутри", #"{"setLevel":{"_0":5,"x":1}}"#),
        ("нет значения", #"{"setLevel":{}}"#),
        ("не тот тип", #"{"setLevel":{"_0":"5"}}"#),
        ("поле потерялось", #"{"pair":{"a":1}}"#),
        ("поле лишнее", #"{"pair":{"a":1,"b":"x","c":2}}"#),
        ("не объект", #"{"setLevel":5}"#),
        ("пробелы: не канонический вид", #"{"setLevel": {"_0":5}}"#),
        ("поля не по порядку: не канонический вид", #"{"pair":{"b":"x","a":1}}"#),
        ("повтор ключа", #"{"setLevel":{"_0":5},"setLevel":{"_0":6}}"#),
        ("неизвестное", #"{"explode":{}}"#),
        ("пустой объект", "{}"),
        ("массив", #"[{"setLevel":{"_0":5}}]"#),
    ] {
        check(accepted(payload) == nil, "\(name): отказ: \(payload)")
    }
    let refused = LinkWire.handle(Data("{".utf8), as: ProbeAction.self, limit: 1024, state: { level(7) }) { _ in
        check(false, "мусор не должен дойти до действия")
        return nil
    }
    let reply = try? JSONDecoder().decode(LinkReply<ProbeState>.self, from: refused)
    check(reply?.error != nil && reply?.state == level(7), "handle: мусор — ошибка и прежнее состояние")
}

// MARK: - Модель на управляемой связи

@MainActor func toleranceChecks() async {
    let (model, script) = scripted()
    var everFalse = false
    let watcher = model.$responding.sink { if !$0 { everFalse = true } }
    defer { watcher.cancel() }

    let first = Task { await model.read() }
    await settle()
    script.failRead()
    await settle()
    check(model.responding && script.reads.count == 1, "первый сбой чтения: страница не переключилась, второе чтение ушло сразу")
    script.answerRead(level(3))
    await first.value
    check(model.responding && model.state == level(3) && !everFalse, "второе чтение удалось: «не отвечает» ни разу не показан")

    let second = Task { await model.read() }
    await settle()
    script.failRead()
    await settle()
    script.answerRead(level(4))
    await second.value
    check(!everFalse, "удача обнуляет счёт: снова один сбой терпится")

    let third = Task { await model.read() }
    await settle()
    script.failRead()
    await settle()
    script.failRead()
    await third.value
    check(!model.responding && script.reads.isEmpty, "второй сбой подряд: не отвечает, третьего чтения нет")
    check(model.state == level(4), "не отвечает: на экране последнее известное состояние")

    let fourth = Task { await model.read() }
    await settle()
    script.answerRead(level(5))
    await fourth.value
    check(model.responding && model.state == level(5), "ответила: страница вернулась")

    let (blocked, blockedScript) = scripted(canRead: { false })
    blocked.refresh()
    blocked.setScreenOpen(false)
    await settle()
    check(blockedScript.reads.isEmpty, "canRead false: refresh не трогает связь")
}

@MainActor func staleChecks() async {
    let (model, script) = scripted()
    let older = Task { await model.read() }
    await settle()
    let newer = Task { await model.read() }
    await settle()
    script.answerRead(1, level(2))
    await newer.value
    check(model.state == level(2), "новое чтение пришло первым: показано")
    script.answerRead(0, level(1))
    await older.value
    check(model.state == level(2), "старое чтение опоздало: отброшено")

    // Старое чтение упало после нового удачного: на «не отвечает» не влияет.
    let staleFail = Task { await model.read() }
    await settle()
    let fresh = Task { await model.read() }
    await settle()
    script.answerRead(1, level(3))
    await fresh.value
    script.failRead(0)
    await staleFail.value
    check(model.responding && script.reads.isEmpty, "старое чтение упало позже нового: не считается и не повторяется")

    // Ответ действия устарел: состояние отброшено, а текст отказа важен.
    let action = Task { await model.perform(.setAttention(true)) }
    await settle()
    let read = Task { await model.read() }
    await settle()
    script.answerRead(level(9))
    await read.value
    script.answerAction(level(1), error: "Отказ")
    await action.value
    check(model.state == level(9), "ответ действия опоздал за чтением: его состояние отброшено")
    check(model.actionError == "Отказ", "но текст отказа показан")
    check(model.responding, "и связь считается живой")

    // Чтение, начатое до действия, не сбрасывает показанное действие.
    let before = Task { await model.read() }
    await settle()
    let pending = Task { await model.perform(.setLevel(50)) }
    await settle()
    check(model.state.level == 50, "действие показано сразу")
    script.answerRead(level(9))
    await before.value
    check(model.state.level == 50, "старое чтение не стирает ещё не отвеченное действие")
    script.answerAction(level(50))
    await pending.value
    check(model.state == level(50) && model.actionError == nil, "ответ подтвердил, текст отказа убран")

    // Чтение, начатое после действия, видит его результат: действие больше не накладывается сверху.
    let sent = Task { await model.perform(.setLevel(60)) }
    await settle()
    let after = Task { await model.read() }
    await settle()
    script.answerRead(level(61))
    await after.value
    check(model.state.level == 61, "чтение после действия: показано состояние утилиты, действие сверху не лежит")
    script.answerAction(level(60))
    await sent.value
    check(model.state.level == 61, "опоздавший ответ этого действия отброшен")
}

@MainActor func rollbackChecks() async {
    let (model, script) = scripted()
    let rejected = Task { await model.perform(.setLevel(500)) }
    await settle()
    check(model.state.level == 500, "оптимизм: значение на экране до ответа")
    script.answerAction(level(0), error: "Больше 100 нельзя")
    await rejected.value
    check(model.state.level == 0 && model.actionError == "Больше 100 нельзя", "отказ: откат по ответу и текст")

    let lost = Task { await model.perform(.setLevel(7)) }
    await settle()
    check(model.state.level == 7, "оптимизм перед сбоем связи")
    script.failAction()
    await lost.value
    check(model.state.level == 0 && model.actionError != nil, "сбой связи: откат и текст")
    check(model.responding, "сбой действия не значит «не отвечает»")

    // Два действия в пути, первое отвергнуто: второе остаётся на экране.
    let one = Task { await model.perform(.setLevel(11)) }
    await settle()
    let two = Task { await model.perform(.setLine("второе")) }
    await settle()
    check(model.state.level == 11 && model.state.line == "второе", "оба действия на экране")
    script.answerAction(0, level(0), error: "Отказ")
    await one.value
    check(model.state.level == 0 && model.state.line == "второе", "первое откатилось, второе ещё показано")
    var confirmed = level(0)
    confirmed.line = "второе"
    script.answerAction(0, confirmed)
    await two.value
    check(model.state == confirmed && model.actionError == nil, "второе подтвердилось, текст отказа первого снят его успехом")
}

@MainActor func coalescingChecks() async {
    let key: (ProbeAction) -> String? = {
        if case .setLevel = $0 { return "level" }
        if case .setLine = $0 { return "line" }
        return nil
    }
    let (model, script) = scripted(coalesce: key)
    let first = Task { await model.perform(.setLevel(1)) }
    await settle()
    for value in 2...100 { model.send(.setLevel(value)) }
    await settle()
    check(script.actions.count == 1, "100 значений подряд: в пути одно (\(script.actions.count))")
    check(model.state.level == 100, "на экране последнее значение, без ожидания ответа")
    script.answerAction(level(1))
    await settle()
    check(model.state.level == 100, "ответ на первое не откатывает к нему")
    check(script.actions.count == 1 && script.actions[0].sent == LinkWire.encoded(ProbeAction.setLevel(100)), "дальше ушло сразу последнее, промежуточные склеены")
    script.answerAction(level(100))
    await first.value
    check(script.actions.isEmpty && model.state.level == 100, "после ответа больше ничего не уходит")

    let again = Task { await model.perform(.setLevel(5)) }
    await settle()
    let other = Task { await model.perform(.setLine("x")) }
    await settle()
    let plain = Task { await model.perform(.setAttention(true)) }
    let plain2 = Task { await model.perform(.setAttention(false)) }
    await settle()
    check(script.actions.count == 4, "другой ключ и действия без ключа не склеиваются (\(script.actions.count))")
    while !script.actions.isEmpty { script.answerAction(level(5)) }
    for task in [again, other, plain, plain2] { await task.value }
}

/// Какой поток разбирал ответ.
nonisolated(unsafe) var decodedOnMain: Bool?
struct SpyState: Codable, Equatable, Sendable {
    var blob: String
    init(blob: String) { self.blob = blob }
    init(from decoder: Decoder) throws {
        decodedOnMain = Thread.isMainThread
        blob = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .blob)
    }
}

@MainActor func decodeChecks() async {
    var payload = Data()
    let link = RemoteModuleLink(state: { payload }, action: { _ in Data() }, setWatch: { _ in }, onPing: { _ in })
    let model = RemoteModuleModel<SpyState, ProbeAction>(id: "test.scripted", initial: SpyState(blob: ""), link: link, canRead: { true })
    payload = LinkWire.encoded(SpyState(blob: "мало"))
    await model.read()
    check(decodedOnMain == true && model.state.blob == "мало", "малый ответ разбирается на месте")
    payload = LinkWire.encoded(SpyState(blob: String(repeating: "б", count: 40_000)))
    await model.read()
    check(decodedOnMain == false && model.state.blob.count == 40_000, "большой ответ разбирается не на главном потоке")
}

@MainActor func pingChecks() async {
    let (model, script) = scripted(base: .changes)
    check(script.watches == [.changes], "модель сразу просит `.changes`, если нужна при закрытом экране")
    script.ping?()
    await settle()
    check(script.reads.count == 1, "пинг: одно чтение")
    for _ in 0..<5 { script.ping?() }
    await settle()
    check(script.reads.count == 1, "пинги во время чтения не плодят чтений")
    script.answerRead(level(1))
    await settle()
    check(script.reads.count == 1, "после чтения ровно одно ещё: состояние могло успеть измениться")
    script.answerRead(level(2))
    await settle()
    check(script.reads.isEmpty && model.state == level(2), "и всё: на этом тишина")

    model.setScreenOpen(true)
    model.setScreenOpen(false)
    check(script.watches == [.changes, .screen, .changes], "экран открыт и закрыт: аренда и обратно к базовому (\(script.watches))")
    let (closed, closedScript) = scripted()
    closed.setScreenOpen(true)
    closed.setScreenOpen(false)
    check(closedScript.watches == [.none, .screen, .none], "без базового после закрытия связь никого не держит (\(closedScript.watches))")
}

// MARK: - Самообновление

@MainActor func selfUpdateChecks(app: URL) async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("base-check-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    let zip = root.appendingPathComponent("update.zip")
    try! KitSigning.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
    let sum = SHA256.hash(data: try! Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
    let target = root.appendingPathComponent(app.lastPathComponent)
    let old = target.appendingPathComponent("old")
    func catalog(sha: String) -> CatalogApp {
        CatalogApp(id: id, version: "1.2.3", minHub: "0.6.0", url: zip, sha256: sha, sizeMB: 1)
    }
    func resetTarget() {
        try? fm.removeItem(at: target)
        try! fm.createDirectory(at: target, withIntermediateDirectories: true)
        fm.createFile(atPath: old.path, contents: Data())
    }
    /// Скачанное убирает установщик, поэтому копия.
    func install(_ app: CatalogApp, hook: () async throws -> Void) async -> Bool {
        let copy = root.appendingPathComponent("copy.zip")
        try? fm.removeItem(at: copy)
        try! fm.copyItem(at: zip, to: copy)
        do {
            try await SatelliteSelfUpdate.install(CatalogApp(id: app.id, version: app.version, minHub: app.minHub, url: copy, sha256: app.sha256, sizeMB: 1), target: target, beforeReplace: hook)
            return true
        } catch {
            return false
        }
    }

    resetTarget()
    var hookRan = false
    check(!(await install(catalog(sha: "00")) { hookRan = true }), "плохая сумма: отказ")
    check(!hookRan && fm.fileExists(atPath: old.path), "плохая сумма: модуль не останавливали, бандл не тронут")

    resetTarget()
    struct Refused: Error {}
    check(!(await install(catalog(sha: sum)) { throw Refused() }), "хук бросил: отказ")
    check(fm.fileExists(atPath: old.path), "хук бросил: бандл не тронут")

    resetTarget()
    var oldAtHook = false
    check(await install(catalog(sha: sum)) { oldAtHook = fm.fileExists(atPath: old.path) }, "обновление прошло")
    check(oldAtHook, "хук идёт до замены бандла")
    check(!fm.fileExists(atPath: old.path), "после хука бандл заменён")
}

// MARK: - Настоящая утилита

@MainActor enum Live {
    static var journalPath = ""
    static func journal() -> [String] {
        ((try? String(contentsOfFile: journalPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    static func clearJournal() { try? "".write(toFile: journalPath, atomically: false, encoding: .utf8) }
    static func journalLast(_ line: String) async -> Bool { await until(3) { journal().last == line } }

    static func state(_ client: LinkClient) async -> ProbeState? {
        guard let data = try? await client.moduleState() else { return nil }
        return try? JSONDecoder().decode(ProbeState.self, from: data)
    }

    static func action(_ client: LinkClient, _ action: ProbeAction) async -> LinkReply<ProbeState>? {
        guard let data = try? await client.moduleAction(LinkWire.encoded(action)) else { return nil }
        return try? JSONDecoder().decode(LinkReply<ProbeState>.self, from: data)
    }

    /// После выхода launchd поднимает утилиту по первому сообщению, иногда не сразу.
    static func wake(_ client: LinkClient) async -> Bool {
        for _ in 0..<60 {
            if (try? await client.hello()) != nil { return true }
            await pause(0.25)
        }
        return false
    }

    static func model() -> RemoteModuleModel<ProbeState, ProbeAction> {
        RemoteModuleModel(id: id, initial: ProbeState(), canRead: { true }, optimistic: probeOptimistic, coalesceKey: {
            if case .setLevel = $0 { return "level" }
            return nil
        })
    }

    static func holder() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["lease"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        // Первая строка — аренда взята.
        _ = pipe.fileHandleForReading.availableData
        return process
    }

    static func protocolChecks() async {
        let client = LinkClient(id: id)
        let hello = try? await client.hello()
        check(hello?.protocolVersion == KitLink.protocolVersion && hello?.oldestProtocolVersion == KitLink.oldestProtocolVersion, "hello называет диапазон версий (\(hello.map { "\($0.oldestProtocolVersion ?? -1)…\($0.protocolVersion)" } ?? "нет"))")

        guard let status = try? await client.status() else { return check(false, "статус не прочитан") }
        check(status.setupSteps.map(\.id) == ["grant", "tip", "broken"], "шаги настройки в статусе")
        check(status.needsSetup == 1, "needsSetup считает только обязательные и не сделанные (\(status.needsSetup))")
        check(status.setupSteps[1].kind == .recommendation && !status.setupSteps[2].verifiable, "вид и проверяемость шага дошли")
        check(status.quickActions.first?.title == "Поднять" && !status.attention, "быстрое действие в статусе, внимания нет")
        let unknown = try? await client.performSetupStep("выдуманный")
        check(unknown?.error != nil && !journal().contains("step выдуманный"), "неизвестный шаг: ошибка, модуль не вызван")
        let broken = try? await client.performSetupStep("broken")
        check(broken?.error == "Не вышло" && broken?.state.needsSetup == 1, "шаг не удался: текст ошибки и прежний счёт")
        let done = try? await client.performSetupStep("grant")
        check(done?.error == nil && done?.state.needsSetup == 0 && done?.state.setupSteps[0].done == true, "шаг сделан: новый статус в ответе")
        check(journal().contains("step grant"), "шаг выполнила утилита")

        let quick = try? await client.moduleAction(status.quickActions[0].action)
        let quickReply = quick.flatMap { try? JSONDecoder().decode(LinkReply<ProbeState>.self, from: $0) }
        check(quickReply?.state.level == 42 && quickReply?.error == nil, "байты быстрого действия приняты через moduleAction")
        _ = await action(client, .setAttention(true))
        let attention = try? await client.status()
        check(attention?.attention == true, "внимание в статусе")
        _ = await action(client, .setAttention(false))
        await checkBadActions(ProbeState.self, id: id, extra: [("чужой ключ", Data(#"{"setLevel":{"_0":5},"x":1}"#.utf8))])
    }

    static func modelChecks(utility: Int32) async {
        let other = LinkClient(id: id)
        let model = model()
        var everFalse = false
        let watcher = model.$responding.sink { if !$0 { everFalse = true } }
        defer { watcher.cancel() }
        await model.read()
        check(model.responding && model.state.running, "модель прочитала настоящую утилиту")

        // Утилита занята дольше срока одного чтения, но меньше двух.
        Task { _ = await action(other, .hang(2600)) }
        await pause(0.1)
        let started = ProcessInfo.processInfo.systemUptime
        await model.read()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        check(model.responding && !everFalse, String(format: "занята 2,6 с: один сбой чтения стерпели, за %.1f с страница не переключалась", elapsed))
        check(elapsed > 2, String(format: "сбой чтения правда был: %.1f с", elapsed))

        kill(utility, SIGSTOP)
        let ticks = TickWatch()
        await model.read()
        check(!model.responding, "зависла: второй сбой подряд, не отвечает")
        check(ticks.maxGap <= 0.3, String(format: "зависла: простой главного потока %.3f с", ticks.maxGap))
        kill(utility, SIGCONT)
        await pause(0.2)
        await model.read()
        check(model.responding, "ожила: снова отвечает")

        await model.perform(.setLevel(10))
        check(model.state.level == 10, "ответ утилиты показан")
        var saw500 = false
        let seen = model.$state.sink { if $0.level == 500 { saw500 = true } }
        await model.perform(.setLevel(500))
        seen.cancel()
        check(saw500, "оптимизм на настоящей связи: до ответа на экране 500")
        check(model.state.level == 10 && model.actionError == "Больше 100 нельзя", "отказ утилиты: откат к 10 и её текст")
        let truth = await state(other)
        check(truth?.level == 10, "у утилиты тоже 10")

        let handledBefore = truth?.handled ?? 0
        for value in 1...100 { model.send(.setLevel(value)) }
        await pause(0.01)
        check(model.state.level == 100, "ползунок: на экране сразу последнее значение")
        await pause(0.3)
        let after = await state(other)
        let handled = (after?.handled ?? 0) - handledBefore
        check(after?.level == 100, "ползунок: у утилиты последнее значение")
        check(handled < 20, "ползунок: из 100 значений дошло \(handled)")

        _ = await action(other, .setBlob(100_000))
        await model.read()
        check(model.state.blob.utf8.count == 100_000, "большое состояние прочитано")
        _ = await action(other, .setBlob(0))
    }

    static func pingChecks() async {
        var statusPosts = 0
        let observer = LinkStatusObserver(id: id) { statusPosts += 1 }
        defer { withExtendedLifetime(observer) {} }
        let other = LinkClient(id: id)
        _ = try? await other.hello()

        let silent = LinkClient(id: id)
        var silentPings = 0
        silent.onStateChanged = { silentPings += 1 }
        _ = try? await silent.hello()

        let client = LinkClient(id: id)
        var pings = 0
        client.onStateChanged = { pings += 1 }
        client.setWatch(.changes)
        _ = try? await client.hello()

        await pause(1.3)
        statusPosts = 0
        pings = 0
        _ = await action(other, .burst(200))
        check(await until(2) { pings > 0 }, "всплеск: пинг пришёл")
        await pause(1.6)
        check(pings >= 2 && pings <= 9, "всплеск 200 изменений за ~1 с: пингов \(pings), не больше 9")
        check(silentPings == 0, "без подписки пингов нет: \(silentPings)")
        check(statusPosts == 0, "статус не менялся: уведомлений, видных всем, нет (\(statusPosts))")

        let model = model()
        await model.read()
        pings = 0
        _ = await action(other, .setLevel(77))
        check(await until(1) { pings > 0 }, "одно изменение: пинг идёт сразу")

        // Строка статуса меняется часто: наружу не чаще раза в секунду.
        await pause(1.1)
        statusPosts = 0
        for index in 0..<20 {
            _ = await action(other, .setLine("строка \(index)"))
            await pause(0.05)
        }
        await pause(1.1)
        check(statusPosts >= 1 && statusPosts <= 4, "статус менялся 20 раз за ~1 с: уведомлений \(statusPosts), не больше 4")
        let line = try? await other.status().line
        check(line == "строка 19", "статус показывает последнее")
        _ = await action(other, .setLine("проба работает"))
        await pause(1.1)
        withExtendedLifetime(client) {}
    }

    static func leaseChecks(utility: Int32) async {
        let client = LinkClient(id: id)
        _ = try? await client.hello()
        clearJournal()
        client.setWatch(.changes)
        await pause(0.3)
        check(journal().isEmpty, "подписка на изменения — ещё не экран (\(journal()))")
        client.setWatch(.screen)
        check(await journalLast("screen true"), "аренда: экран открыт (\(journal()))")
        client.setWatch(.none)
        check(await journalLast("screen false"), "сами отпустили: экран закрыт")

        clearJournal()
        guard let first = try? holder(), let second = try? holder() else { return check(false, "держатели не запустились") }
        check(await journalLast("screen true"), "держатели взяли экран")
        check(journal() == ["screen true"], "два держателя: одно открытие (\(journal()))")
        kill(first.processIdentifier, SIGKILL)
        await pause(0.5)
        check(journal() == ["screen true"], "один из двух умер: экран ещё открыт")
        kill(second.processIdentifier, SIGKILL)
        check(await journalLast("screen false"), "клиент умер: аренда кончилась сама")
        check(journal() == ["screen true", "screen false"], "ровно одно закрытие (\(journal()))")
        first.waitUntilExit()
        second.waitUntilExit()

        // Умер подписчик: остальным сказать, что пора перечитать, если сами они были на этом же соединении.
        var posts = 0
        let observer = LinkStatusObserver(id: id) { posts += 1 }
        defer { withExtendedLifetime(observer) {} }
        guard let third = try? holder() else { return check(false, "держатель не запустился") }
        await pause(0.2)
        posts = 0
        kill(third.processIdentifier, SIGKILL)
        check(await until(2) { posts == 1 }, "подписчик пропал: один statusChanged")
        third.waitUntilExit()

        // Утилита умерла и поднялась: аренду модель берёт заново, как только прочитает.
        let model = model()
        model.setScreenOpen(true)
        await model.read()
        check(await journalLast("screen true"), "модель взяла экран при первом чтении")
        clearJournal()
        kill(utility, SIGKILL)
        await pause(0.2)
        check(await wake(LinkClient(id: id)), "launchd поднял утилиту")
        await model.read()
        check(await until(3) { journal().contains("screen true") }, "новая утилита снова знает про экран (\(journal()))")
        model.setScreenOpen(false)
        check(await journalLast("screen false"), "и отпускает")
    }

    static func passiveChecks() async {
        let defaults = Kit.defaults
        let client = LinkClient(id: id)
        func hub(running: Bool, version: String?, on: Bool = true, handed: Bool = false) {
            defaults.set(running, forKey: "Test.HubRunning")
            if let version { defaults.set(version, forKey: "Test.HubVersion") } else { defaults.removeObject(forKey: "Test.HubVersion") }
            defaults.set(on, forKey: SatelliteRole.hubModuleOnKey(id))
            defaults.set(handed, forKey: SatelliteRole.handedOverKey(id))
            defaults.synchronize()
        }
        /// `setEnabled` решает роль заново: настоящая смена центра у стенда только в настройках.
        func enable() async { try? await client.setEnabled(true) }

        hub(running: false, version: nil)
        await enable()
        var state = await state(client)
        check(state?.running == true, "центра нет: работает")

        clearJournal()
        client.setWatch(.screen)
        await pause(0.2)
        check(journal() == ["screen true"], "экран открыт у работающей")

        clearJournal()
        hub(running: true, version: "0.6.0")
        await enable()
        state = await Self.state(client)
        check(state?.running == false, "центр запущен, передачи нет: пассивная значит остановленная")
        check(journal() == ["screen false", "stop"], "сначала экран закрыт для модуля, потом стоп (\(journal()))")
        let line = try? await client.status().line
        check(line == "Ждём передачу от центра", "статус говорит почему: \(line ?? "нет")")

        clearJournal()
        hub(running: true, version: "0.6.0", handed: true)
        await enable()
        state = await Self.state(client)
        check(state?.running == true, "передача: снова работает")
        check(journal() == ["start", "screen true"], "сначала старт, потом экран (\(journal()))")

        clearJournal()
        hub(running: true, version: "0.5.3")
        await enable()
        state = await Self.state(client)
        check(state?.running == false && journal().contains("stop"), "старый центр: стоп (\(journal()))")

        clearJournal()
        hub(running: true, version: nil)
        await enable()
        state = await Self.state(client)
        check(state?.running == false && !journal().contains("start"), "версию центра не прочитать: работа не начинается (\(journal()))")

        hub(running: false, version: nil)
        await enable()
        state = await Self.state(client)
        check(state?.running == true, "центр вышел: работает")
        clearJournal()
        hub(running: true, version: nil)
        await enable()
        state = await Self.state(client)
        check(state?.running == false && journal().contains("stop"), "версию не прочитать, а работала: тоже стоп (\(journal()))")
        hub(running: false, version: nil)
        await enable()

        clearJournal()
        try? await client.setEnabled(false)
        state = await Self.state(client)
        check(state?.running == false && journal().contains("stop"), "выключена: стоп")
        client.setWatch(.none)
        await enable()
        state = await Self.state(client)
        check(state?.running == true, "включена: работает")

        // Запуск сразу пассивной: `start` не было ни разу.
        clearJournal()
        hub(running: true, version: "0.6.0")
        try? await client.quit(.update)
        await pause(0.2)
        clearJournal()
        check(await wake(client), "пассивная поднялась заново")
        state = await Self.state(client)
        check(state?.running == false, "запуск пассивной: не работает")
        check(!journal().contains("start"), "запуск пассивной: `start` не вызван (\(journal()))")
        hub(running: false, version: nil)
    }

    static func quitChecks() async {
        var client = LinkClient(id: id)
        _ = await wake(client)
        clearJournal()
        try? await client.quit(.update)
        check(await journalLast("stopForUpdate"), "quit(update): stopForUpdate (\(journal()))")
        await pause(0.3)
        check(journal() == ["stopForUpdate"], "quit(update): не stop и не удаление (\(journal()))")

        client = LinkClient(id: id)
        _ = await wake(client)
        clearJournal()
        try? await client.quit(.uninstall)
        check(await journalLast("stopForUninstall"), "quit(uninstall): stopForUninstall (\(journal()))")
        await pause(0.3)
        check(journal() == ["stopForUninstall"], "quit(uninstall): только он (\(journal()))")

        // Причина из будущей версии: настройка пользователя важнее.
        client = LinkClient(id: id)
        _ = await wake(client)
        clearJournal()
        let connection = NSXPCConnection(machServiceName: KitLink.machService(id), options: [])
        connection.setCodeSigningRequirement(KitLink.requirement(identifier: KitLink.bundleID(id)))
        connection.remoteObjectInterface = NSXPCInterface(with: LinkXPC.self)
        connection.resume()
        (connection.remoteObjectProxy as? LinkXPC)?.quit(reason: 77) {}
        check(await journalLast("stopForUpdate"), "неизвестная причина: как обновление (\(journal()))")
        connection.invalidate()
    }
}

// MARK: - Вход

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        Task { @MainActor in
            if await runCommonRole(args[1], id: id, foreignAction: LinkWire.encoded(ProbeAction.setLevel(66))) { return }
            switch args[1] {
            case "pure":
                wireChecks()
                await toleranceChecks()
                await staleChecks()
                await rollbackChecks()
                await coalescingChecks()
                await decodeChecks()
                await pingChecks()
                await selfUpdateChecks(app: URL(fileURLWithPath: args[2]))
                finish()
            case "live":
                Live.journalPath = args[2] + "/journal.log"
                let utility = Int32(args[3])!
                await Live.protocolChecks()
                await Live.modelChecks(utility: utility)
                await Live.pingChecks()
                await Live.leaseChecks(utility: utility)
                await Live.passiveChecks()
                await Live.quitChecks()
                finish()
            case "lease":
                // Держит экран, пока его не убьют.
                let client = LinkClient(id: id)
                client.setWatch(.screen)
                _ = try? await client.hello()
                print("держу")
                fflush(stdout)
                holding = client
            default:
                fatalError("неизвестная роль")
            }
        }
        RunLoop.main.run()
    }
}

nonisolated(unsafe) var holding: LinkClient?
