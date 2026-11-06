import AppKit
import SwiftUI

// Вкладка «Боты» в лаунчере, работа в утилите. Запуск: Tests/run-bots-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Ни один настоящий бот не трогается: файл bots.toml стенда
// лежит во временной папке, команды из него стенд не запускает (Kit.standRefuses), метки в нём либо чужие выдуманные,
// либо метка самой утилиты стенда.

let moduleID = "test.bots"
let utilityLabel = "local.utilitumus.test.bots"
let fm = FileManager.default
let markerDir = NSTemporaryDirectory() + "bots-check-\(getpid())"
let marker = markerDir + "/MARKER"

/// Не одно известное действие, а попытка протащить команду, путь или pid.
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"refresh":{},"x":1}"#),
    ("argv в просьбе", #"{"request":{"id":"alpha","verb":"start","argv":["/bin/rm","-rf","/"]}}"#),
    ("путь в просьбе", #"{"request":{"id":"alpha","verb":"start","path":"/bin/rm"}}"#),
    ("pid в просьбе", #"{"request":{"id":"alpha","verb":"stop","pid":1}}"#),
    ("pid в быстром действии", #"{"quick":{"id":"alpha","verb":"stop","pid":1}}"#),
    ("действие kill", #"{"kill":{"pid":1}}"#),
    ("действие run", #"{"run":{"argv":["/bin/rm"]}}"#),
    ("действие runCommand", #"{"runCommand":{"argv":["/bin/rm"]}}"#),
    ("кнопка, которой нет", #"{"request":{"id":"alpha","verb":"rm"}}"#),
    ("просьба без кнопки", #"{"request":{"id":"alpha"}}"#),
    ("id не строка", #"{"request":{"id":1,"verb":"start"}}"#),
    ("два действия", #"{"refresh":{},"cancel":{}}"#),
    ("confirm без плана", #"{"confirm":{}}"#),
    ("confirm не UUID", #"{"confirm":{"planID":"not-a-uuid"}}"#),
    ("чужой ключ внутри refresh", #"{"refresh":{"x":1}}"#),
    ("пустой объект", "{}"),
    ("массив", #"[{"refresh":{}}]"#),
]
let repeatedKey = #"{"request":{"id":"alpha","verb":"start"},"request":{"id":"beta","verb":"start"}}"#

// MARK: - Файл стенда

func writeBots(_ text: String?, mode: mode_t = 0o600) {
    let url = BotRegistry.url
    guard let text else { try? fm.removeItem(at: url); return }
    try? fm.removeItem(at: url)
    fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: Int(mode)])
    chmod(url.path, mode)
}

/// Три бота: alpha — метка самой утилиты стенда (работает), beta — выдуманная метка (остановлен), cfg — не хватает переменной.
func fixtureTOML() -> String {
    """
    [[bot]]
    id = "alpha"
    name = "Альфа"
    project = "demo"
    url = "http://127.0.0.1:8765/"
    launchd = ["\(utilityLabel)"]
    stop = ["/bin/echo", "stop-alpha"]
    restart = ["/bin/echo", "restart-alpha"]
    note = "Первый тестовый"

    [[bot]]
    id = "beta"
    name = "Бета"
    project = "demo"
    launchd = ["com.example.absent-bot"]
    start = ["/usr/bin/touch", "\(marker)"]

    [[bot]]
    id = "cfg"
    name = "Гамма"
    project = "other"
    launchd = ["com.example.absent-cfg"]
    start = ["/bin/echo", "start-cfg"]
    requires_env = ["BOTS_CHECK_UNSET_VARIABLE"]
    env_file = "\(markerDir)/absent.env"
    """
}

// MARK: - Чистая логика

func fixtureLaunchctl() -> String {
    "PID\tStatus\tLabel\n123\t0\tcom.example.alpha\n-\t0\tcom.example.beta\n-\t78\tcom.example.gamma-web\n-\t0\tcom.example.noise\n"
}

func logicPure() {
    let procs: [Int32: BotProc] = [
        123: BotProc(memMB: 100.4, start: 1_000_000, children: [124, 125]),
        124: BotProc(memMB: 50.2, start: 1_000_010, children: []),
        125: BotProc(memMB: 10, start: 1_000_020, children: [123]),   // кольцо: не должно зациклить
    ]
    let parsed = LaunchdList.parse(fixtureLaunchctl())
    check((parsed["com.example.alpha"] ?? nil) == 123 && parsed["com.example.beta"] != nil && (parsed["com.example.beta"] ?? 7) == nil, "launchctl list: pid и «-» разобраны")
    check(parsed["com.example.noise"] != nil && parsed.count == 4, "launchctl list: заголовок не метка, строк четыре")
    func spec(_ id: String, launchd: [String], commands: [BotVerb: BotCommand], env: [String] = [], envFile: String? = nil) -> BotSpec {
        BotSpec(id: id, name: id.uppercased(), project: "p", url: "https://host.example/panel", launchd: launchd, bundleIDs: [], commands: commands,
                requiresEnv: env, envFile: envFile, note: "")
    }
    let all: [BotVerb: BotCommand] = [.start: .argv(["a"]), .stop: .argv(["b"]), .restart: .argv(["c"])]
    let specs = [
        spec("up", launchd: ["com.example.alpha"], commands: all),
        spec("half", launchd: ["com.example.alpha", "com.example.beta"], commands: all),
        spec("down", launchd: ["com.example.beta"], commands: all),
        spec("nostart", launchd: ["com.example.beta"], commands: [.stop: .argv(["b"])]),
        spec("onlyrestart", launchd: ["com.example.alpha"], commands: [.restart: .argv(["c"])]),
        spec("cfg", launchd: ["com.example.gamma-web"], commands: all, env: ["BOTS_CHECK_UNSET_VARIABLE"], envFile: "/nonexistent/bots-check.env"),
        spec("ghost", launchd: ["com.example.not-there"], commands: all),
    ]
    let cards = BotsMonitor.cards(specs, launchd: parsed, now: Date(timeIntervalSince1970: 1_000_000 + 7200 + 30), probe: { procs[$0] }, ports: { $0.isEmpty ? [] : ["127.0.0.1:8765"] })
    let by = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
    check(by["up"]?.state == .running && by["half"]?.state == .partial && by["down"]?.state == .stopped, "статус по метке: работает, частично, остановлен")
    check(by["cfg"]?.state == .noConfig && by["ghost"]?.state == .stopped, "нет переменной — не настроен; метки нет в списке — остановлен")
    check(by["up"]?.memMB == 161 && by["up"]?.ports == ["127.0.0.1:8765"], "память — сумма поддерева (с кольцом), порт из процессов бота: \(by["up"]?.memMB ?? -1)")
    check(by["up"]?.uptime == 7200, "аптайм до минуты: \(by["up"]?.uptime ?? -1)")
    check(by["down"]?.verbs == [.start] && by["up"]?.verbs == [.stop, .restart] && by["half"]?.verbs == [.start, .stop, .restart], "кнопки по состоянию")
    check(by["nostart"]?.verbs.isEmpty == true, "у остановленного без start в файле кнопок нет")
    check(by["onlyrestart"]?.verbs == [.restart], "только описанные в файле: у работающего остаётся один restart")
    check(by["cfg"]?.verbs.isEmpty == true && by["cfg"]?.note.contains("BOTS_CHECK_UNSET_VARIABLE") == true, "не настроен: кнопок нет, в заметке имя переменной")
    check(BotsMonitor.safeURL("https://host.example/panel") != nil && BotsMonitor.safeURL("javascript:alert(1)") == nil
          && BotsMonitor.safeURL("file:///etc/passwd") == nil && BotsMonitor.safeURL("https://u:p@host.example/") == nil, "ссылка: только http и https без пароля")
    let json = String(decoding: LinkWire.encoded(BotsState(file: .ok, bots: cards, prompt: nil, running: false, notice: nil)), as: UTF8.self)
    check(!json.contains("\"a\"") && !json.contains("argv") && !json.contains("commands") && !json.contains("launchd") && !json.contains("com.example"), "в состоянии для центра нет ни команд, ни меток")

    // Дерево потомков на настоящем libproc: у процесса с дочерним sleep потомок виден.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try? child.run()
    let kids = BotsMonitor.liveProbe(getpid())?.children ?? []
    check(kids.contains(child.processIdentifier), "libproc: дочерний процесс виден в children")
    check((BotsMonitor.liveProbe(getpid())?.memMB ?? 0) > 1, "libproc: память процесса читается")
    child.terminate()
}

func envAndFile() {
    // Значения из .env не читаются и не показываются: только есть ключ или нет.
    let dir = markerDir
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let envPath = dir + "/present.env"
    fm.createFile(atPath: envPath, contents: Data("export BOTS_CHECK_KEY=value-that-must-never-appear\nOTHER=\n".utf8), attributes: [.posixPermissions: 0o600])
    func spec(_ names: [String]) -> BotSpec {
        BotSpec(id: "e\(names.joined())", name: "E", project: "p", url: nil, launchd: [], bundleIDs: [], commands: [:], requiresEnv: names, envFile: envPath, note: "")
    }
    check(BotRegistry.envMissing(spec(["BOTS_CHECK_KEY"])).isEmpty, "ключ задан — не хватает ничего")
    let missing = BotRegistry.envMissing(spec(["OTHER", "NOPE"]))
    check(missing == ["OTHER", "NOPE"], "пустое значение и отсутствие — не хватает обоих: \(missing)")
    let note = BotRegistry.noConfigNote(spec(["OTHER"]), missing: ["OTHER"])
    check(note.contains("OTHER") && note.contains("present.env") && !note.contains("value-that-must-never-appear"), "заметка называет ключ и имя файла, значения нет")

    // Права и разбор bots.toml.
    let url = URL(fileURLWithPath: dir + "/file.toml")
    func put(_ text: String, _ mode: Int) {
        try? fm.removeItem(at: url)
        fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
        chmod(url.path, mode_t(mode))
    }
    let good = "[[bot]]\nid = \"a\"\nname = \"A\"\nproject = \"p\"\nstart = [\"/bin/echo\"]\n"
    put(good, 0o600)
    var read = BotRegistry.read(url)
    check(read.exists && read.problem == nil && read.bots.count == 1, "файл 0600: прочитан")
    put(good, 0o644)
    read = BotRegistry.read(url)
    check(read.problem == nil && read.bots.count == 1, "файл 0644 (запись только хозяину): прочитан")
    for mode in [0o664, 0o666, 0o620, 0o602] {
        put(good, mode)
        read = BotRegistry.read(url)
        var unsafe = false
        if case .unsafe? = read.problem { unsafe = true }
        check(unsafe && read.bots.isEmpty, "файл \(String(mode, radix: 8)): отвергнут, ботов нет")
    }
    put(good, 0o600)
    chmod(dir, 0o777)
    read = BotRegistry.read(url)
    if case .unsafe? = read.problem { check(read.bots.isEmpty, "папка доступна всем на запись: файл отвергнут") } else { check(false, "папка 0777 не замечена") }
    chmod(dir, 0o700)
    check(BotRegistry.read(url).bots.count == 1, "права исправлены: файл снова читается (chmod не меняет время правки, кэш не мешает)")
    put("[[bot]\nid = ", 0o600)
    read = BotRegistry.read(url)
    check(read.exists && read.problem == .invalid && read.bots.isEmpty, "битый TOML: invalid, ботов нет")
    put("[[bot]]\nid = \"a\"\n", 0o600)
    check(BotRegistry.read(url).problem == nil && BotRegistry.read(url).bots.isEmpty, "запись без name и project пропущена")
    try? fm.removeItem(at: url)
    check(!BotRegistry.read(url).exists, "нет файла — missing")
    #if KIT_TEST_DEFAULTS
    let real = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Utilitumus/bots.toml").path
    check(BotRegistry.url.path != real && !BotRegistry.url.path.hasPrefix(Kit.realHome + "/"), "стенд читает файл из временной папки, не из настоящего дома")
    #endif
}

func isolationPure() {
    writeBots(fixtureTOML())
    try? fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
        _ = try BotRunner.run(.start, id: "beta", file: BotRegistry.url)
        check(false, "BotRunner в стенде запустил команду")
    } catch let e as BackgroundActionError {
        check(e.message.contains("Стенд не запускает"), "BotRunner в стенде отказал: «\(e.message)»")
    } catch { check(false, "BotRunner: \(error)") }
    check(!fm.fileExists(atPath: marker), "после отказа команда не выполнялась: маркера нет")
    do {
        _ = try BotRunner.run(.start, id: "nobody", file: BotRegistry.url)
        check(false, "неизвестный бот принят")
    } catch let e as BackgroundActionError {
        check(e.message.contains("устарело"), "неизвестный бот: «\(e.message)»")
    } catch {}
    do {
        _ = try BotRunner.run(.stop, id: "beta", file: BotRegistry.url)
        check(false, "кнопка, которой нет в файле, принята")
    } catch let e as BackgroundActionError {
        check(e.message.contains("устарело"), "кнопки нет в файле: «\(e.message)»")
    } catch {}
    writeBots(fixtureTOML(), mode: 0o666)
    do {
        _ = try BotRunner.run(.start, id: "beta", file: BotRegistry.url)
        check(false, "команда из небезопасного файла принята")
    } catch let e as BackgroundActionError {
        check(e.message.contains("Не запускаю"), "небезопасный файл: команды не запускаются: «\(e.message)»")
    } catch {}
    writeBots(nil)
}

func wirePure() {
    let card = BotCard(id: "alpha", name: "A", project: "p", state: .running, memMB: 10, uptime: 60, ports: ["1"], url: nil, note: "", verbs: [.stop])
    let state = BotsState(file: .ok, bots: [card], prompt: BotsPrompt(id: UUID(), title: "t", message: "m", command: "c", confirmTitle: "b", destructive: true),
                          running: false, notice: BotsNotice(text: "x", isError: true))
    check((try? JSONDecoder().decode(BotsState.self, from: JSONEncoder().encode(state))) == state, "BotsState переживает кодирование")
    let actions: [BotsAction] = [.refresh, .request(id: "alpha", verb: .restart), .cancel, .confirm(planID: UUID()), .dismissNotice, .quick(id: "a", verb: .stop)]
    for action in actions {
        check((try? JSONDecoder().decode(BotsAction.self, from: JSONEncoder().encode(action))) == action, "BotsAction \(action) переживает кодирование")
        check(LinkWire.decodeAction(BotsAction.self, from: LinkWire.encoded(action), limit: BotsStore.maxActionBytes) == action, "BotsAction \(action): проходит канонический разбор")
    }
    for (name, payload) in notOneAction + [("повтор ключа", repeatedKey)] {
        check(LinkWire.decodeAction(BotsAction.self, from: Data(payload.utf8), limit: BotsStore.maxActionBytes) == nil, "\(name) не разбирается")
    }
    let long = LinkWire.encoded(BotsAction.request(id: String(repeating: "a", count: 2000), verb: .start))
    check(LinkWire.decodeAction(BotsAction.self, from: long, limit: BotsStore.maxActionBytes) == nil, "слишком длинный id не разбирается")
}

// MARK: - Утилита

@MainActor func ids(_ model: RemoteBotsModel) -> String { model.state.bots.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: " ") }

@MainActor func garbage() async {
    await checkBadActions(BotsState.self, id: moduleID, extra: (notOneAction + [("повтор ключа", repeatedKey)]).map { ($0.0, Data($0.1.utf8)) })
}

/// Замеры идут только под арендой экрана: без неё утилита файл не перечитывает.
@MainActor func lease() async {
    let model = RemoteBotsModel.shared
    writeBots(fixtureTOML())
    await model.perform(.refresh)
    check(await until(5) { model.state.bots.count == 3 }, "refresh: три бота из файла, \(ids(model))")
    // Файл меняется, экран закрыт: за два срока опроса (5 с) утилита не должна ничего перечитать.
    writeBots(fixtureTOML().replacingOccurrences(of: "\"Бета\"", with: "\"Бета2\""))
    await pause(11.5)
    await model.read()
    check(model.state.bots.first { $0.id == "beta" }?.name == "Бета", "экран закрыт: файл не перечитывался 11 с")
    model.setScreenOpen(true)
    check(await until(6) { model.state.bots.first { $0.id == "beta" }?.name == "Бета2" }, "экран открыт: файл перечитан")
    writeBots(fixtureTOML().replacingOccurrences(of: "\"Бета\"", with: "\"Бета3\""))
    check(await until(8) { model.state.bots.first { $0.id == "beta" }?.name == "Бета3" }, "экран открыт: опрос идёт сам")
    model.setScreenOpen(false)
    await pause(0.5)
    writeBots(fixtureTOML())
    await pause(7)
    await model.read()
    check(model.state.bots.first { $0.id == "beta" }?.name == "Бета3", "экран снова закрыт: опрос остановился")
    await model.perform(.refresh)
    check(await until(5) { model.state.bots.first { $0.id == "beta" }?.name == "Бета" }, "ручное обновление работает и при закрытом экране")
}

@MainActor func states() async {
    let model = RemoteBotsModel.shared
    let by = Dictionary(uniqueKeysWithValues: model.state.bots.map { ($0.id, $0) })
    check(by["alpha"]?.state == .running, "alpha: метка самой утилиты — работает")
    check(by["beta"]?.state == .stopped && by["beta"]?.verbs == [.start], "beta: метки нет в launchctl — остановлен, кнопка «Включить»")
    check(by["cfg"]?.state == .noConfig && by["cfg"]?.verbs.isEmpty == true, "cfg: нет переменной — не настроен, кнопок нет")
    check((by["alpha"]?.memMB ?? 0) > 1 && by["alpha"]?.verbs == [.stop, .restart], "alpha: память процесса утилиты, кнопки «Выключить» и «Перезапустить»")
    check(by["alpha"]?.url == "http://127.0.0.1:8765/" && by["alpha"]?.note == "Первый тестовый", "ссылка на панель и заметка дошли")
    check(by["alpha"]?.project == "demo", "проект дошёл")
    let json = String(decoding: LinkWire.encoded(model.state), as: UTF8.self)
    check(!json.contains("/usr/bin/touch") && !json.contains(markerDir) && !json.contains(utilityLabel), "в состоянии нет команд, путей и меток launchd")
}

@MainActor func actions() async {
    let model = RemoteBotsModel.shared
    // Как в жизни: действие нажимают на открытом экране, он и ведёт аренду, по которой утилита сообщает о смене.
    model.setScreenOpen(true)
    defer { model.setScreenOpen(false) }
    guard let beta = model.state.bots.first(where: { $0.id == "beta" }) else { return check(false, "beta не найден: \(ids(model))") }
    check(model.state.prompt == nil, "до просьбы подтверждения нет")
    // Кнопки, которой в файле нет или которая не подходит состоянию, на просьбу не откликаются.
    for (id, verb) in [("alpha", BotVerb.start), ("beta", .stop), ("beta", .restart), ("cfg", .start), ("nobody", .start)] {
        await model.perform(.request(id: id, verb: verb))
        check(model.actionError != nil && model.state.prompt == nil, "просьба \(id) \(verb.rawValue): отказ «\(model.actionError ?? "нет")», подтверждения нет")
    }
    await model.perform(.request(id: beta.id, verb: .start))
    check(model.state.prompt != nil, "просьба: утилита показала подтверждение")
    guard let prompt = model.state.prompt else { return check(false, "подтверждения нет") }
    check(prompt.title == "Включить Бета" && prompt.command.contains("/usr/bin/touch") && prompt.confirmTitle == "Включить" && !prompt.destructive, "подтверждение называет действие и команду из файла")
    check(!fm.fileExists(atPath: marker), "до подтверждения ничего не запущено")
    await model.perform(.confirm(planID: UUID()))
    check(model.actionError != nil && model.state.prompt?.id == prompt.id, "чужой id плана: отказ, настоящий план жив")
    await model.perform(.cancel)
    check(model.state.prompt == nil && model.actionError == nil, "отмена закрывает подтверждение")
    await model.perform(.confirm(planID: prompt.id))
    check(model.actionError != nil, "подтверждение отменённого плана: отказ")
    await model.perform(.request(id: "beta", verb: .start))
    check(model.actionError == nil && model.state.prompt != nil, "вторая просьба: \(model.actionError ?? "ошибки нет")")
    guard let second = model.state.prompt else { return check(false, "второго подтверждения нет: \(model.actionError ?? "без ошибки"), \(ids(model))") }
    model.confirm(second.id)
    check(await until(5) { model.state.notice != nil }, "подтверждение: пришёл результат")
    check(model.state.notice?.isError == true && model.state.notice?.text.contains("Стенд не запускает") == true, "стенд отказал в запуске: «\(model.state.notice?.text ?? "нет")»")
    check(!fm.fileExists(atPath: marker), "команда бота не выполнялась: маркера нет")
    // Быстрое действие идёт тем же путём.
    await model.perform(.quick(id: "beta", verb: .start))
    check(await until(5) { model.state.notice?.isError == true && !model.state.running }, "быстрое действие: тот же отказ стенда")
    check(!fm.fileExists(atPath: marker), "быстрое действие: маркера нет")
    await model.perform(.quick(id: "alpha", verb: .start))
    check(model.actionError != nil, "быстрое действие, которого у бота нет: отказ")
    await model.perform(.dismissNotice)
    check(await until(2) { model.state.notice == nil }, "баннер закрывается")

    // Статус для дашборда и меню: счёт без имён, быстрые действия с подтверждением.
    let status = try? await LinkClient(id: moduleID).status()
    check(status?.line == "1 из 3 работает" || status?.line.hasSuffix("работает") == true, "строка статуса — счёт: «\(status?.line ?? "нет")»")
    check(status?.line.contains("Альфа") == false && status?.attention == false, "в строке нет имён, внимания нет")
    let quick = status?.quickActions ?? []
    check(quick.count == 2 && quick.allSatisfy { $0.confirm != nil }, "быстрых действий два (альфа выключить, бета включить), у каждого подтверждение: \(quick.map(\.title))")
    check(quick.first.map { LinkWire.decodeAction(BotsAction.self, from: $0.action, limit: 4096) } != nil, "быстрое действие — обычное действие утилиты, id и кнопка")
}

@MainActor func fileProblems() async {
    let model = RemoteBotsModel.shared
    let link = LinkClient(id: moduleID)
    writeBots(fixtureTOML(), mode: 0o666)
    await model.perform(.refresh)
    check(await until(5) { model.state.file.kind == .unsafe && model.state.bots.isEmpty }, "bots.toml 0666: утилита его отвергла, ботов нет, на экране причина «\(model.state.file.detail)»")
    let status = try? await link.status()
    check(status?.attention == true && status?.line == "bots.toml небезопасен" && status?.quickActions.isEmpty == true, "статус: внимание, быстрых действий нет")
    await model.perform(.quick(id: "beta", verb: .start))
    check(model.actionError != nil && !fm.fileExists(atPath: marker), "быстрое действие при небезопасном файле отвергнуто")
    let unsafeShot = await Stand.open(.dusk)
    Stand.save(unsafeShot, "dusk-unsafe")
    chmod(BotRegistry.url.path, 0o600)
    await model.perform(.refresh)
    check(await until(5) { model.state.file.kind == .ok && model.state.bots.count == 3 }, "права исправлены: боты вернулись")
    writeBots("[[bot]\nid = ")
    await model.perform(.refresh)
    check(await until(5) { model.state.file.kind == .invalid && model.state.bots.isEmpty }, "битый TOML: invalid, на экране пустое состояние")
    Stand.save(await Stand.open(.dusk), "dusk-invalid")
    writeBots(nil)
    await model.perform(.refresh)
    check(await until(5) { model.state.file.kind == .missing && model.state.bots.isEmpty }, "файла нет: missing")
    let statusMissing = try? await link.status()
    check(statusMissing?.line == "bots.toml не найден", "статус без файла: «\(statusMissing?.line ?? "нет")»")
}

// MARK: - Пиксели

@MainActor func pinLocal(_ state: BotsState) { BotsStore.shared.testPin(state) }

@MainActor func pixels() async {
    let model = RemoteBotsModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    var seen: [NSBitmapImageRep] = []
    let scenarios: [(String, String?, mode_t)] = [("bots", fixtureTOML(), 0o600), ("empty", nil, 0o600), ("unsafe", fixtureTOML(), 0o666)]
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        for (name, text, mode) in scenarios {
            writeBots(text, mode: mode)
            await model.perform(.refresh)
            check(await until(5) { model.state.file.kind == (text == nil ? .missing : mode == 0o666 ? .unsafe : .ok) && (text == nil || mode == 0o666 || model.state.bots.count == 3) }, "\(themeName) \(name): утилита в нужном состоянии")
            await model.read()
            // Локальный экран закреплён на том же состоянии, что получил центр от утилиты.
            modules.setExternal(.bots, false)
            pinLocal(model.state)
            let local = await Stand.open(theme)
            Stand.save(local, "\(themeName)-\(name)-local")
            modules.setExternal(.bots, true)
            await registry.update()
            check(registry.isEnabled(.bots), "\(themeName) \(name): реестр видит утилиту включённой")
            let remote = await Stand.open(theme)
            Stand.save(remote, "\(themeName)-\(name)-remote")
            let diff = differingPixels(local, remote)
            check(diff == 0, "\(themeName) \(name): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            seen.append(remote)
        }
        check(differingPixels(seen[seen.count - 3], seen[seen.count - 2]) > 0 && differingPixels(seen[seen.count - 2], seen[seen.count - 1]) > 0, "\(themeName): три состояния выглядят по-разному, снимки не пустые")
    }
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    BotsStore.shared.testUnpin()
    writeBots(nil)
}

// MARK: - Вход

@main
enum Main {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Только чистая логика, без утилиты: для поломок проверки (`run-bots-remote-check.sh pure`).
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "pure" {
            MainActor.assumeIsolated {
                try? fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                logicPure()
                envAndFile()
                isolationPure()
                wirePure()
                try? fm.removeItem(atPath: markerDir)
                finish()
            }
        }
        MainActor.assumeIsolated {
            ModuleCheck.main(.bots, foreignAction: LinkWire.encoded(BotsAction.quick(id: "beta", verb: .start))) { utility in
                let realFile = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Utilitumus/bots.toml").path
                let realBefore = (try? fm.attributesOfItem(atPath: realFile))?[.modificationDate] as? Date
                try? fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                logicPure()
                envAndFile()
                isolationPure()
                wirePure()
                await garbage()
                await lease()
                await states()
                await actions()
                await fileProblems()
                await pixels()
                writeBots(nil)
                let realAfter = (try? fm.attributesOfItem(atPath: realFile))?[.modificationDate] as? Date
                check(realBefore == realAfter, "настоящий bots.toml не менялся (только дата правки, содержимое не читалось)")
                check(!fm.fileExists(atPath: marker), "за весь прогон ни одна команда бота не выполнена")
                try? fm.removeItem(atPath: markerDir)
            }
        }
    }
}
