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
    ("find с чужим ключом", #"{"find":{"path":"/"}}"#),
    ("add с путём", #"{"add":{"id":"x","path":"/bin/rm"}}"#),
    ("add с командой", #"{"add":{"id":"x","argv":["/bin/rm"]}}"#),
    ("add с меткой", #"{"add":{"id":"x","label":"com.example.y"}}"#),
    ("add без id", #"{"add":{}}"#),
    ("add: id не строка", #"{"add":{"id":5}}"#),
    ("dismissFound с полем", #"{"dismissFound":{"x":1}}"#),
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
        _ = try BotRunner.run(.start, id: "beta", file: BotRegistry.url, expected: ["/usr/bin/touch", marker])
        check(false, "BotRunner в стенде запустил команду")
    } catch let e as BackgroundActionError {
        check(e.message.contains("Стенд не запускает"), "BotRunner в стенде отказал: «\(e.message)»")
    } catch { check(false, "BotRunner: \(error)") }
    check(!fm.fileExists(atPath: marker), "после отказа команда не выполнялась: маркера нет")
    do {
        _ = try BotRunner.run(.start, id: "beta", file: BotRegistry.url, expected: ["/bin/другая"])
        check(false, "команда не та, что подтвердили, а запуск принят")
    } catch let e as BackgroundActionError {
        check(e.message == BotRunner.changedMessage, "подтверждали другую команду: «\(e.message)»")
    } catch {}
    let tricky = BotRunner.shown(["/bin/x\u{202E}y", "a\u{200F}b\u{2066}c\nd\u{7}"])
    check(!tricky.unicodeScalars.contains { [0x202E, 0x200F, 0x2066, 0x0A, 0x07].contains($0.value) }, "в показанной команде нет смены направления и управляющих символов: \(tricky)")
    check(tricky.contains("/bin/x"), "и сама команда видна")
    check(BotRunner.fingerprint(["a\0b"]) != BotRunner.fingerprint(["a", "b"]), "отпечаток: ноль внутри части и две части различаются")
    check(BotRunner.fingerprint(["ab"]) != BotRunner.fingerprint(["a", "b"]) && BotRunner.fingerprint(["1:a"]) != BotRunner.fingerprint(["a"]), "отпечаток: склейка и длина внутри части не совпадают с другой командой")
    check(BotRunner.fingerprint(["a", "b"]) == BotRunner.fingerprint(["a", "b"]), "отпечаток: одна команда, один отпечаток")
    do {
        _ = try BotRunner.run(.start, id: "nobody", file: BotRegistry.url, expected: [])
        check(false, "неизвестный бот принят")
    } catch let e as BackgroundActionError {
        check(e.message.contains("устарело"), "неизвестный бот: «\(e.message)»")
    } catch {}
    do {
        _ = try BotRunner.run(.stop, id: "beta", file: BotRegistry.url, expected: [])
        check(false, "кнопка, которой нет в файле, принята")
    } catch let e as BackgroundActionError {
        check(e.message.contains("устарело"), "кнопки нет в файле: «\(e.message)»")
    } catch {}
    writeBots(fixtureTOML(), mode: 0o666)
    do {
        _ = try BotRunner.run(.start, id: "beta", file: BotRegistry.url, expected: ["/usr/bin/touch", marker])
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
    let actions: [BotsAction] = [.refresh, .request(id: "alpha", verb: .restart), .cancel, .confirm(planID: UUID()), .dismissNotice, .quick(id: "a", verb: .stop, sum: BotRunner.fingerprint(["/bin/x"]))]
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


// MARK: - Поиск ботов

let planted = ["PLANTED-PLIST-VALUE", "PLANTED-ARG-VALUE", "PLANTED-DOTENV-VALUE", "PLANTED-SOURCE-VALUE", "PLANTED-GENERIC-VALUE"]
let craftedDir = "we\"ird\nname"
let craftedLabel = "com.example.x\"\n[[bot]]\nid = \"evil"

func put(_ path: String, _ text: String, mode: Int = 0o600) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    fm.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
}

func agentPlist(_ home: String, _ file: String, label: String, work: String? = nil, args: [String] = ["/usr/bin/python3", "-V"], env: [String: String]? = nil) {
    var plist: [String: Any] = ["Label": label, "ProgramArguments": args]
    if let work { plist["WorkingDirectory"] = work }
    if let env { plist["EnvironmentVariables"] = env }
    let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    put(home + "/Library/LaunchAgents/" + file, String(decoding: data ?? Data(), as: UTF8.self), mode: 0o644)
}

/// Дерево для поиска: поддельные агенты и проекты. `home` — временная папка, настоящий дом не участвует.
func seedDiscovery(_ home: String) {
    let p = home + "/proj"
    // Верно по библиотеке. В плисте и аргументах лежат «токены»: ни один не должен выйти в результат.
    put(p + "/news/requirements.txt", "aiogram==3.4\nrequests\n")
    put(p + "/news/main.py", "from aiogram import Bot\nTOKEN = \"PLANTED-SOURCE-VALUE\"\n")
    agentPlist(home, "a1.plist", label: "com.example.news-digest", work: p + "/news",
               args: ["/usr/bin/python3", p + "/news/main.py", "--token", "PLANTED-ARG-VALUE", "123456:PLANTED-ARG-VALUE"],
               env: ["TELEGRAM_BOT_TOKEN": "PLANTED-PLIST-VALUE", "LANG": "ru"])
    // Верно по ключу в .env.
    put(p + "/envapp/.env", "# токен\nexport TELEGRAM_BOT_TOKEN=PLANTED-DOTENV-VALUE\nDEBUG=1\n")
    agentPlist(home, "a2.plist", label: "com.example.digest-env", work: p + "/envapp")
    // Только слабый признак: название. Зависимостей нет.
    put(p + "/plain/README", "ничего\n")
    agentPlist(home, "a3.plist", label: "com.example.helperbot", work: p + "/plain")
    // Не бот: зависимости без Telegram, чужой ключ.
    put(p + "/backup/requirements.txt", "requests\nboto3\n")
    put(p + "/backup/.env", "DB_PASSWORD=PLANTED-DOTENV-VALUE\n")
    agentPlist(home, "a4.plist", label: "com.example.backup", work: p + "/backup")
    // Подделанная метка: кавычки и переводы строк. В команду она не попадёт никогда.
    put(p + "/crafted/requirements.txt", "aiogram\n")
    agentPlist(home, "a5.plist", label: craftedLabel, work: p + "/crafted")
    // Подделанная папка: кавычка и перевод строки в имени. Предлагается, а при записи экранируется.
    put(p + "/" + craftedDir + "/requirements.txt", "telethon\n")
    agentPlist(home, "a6.plist", label: "com.example.weird-dir", work: p + "/" + craftedDir)
    // По импорту; проект выведен из пути скрипта.
    put(p + "/srcapp/bot_main.py", "import os\nimport telebot\n")
    agentPlist(home, "a7.plist", label: "com.example.srcapp", args: ["/usr/bin/python3", p + "/srcapp/bot_main.py"])
    // Предел размера: библиотека за пределом чтения не видна. Вложенные папки не обходятся.
    put(p + "/huge/requirements.txt", String(repeating: "x\n", count: 100_000) + "aiogram\n")
    agentPlist(home, "a8.plist", label: "com.example.huge", work: p + "/huge")
    put(p + "/nested/sub/requirements.txt", "aiogram\n")
    agentPlist(home, "a9.plist", label: "com.example.nested", work: p + "/nested")
    // Папка закрыта: это «нет доступа», а не «не бот».
    put(p + "/locked/requirements.txt", "aiogram\n")
    agentPlist(home, "b1.plist", label: "com.example.locked-app", work: p + "/locked")
    chmod(p + "/locked", 0)
    // Голый BOT_TOKEN: только «возможно».
    put(p + "/generic/.env", "BOT_TOKEN=PLANTED-GENERIC-VALUE\n")
    agentPlist(home, "b2.plist", label: "com.example.genericenv", work: p + "/generic")
    // Уже описанные в bots.toml: по метке и по папке.
    put(p + "/known1/requirements.txt", "aiogram\n")
    agentPlist(home, "b3.plist", label: "com.example.known", work: p + "/known1")
    put(p + "/known2/requirements.txt", "aiogram\n")
    agentPlist(home, "b4.plist", label: "com.example.known-path", work: p + "/known2")
    // Чужие и наши метки пропускаются.
    put(p + "/apple/requirements.txt", "aiogram\n")
    agentPlist(home, "b5.plist", label: "com.apple.something", work: p + "/apple")
    agentPlist(home, "b6.plist", label: "local.utilitumus.test.x", work: p + "/apple")
    // Для процессов.
    put(p + "/procbot/.env", "TELEGRAM_TOKEN=PLANTED-DOTENV-VALUE\n")
    put(p + "/quiet/requirements.txt", "flask\n")
}

func discoveryProcesses(_ home: String) -> [BotsDiscovery.ProcInfo] {
    let p = home + "/proj"
    return [
        .init(pid: 9001, exe: "/usr/bin/python3", cwd: p + "/procbot"),             // найден по процессу
        .init(pid: 9002, exe: "/opt/node/bin/node", cwd: p + "/quiet"),              // зависимостей Telegram нет
        .init(pid: 9003, exe: "/usr/bin/python3", cwd: "/usr/local/elsewhere"),      // вне дома
        .init(pid: 9004, exe: "/bin/zsh", cwd: p + "/procbot"),                      // оболочка, не среда запуска
        .init(pid: 9005, exe: "/usr/bin/python3", cwd: p + "/news"),                 // проект уже у агента
        .init(pid: 9006, exe: "/usr/bin/python3", cwd: home),                        // сам дом не проект
    ]
}

func discoveryRoots(_ home: String) -> BotsDiscovery.Roots {
    let procs = discoveryProcesses(home)
    return BotsDiscovery.Roots(home: home, launchAgents: home + "/Library/LaunchAgents", uid: getuid(), processes: { procs })
}

func discoveryKnown(_ home: String) -> BotsDiscovery.Known {
    BotsDiscovery.Known(labels: ["com.example.known"], paths: [home + "/proj/known2"])
}

/// Всё, что может уйти наружу из результата: описание и то, что видит центр.
func scanDump(_ result: BotsDiscovery.Result) -> String {
    let found = result.candidates.map { BotFound(id: $0.id, name: $0.name, place: $0.place, why: $0.why, possible: $0.strength == .possible, monitorOnly: $0.label == nil) }
    return String(describing: result) + String(decoding: LinkWire.encoded(BotsDiscoveryState(scanning: false, found: found, skipped: result.skipped)), as: UTF8.self)
}

func discoveryPure() {
    let home = markerDir + "/disc-home"
    try? fm.removeItem(atPath: home)
    try? fm.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    seedDiscovery(home)
    defer { chmod(home + "/proj/locked", 0o700); try? fm.removeItem(atPath: home) }
    let result = BotsDiscovery.scan(discoveryRoots(home), known: discoveryKnown(home))
    let byLabel = Dictionary(result.candidates.compactMap { c in c.label.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
    for (exe, cwd) in [("/opt/homebrew/bin/python3.12", "/p"), ("/usr/bin/node", "/p"), ("/p/app/bot", "/p/app"), ("/bin/zsh", "/p"), ("/usr/bin/python3", "/"), ("/usr/bin/pythonx", "/p")] {
        check(BotsDiscovery.isRuntime(exe: exe, cwd: cwd) == BotRegistry.isRuntime(exe: exe, cwd: cwd), "«Боты» и «Нагрузка» одинаково узнают процесс бота: \(exe)")
    }
    check(!BotsDiscovery.usable("/Volumes/net/bot", home: home) && !BotsDiscovery.usable("/Volumes", home: home), "том в /Volumes поиск не читает: мёртвое подключение его не повесит")
    check(BotsDiscovery.usable("/Volumes/Data/Users/x/bot", home: "/Volumes/Data/Users/x"), "дом на отдельном томе остаётся обычной папкой")
    func c(_ label: String) -> BotsDiscovery.Candidate? { byLabel[label] }

    check(c("com.example.news-digest")?.strength == .confirmed && c("com.example.news-digest")?.why.contains("aiogram в requirements.txt") == true, "по библиотеке: aiogram в requirements.txt — уверенно")
    check(c("com.example.digest-env")?.strength == .confirmed && c("com.example.digest-env")?.why == "ключ TELEGRAM_BOT_TOKEN в .env", "по ключу .env: TELEGRAM_BOT_TOKEN — уверенно: «\(c("com.example.digest-env")?.why ?? "нет")»")
    check(c("com.example.helperbot")?.strength == .possible && c("com.example.helperbot")?.why.contains("по названию") == true, "по названию «bot» — только «возможно»")
    check(c("com.example.backup") == nil, "не бот: зависимости без Telegram, чужой ключ — не предложен")
    check(c("com.example.srcapp")?.strength == .confirmed && c("com.example.srcapp")?.why == "импорт telebot в bot_main.py", "по импорту: проект выведен из пути скрипта: «\(c("com.example.srcapp")?.why ?? "нет")»")
    check(c("com.example.weird-dir")?.strength == .confirmed && c("com.example.weird-dir")?.project?.contains("\"") == true, "папка с кавычкой и переводом строки в имени: предложена")
    check(c("com.example.huge") == nil, "зависимость за пределом размера не видна: чтение ограничено")
    check(c("com.example.nested") == nil, "вложенная папка не обходится")
    check(c("com.example.locked-app")?.noAccess == true && c("com.example.locked-app")?.why.contains("Нет доступа к папке") == true && c("com.example.locked-app")?.why.contains("по названию") == false, "закрытая папка: «нет доступа к папке», а не «не бот»: «\(c("com.example.locked-app")?.why ?? "нет")»")
    check(c("com.example.genericenv")?.strength == .possible, "голый BOT_TOKEN: только «возможно»")
    check(c("com.example.known") == nil && c("com.example.known-path") == nil, "уже описанные (по метке и по папке) не предлагаются")
    check(c("com.apple.something") == nil && c("local.utilitumus.test.x") == nil, "метки Apple и свои пропущены")
    check(!result.candidates.contains { $0.label == craftedLabel || $0.place.contains("[[bot]]") } && result.skipped == 1, "подделанная метка не предложена, посчитана: \(result.skipped)")
    let procs = result.candidates.filter { $0.label == nil }
    check(procs.count == 1 && procs.first?.strength == .confirmed && procs.first?.project == home + "/proj/procbot" && procs.first?.why == "ключ TELEGRAM_TOKEN в .env",
          "процесс: найден по рабочей папке и ключу .env; без признака, вне дома, оболочки, дом и папка агента не предложены")
    let sure = result.candidates.filter { $0.strength == .confirmed }.count
    check(result.candidates.prefix(sure).allSatisfy { $0.strength == .confirmed }, "уверенные идут перед «возможно»")

    // Токены: ни одно значение из .env, плиста, аргументов и исходников не вышло в результат.
    let dump = scanDump(result)
    for value in planted { check(!dump.contains(value), "значение «\(value)» не попало в результат") }
    check(!dump.contains("--token") && !dump.contains("123456:"), "аргументы запуска не попали в результат")
    check(c("com.example.news-digest")?.why.contains("TELEGRAM_BOT_TOKEN в окружении агента") == true, "из окружения агента взято только имя ключа")

    // Поиск только читает: дерево до и после одинаково.
    func tree() -> String {
        ((fm.subpaths(atPath: home) ?? []).sorted().map { p -> String in
            let a = try? fm.attributesOfItem(atPath: home + "/" + p)
            return "\(p)|\((a?[.size] as? Int) ?? 0)|\(((a?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
        }).joined(separator: "\n")
    }
    let before = tree()
    _ = BotsDiscovery.scan(discoveryRoots(home), known: discoveryKnown(home))
    check(before == tree(), "поиск ничего не создал и не изменил в дереве")

    // Живое чтение процессов: рабочая папка своего процесса.
    let cwd = fm.currentDirectoryPath
    let me = BotsDiscovery.processInfo(getpid())
    check(me != nil && (me?.cwd == cwd || me?.cwd == (cwd as NSString).resolvingSymlinksInPath), "libproc: рабочая папка своего процесса читается")
    check(BotsDiscovery.isRuntime(exe: "/opt/homebrew/bin/python3.12", cwd: home + "/p") && BotsDiscovery.isRuntime(exe: home + "/p/mybot", cwd: home + "/p")
          && !BotsDiscovery.isRuntime(exe: "/bin/zsh", cwd: home + "/p") && !BotsDiscovery.isRuntime(exe: "/usr/bin/python3", cwd: "/"), "среда запуска: интерпретатор или программа внутри проекта")

    // Помощники разбора.
    check(BotsDiscovery.mentions("aiogram==3", "aiogram") && BotsDiscovery.mentions("python-telegram-bot[x]", "python-telegram-bot") && !BotsDiscovery.mentions("myaiogramx", "aiogram"), "библиотека — слово целиком")
    check(BotsDiscovery.envKeys(in: Data("A=1\n  export B = 2\n#C=3\nbad key=4\nD".utf8)) == ["A", "B"], "из .env берутся только имена ключей")
    check(!BotsDiscovery.weakName("com.example.robot", []) && BotsDiscovery.weakName("com.example.tgbot", []) && BotsDiscovery.weakName("x", ["proj/telegram-helper"]), "название: robot не бот, tgbot и telegram — да")
}

func writerPure() {
    let dir = markerDir + "/writer"
    try? fm.removeItem(atPath: dir)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(atPath: dir) }
    let url = URL(fileURLWithPath: dir + "/bots.toml")
    func tomlBots() -> [MiniTOML.Table]? { (try? String(contentsOf: url, encoding: .utf8)).flatMap(MiniTOML.init(parsing:))?.arrays["bot"] }
    func mode() -> Int { ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
    func leftovers() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0 != "bots.toml" } }

    // Экранирование: любое значение возвращается из разбора тем же.
    let nasty = ["a\"b", "x\ny", "q\"\n[[bot]]\nid = \"evil", "back\\slash\\", "tab\there\r", "\u{1}\u{7f}ctl", "e\u{301}\"\u{301}", "emoji 🙂 ✓ кириллица", "\"\"\"", "'''", "# не комментарий"]
    for s in nasty {
        let parsed = MiniTOML(parsing: "[[bot]]\nk = \(BotsEntryWriter.quote(s))\n")?.arrays["bot"]?.first?["k"]?.string
        check(parsed == s, "строка TOML возвращается из разбора той же: \(s.debugDescription)")
    }

    // Подделанные метка, папка, имя и заметка: запись одна, поля точные, чужой записи не появилось.
    let label = craftedLabel, project = "/p/" + craftedDir
    let candidate = BotsDiscovery.Candidate(id: "i", name: "a\"b\nc", label: label, plist: "/p/" + craftedDir + ".plist", project: project, strength: .confirmed, why: "", place: "", noAccess: false)
    var entry = BotsEntryWriter.entry(for: candidate, uid: 501, home: "/nohome")
    entry.note = "n\"\n[[bot]]"
    let first = "# мой файл\n[[bot]]\nid = \"old\"\nname = \"Старый\"\nproject = \"p\"\n"
    put(url.path, first)
    var written: BotsEntryWriter.Entry?
    do { written = try BotsEntryWriter.append(entry, to: url) } catch { check(false, "запись подделанных значений: \(error)") }
    let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let bots = tomlBots() ?? []
    check(bots.count == 2 && !bots.contains { $0["id"]?.string == "evil" }, "подделанные значения: ровно две записи, чужой записи нет")
    check(bots.last?["name"]?.string == candidate.name && bots.last?["project"]?.string == project && bots.last?["launchd"]?.strings == [label]
          && bots.last?["note"]?.string == entry.note && bots.last?["id"]?.string == written?.id, "подделанные значения вернулись из разбора буква в букву")
    check(bots.last?["start"]?.strings == ["/bin/launchctl", "bootstrap", "gui/501", candidate.plist!]
          && bots.last?["stop"]?.strings == ["/bin/launchctl", "bootout", "gui/501/" + label]
          && bots.last?["restart"]?.strings == ["/bin/launchctl", "kickstart", "-k", "gui/501/" + label], "команды: /bin/launchctl, gui/<uid>/<метка> и путь плиста, каждое одним аргументом")
    check(after.hasPrefix(first) && mode() == 0o600 && leftovers().isEmpty, "старое содержимое сохранено, права 600, временных файлов нет")
    let reread = BotRegistry.read(url)
    check(reread.problem == nil && reread.bots.count == 2, "BotRegistry читает получившийся файл")

    // Повтор: тот же бот уже есть; тот же id получает суффикс.
    do { _ = try BotsEntryWriter.append(entry, to: url); check(false, "повторная запись принята") }
    catch let e as BackgroundActionError { check(e.message.contains("уже есть") && tomlBots()?.count == 2, "тот же бот второй раз: отказ, файл тот же") } catch {}
    var other = entry
    other.launchd = ["com.example.other"]; other.start = []; other.stop = []; other.restart = []
    if let w = try? BotsEntryWriter.append(other, to: url) { check(w.id == entry.id + "-2" && tomlBots()?.count == 3, "тот же id получил суффикс: \(w.id)") } else { check(false, "вторая запись не прошла") }

    // Небезопасный, битый файл и ссылка: ничего не пишется.
    let snapshot = (try? Data(contentsOf: url)) ?? Data()
    chmod(url.path, 0o666)
    do { _ = try BotsEntryWriter.append(other, to: url); check(false, "запись в небезопасный файл принята") }
    catch let e as BackgroundActionError { check(e.message.contains("Не добавляю") && (try? Data(contentsOf: url)) == snapshot, "файл 0666: отказ, содержимое то же") } catch {}
    chmod(url.path, 0o600)
    put(url.path, "[[bot]\nid = ")
    let broken = (try? Data(contentsOf: url)) ?? Data()
    do { var o2 = other; o2.launchd = ["com.example.o2"]; _ = try BotsEntryWriter.append(o2, to: url); check(false, "запись в битый файл принята") }
    catch let e as BackgroundActionError { check(e.message.contains("не читается") && (try? Data(contentsOf: url)) == broken, "битый файл: отказ, содержимое то же") } catch {}
    try? fm.removeItem(at: url)
    put(dir + "/real.toml", "[[bot]]\nid = \"s\"\nname = \"S\"\nproject = \"p\"\n")
    try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: dir + "/real.toml")
    do { var o3 = other; o3.launchd = ["com.example.o3"]; _ = try BotsEntryWriter.append(o3, to: url); check(false, "запись через ссылку принята") }
    catch let e as BackgroundActionError { check(e.message.contains("не обычный файл"), "bots.toml-ссылка: отказ") } catch {}
    try? fm.removeItem(at: url)
    try? fm.removeItem(atPath: dir + "/real.toml")

    // Нет файла: создаётся с правами 600; небезопасная папка не пускает.
    if (try? BotsEntryWriter.append(other, to: url)) != nil { check(mode() == 0o600 && tomlBots()?.count == 1 && leftovers().isEmpty, "нет файла: создан с правами 600") } else { check(false, "создание файла не удалось") }
    try? fm.removeItem(at: url)
    chmod(dir, 0o777)
    do { _ = try BotsEntryWriter.append(other, to: url); check(false, "запись в доступную всем папку принята") }
    catch let e as BackgroundActionError { check(e.message.contains("Не добавляю") && !fm.fileExists(atPath: url.path) && leftovers().isEmpty, "папка 0777: новый файл не создан, временного нет") } catch {}
    chmod(dir, 0o700)

    // Процесс без launchd: только наблюдение, кнопок нет.
    let proc = BotsDiscovery.Candidate(id: "p", name: "procbot", label: nil, plist: nil, project: "/p/procbot", strength: .confirmed, why: "", place: "", noAccess: false)
    let monitor = BotsEntryWriter.entry(for: proc, uid: 501, home: "/nohome")
    check(monitor.start.isEmpty && monitor.stop.isEmpty && monitor.restart.isEmpty && monitor.launchd.isEmpty && monitor.watchDir == "/p/procbot" && monitor.note.contains("только наблюдается"), "процесс без launchd: ни одной команды, watch_dir и пояснение в заметке")
    if (try? BotsEntryWriter.append(monitor, to: url)) != nil, let spec = BotRegistry.read(url).bots.first {
        check(spec.commands.isEmpty && spec.watchDir == "/p/procbot", "BotRegistry: у наблюдаемого бота нет команд")
        for state in [BotState.running, .stopped, .partial] { check(BotRegistry.offered(spec, state).isEmpty, "наблюдаемый бот, \(state.rawValue): кнопок нет") }
        let procs: [Int32: BotProc] = [77: BotProc(memMB: 20, start: 1_000_000, children: [])]
        let up = BotsMonitor.cards([spec], launchd: [:], dirPIDs: ["/p/procbot": [77]], now: Date(timeIntervalSince1970: 1_000_000 + 600), probe: { procs[$0] }, ports: { _ in [] })
        let down = BotsMonitor.cards([spec], launchd: [:], dirPIDs: [:], probe: { procs[$0] }, ports: { _ in [] })
        check(up.first?.state == .running && up.first?.verbs.isEmpty == true && up.first?.memMB == 20 && up.first?.uptime == 600, "наблюдаемый бот: работает по процессу в рабочей папке, кнопок нет")
        check(down.first?.state == .stopped && down.first?.verbs.isEmpty == true, "наблюдаемый бот без процесса: остановлен, кнопок нет")
    } else { check(false, "запись наблюдаемого бота не удалась") }
    try? fm.removeItem(at: url)

    // Уже описанное в файле распознаётся по метке и папке (с ~).
    let spec = BotSpec(id: "a", name: "A", project: "~/x/y", url: nil, launchd: ["l.a"], bundleIDs: [], commands: [:], requiresEnv: [], envFile: "/h/e/.env", note: "")
    let known = BotsEntryWriter.known([spec], home: "/h")
    check(known.labels == ["l.a"] && known.paths == ["/h/x/y", "/h/e"], "известные: метка, папка проекта и папка .env: \(known.paths.sorted())")
    check(BotsEntryWriter.slug("Новости 24 / bot!") == "24-bot" && BotsEntryWriter.slug("!!!") == "bot", "id из имени: латиница и цифры, иначе «bot»")
}

func discoveryWirePure() {
    let found = BotFound(id: "abc", name: "n", place: "p", why: "w", possible: true, monitorOnly: false)
    let state = BotsState(file: .ok, bots: [], prompt: nil, running: false, notice: nil, discovery: BotsDiscoveryState(scanning: false, found: [found], skipped: 2))
    check((try? JSONDecoder().decode(BotsState.self, from: JSONEncoder().encode(state))) == state, "BotsState с результатами поиска переживает кодирование")
    check((try? JSONDecoder().decode(BotsState.self, from: Data(#"{"file":{"kind":"ok","detail":""},"bots":[],"running":false}"#.utf8)))?.discovery == nil, "состояние без поиска (старая утилита) разбирается")
    for action in [BotsAction.find, .add(id: "abc"), .dismissFound] {
        check(LinkWire.decodeAction(BotsAction.self, from: LinkWire.encoded(action), limit: BotsStore.maxActionBytes) == action, "BotsAction \(action): проходит канонический разбор")
    }
    let json = String(decoding: LinkWire.encoded(state), as: UTF8.self)
    check(!json.contains("launchctl") && !json.contains("bootstrap") && !json.contains("plist"), "в состоянии с поиском нет команд и путей плиста")
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
    let betaSum = BotRunner.fingerprint(["/usr/bin/touch", marker])
    await model.perform(.quick(id: "beta", verb: .start, sum: betaSum))
    check(await until(5) { model.state.notice?.isError == true && !model.state.running && model.state.notice?.text.contains("Стенд не запускает") == true }, "быстрое действие: тот же отказ стенда")
    check(!fm.fileExists(atPath: marker), "быстрое действие: маркера нет")
    await model.perform(.quick(id: "alpha", verb: .start, sum: betaSum))
    check(model.actionError != nil, "быстрое действие, которого у бота нет: отказ")
    await model.perform(.quick(id: "beta", verb: .start, sum: BotRunner.fingerprint(["/bin/другая"])))
    check(model.actionError == BotRunner.changedMessage && !model.state.running, "быстрое действие с другой командой: отказ, ничего не запущено")
    await model.perform(.dismissNotice)
    check(await until(2) { model.state.notice == nil }, "баннер закрывается")

    // Статус для дашборда и меню: счёт без имён, быстрые действия с подтверждением.
    let status = try? await LinkClient(id: moduleID).status()
    check(status?.line == "1 из 3 работает" || status?.line.hasSuffix("работает") == true, "строка статуса — счёт: «\(status?.line ?? "нет")»")
    check(status?.line.contains("Альфа") == false && status?.attention == false, "в строке нет имён, внимания нет")
    let quick = status?.quickActions ?? []
    check(quick.count == 2 && quick.allSatisfy { $0.confirm != nil }, "быстрых действий два (альфа выключить, бета включить), у каждого подтверждение: \(quick.map(\.title))")
    check(quick.first.map { LinkWire.decodeAction(BotsAction.self, from: $0.action, limit: 4096) } != nil, "быстрое действие — обычное действие утилиты, id и кнопка")
    check(quick.allSatisfy { $0.confirm?.message.contains("Выполнит /") == true }, "вопрос быстрого действия показывает команду: \(quick.map { $0.confirm?.message ?? "" })")

    // Файл поменяли, пока вопрос открыт: подтверждали другое, запускать нельзя.
    await model.perform(.dismissNotice)
    await model.perform(.request(id: "beta", verb: .start))
    guard let open = model.state.prompt else { return check(false, "подтверждения для смены файла нет") }
    let text = fixtureTOML()
    writeBots(text.replacingOccurrences(of: "\"\(marker)\"", with: "\"\(marker)-другой\""))
    await model.perform(.confirm(planID: open.id))
    check(await until(5) { model.state.notice != nil }, "подтверждение после смены файла: пришёл результат")
    check(model.state.notice?.text == BotRunner.changedMessage && model.state.notice?.isError == true, "команда сменилась: отказ, а не запуск: «\(model.state.notice?.text ?? "нет")»")
    writeBots(text)
    await model.perform(.dismissNotice)
}

@MainActor func fileProblems() async {
    let model = RemoteBotsModel.shared
    let link = LinkClient(id: moduleID)
    writeBots(fixtureTOML(), mode: 0o666)
    await model.perform(.refresh)
    check(await until(5) { model.state.file.kind == .unsafe && model.state.bots.isEmpty }, "bots.toml 0666: утилита его отвергла, ботов нет, на экране причина «\(model.state.file.detail)»")
    let status = try? await link.status()
    check(status?.attention == true && status?.line == "bots.toml небезопасен" && status?.quickActions.isEmpty == true, "статус: внимание, быстрых действий нет")
    await model.perform(.quick(id: "beta", verb: .start, sum: BotRunner.fingerprint(["/usr/bin/touch", marker])))
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


// MARK: - Поиск ботов в утилите

/// Домашняя папка стенда: под launchd утилита видит её как свой дом, настоящего дома у неё нет.
@MainActor func standHome() -> String { Stand.out + "/home" }

func knownTOML(_ home: String) -> String {
    fixtureTOML() + """


    [[bot]]
    id = "k1"
    name = "K1"
    project = "demo"
    launchd = ["com.example.known"]

    [[bot]]
    id = "k2"
    name = "K2"
    project = "\(home)/proj/known2"
    launchd = ["com.example.k2"]
    """
}

@MainActor func foundNames(_ model: RemoteBotsModel) -> Set<String> { Set(model.state.discovery?.found.map(\.name) ?? []) }

@MainActor func discoveryRemote() async {
    let model = RemoteBotsModel.shared
    let home = standHome()
    try? fm.removeItem(atPath: home + "/proj")
    try? fm.removeItem(atPath: home + "/Library/LaunchAgents")
    seedDiscovery(home)
    writeBots(knownTOML(home))
    await model.perform(.refresh)
    check(await until(5) { model.state.bots.count == 5 }, "поиск: в файле пять ботов, \(ids(model))")
    await pause(1)
    check(model.state.discovery == nil, "до нажатия никакого поиска нет")
    let fileBefore = (try? Data(contentsOf: BotRegistry.url)) ?? Data()

    await model.perform(.find)
    check(await until(15) { model.state.discovery?.scanning == false && model.state.discovery?.found.isEmpty == false }, "«Найти ботов»: утилита вернула результат")
    let names = foundNames(model)
    check(["news-digest", "digest-env", "helperbot", "weird-dir", "srcapp", "locked-app", "genericenv"].allSatisfy(names.contains), "найдены агенты с признаками: \(names.sorted())")
    check(["backup", "known", "known-path", "huge", "nested", "something"].allSatisfy { !names.contains($0) }, "не бот, уже описанные, за пределами чтения и чужие не предложены")
    check(!names.contains("procbot") && model.state.discovery?.found.allSatisfy { $0.place.hasPrefix("LaunchAgent ") } == true, "стенд не смотрит настоящие процессы: только поддельные агенты")
    check(model.state.discovery?.skipped == 1, "подделанная метка посчитана и не предложена")
    let byName = Dictionary(uniqueKeysWithValues: (model.state.discovery?.found ?? []).map { ($0.name, $0) })
    check(byName["news-digest"]?.possible == false && byName["digest-env"]?.possible == false && byName["helperbot"]?.possible == true
          && byName["genericenv"]?.possible == true && byName["locked-app"]?.possible == true && byName["locked-app"]?.why.contains("Нет доступа к папке") == true,
          "уверенные и «возможно» разделены; закрытая папка названа «нет доступа»")
    let json = String(decoding: LinkWire.encoded(model.state), as: UTF8.self)
    for value in planted { check(!json.contains(value), "значение «\(value)» не дошло до центра") }
    check(!json.contains(home) && !json.contains(Kit.realHome) && !json.contains("launchctl") && !json.contains("bootstrap") && !json.contains(".plist"), "в состоянии для центра нет путей дома, плистов и команд")
    let log = (try? String(contentsOfFile: Stand.out + "/agent.log", encoding: .utf8)) ?? ""
    for value in planted { check(!log.contains(value), "значение «\(value)» не попало в журнал утилиты") }
    check((try? Data(contentsOf: BotRegistry.url)) == fileBefore, "поиск bots.toml не менял")

    // Добавление: центр называет только id.
    await model.perform(.add(id: "nobody"))
    check(model.actionError != nil, "add с неизвестным id: отказ")
    await model.perform(.add(id: String(repeating: "a", count: 400)))
    check(model.actionError != nil, "add со слишком длинным id: отказ")
    guard let news = byName["news-digest"], let weird = byName["weird-dir"] else { return check(false, "нет кандидатов для добавления") }
    await model.perform(.add(id: news.id))
    check(await until(5) { model.state.notice?.isError == false && model.state.notice?.text.contains("Добавлен") == true }, "add: утилита добавила и сказала об этом")
    check(await until(5) { model.state.bots.count == 6 && !foundNames(model).contains("news-digest") }, "бот появился на экране и исчез из найденных")
    let added = BotRegistry.load(BotRegistry.url).first { $0.launchd == ["com.example.news-digest"] }
    let plist = home + "/Library/LaunchAgents/a1.plist"
    // /tmp и /private/tmp — одно место: путь плиста сравниваем после раскрытия ссылок.
    var startArgs: [String] = []
    if case .argv(let a)? = added?.commands[.start] { startArgs = a }
    func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
    check(Array(startArgs.prefix(3)) == ["/bin/launchctl", "bootstrap", "gui/\(getuid())"] && startArgs.count == 4 && resolved(startArgs[3]) == resolved(plist)
          && added?.commands[.stop] == .argv(["/bin/launchctl", "bootout", "gui/\(getuid())/com.example.news-digest"])
          && added?.commands[.restart] == .argv(["/bin/launchctl", "kickstart", "-k", "gui/\(getuid())/com.example.news-digest"]), "команды записи — /bin/launchctl против gui/<uid>/<метка> и плиста: \(startArgs)")
    let mode = ((try? fm.attributesOfItem(atPath: BotRegistry.url.path))?[.posixPermissions] as? Int) ?? 0
    let text = (try? String(contentsOf: BotRegistry.url, encoding: .utf8)) ?? ""
    check(mode == 0o600 && String(decoding: fileBefore, as: UTF8.self).isEmpty == false && text.hasPrefix(String(decoding: fileBefore, as: UTF8.self)), "файл 0600, прежнее содержимое на месте")
    for value in planted { check(!text.contains(value), "значение «\(value)» не попало в bots.toml") }
    await model.perform(.add(id: news.id))
    check(model.actionError != nil, "тот же id второй раз: отказ")

    await model.perform(.add(id: weird.id))
    check(await until(5) { model.state.bots.count == 7 }, "папка с кавычкой и переводом строки: добавлена")
    let all = BotRegistry.read(BotRegistry.url)
    check(all.problem == nil && all.bots.count == 7 && !all.bots.contains { $0.id == "evil" }
          && all.bots.contains { $0.launchd == ["com.example.weird-dir"] && $0.project == "~/proj/" + craftedDir }, "файл после подделанной папки разбирается, чужой записи нет")

    // Недавно добавленные больше не предлагаются.
    await model.perform(.find)
    check(await until(15) { model.state.discovery?.scanning == false && model.state.discovery?.found.isEmpty == false }, "повторный поиск вернул результат")
    check(!foundNames(model).contains("news-digest") && !foundNames(model).contains("weird-dir") && foundNames(model).contains("helperbot"), "добавленные не предлагаются повторно")

    // Небезопасный файл: добавление отказывает, файл не меняется.
    let snapshot = (try? Data(contentsOf: BotRegistry.url)) ?? Data()
    chmod(BotRegistry.url.path, 0o666)
    if let helper = (model.state.discovery?.found ?? []).first(where: { $0.name == "helperbot" }) {
        await model.perform(.add(id: helper.id))
        check(await until(5) { model.state.notice?.isError == true && model.state.notice?.text.contains("Не добавляю") == true }, "bots.toml 0666: добавление отказало «\(model.state.notice?.text ?? "нет")»")
    } else { check(false, "helperbot не найден") }
    check((try? Data(contentsOf: BotRegistry.url)) == snapshot, "небезопасный файл не изменён")
    chmod(BotRegistry.url.path, 0o600)
    await model.perform(.dismissNotice)
    await model.perform(.dismissFound)
    check(await until(3) { model.state.discovery == nil }, "«Закрыть» убирает результаты")
}

// MARK: - Пиксели

@MainActor func pinLocal(_ state: BotsState) { BotsStore.shared.testPin(state) }

/// Экран утилиты на её хранилище в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.bots), animated: false) { _, active in
        AnyView(ModuleScreen(module: .bots) { BotsView(model: BotsStore.shared) }
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.bots))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .bots, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

/// Вкладка и хранилище утилиты, закреплённое на том, что вкладка показала в момент снимка. Вкладка ведёт аренду, и утилита
/// могла перемерить память между снимками, поэтому до трёх попыток; подделка красна в каждой.
@MainActor func compareTab(_ theme: DSTheme, _ name: String) async -> NSBitmapImageRep {
    let model = RemoteBotsModel.shared
    await SatelliteRegistry.shared.update()
    var remote: NSBitmapImageRep!, local: NSBitmapImageRep!, diff = 0
    for _ in 0..<3 {
        remote = await Stand.open(theme)
        pinLocal(model.state)
        local = await openLocal(theme)
        diff = differingPixels(local, remote)
        if diff == 0 { break }
    }
    Stand.save(local, "\(name)-local")
    Stand.save(remote, "\(name)-remote")
    check(diff == 0, "\(name): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
    return remote
}

@MainActor func pixels() async {
    let model = RemoteBotsModel.shared
    let registry = SatelliteRegistry.shared
    var seen: [NSBitmapImageRep] = []
    var plainBots: [String: NSBitmapImageRep] = [:]
    let scenarios: [(String, String?, mode_t)] = [("bots", fixtureTOML(), 0o600), ("empty", nil, 0o600), ("unsafe", fixtureTOML(), 0o666)]
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        for (name, text, mode) in scenarios {
            writeBots(text, mode: mode)
            await model.perform(.refresh)
            check(await until(5) { model.state.file.kind == (text == nil ? .missing : mode == 0o666 ? .unsafe : .ok) && (text == nil || mode == 0o666 || model.state.bots.count == 3) }, "\(themeName) \(name): утилита в нужном состоянии")
            await model.read()
            let remote = await compareTab(theme, "\(themeName)-\(name)")
            check(registry.isEnabled(.bots), "\(themeName) \(name): реестр видит утилиту включённой")
            seen.append(remote)
            if name == "bots" {
                plainBots[themeName] = remote
                // Сверка видит значения: другое имя бота на экране утилиты на снимок вкладки не похоже.
                var other = model.state
                other.bots = other.bots.map { card in
                    BotCard(id: card.id, name: card.name + "-подделка", project: card.project, state: card.state, memMB: card.memMB,
                            uptime: card.uptime, ports: card.ports, url: card.url, note: card.note, verbs: card.verbs)
                }
                pinLocal(other)
                let changed = await openLocal(theme)
                check(differingPixels(changed, remote) > 0, "\(themeName): другое имя бота сверка замечает, разных пикселей \(differingPixels(changed, remote))")
            }
        }
        check(differingPixels(seen[seen.count - 3], seen[seen.count - 2]) > 0 && differingPixels(seen[seen.count - 2], seen[seen.count - 1]) > 0, "\(themeName): три состояния выглядят по-разному, снимки не пустые")
    }
    // Результаты поиска: утилита нашла ботов в поддельном доме, вкладка и экран утилиты рисуют одно и то же.
    // Для снимка оставляем трёх: уверенный и двое «возможно», иначе список не влезает на экран.
    for file in ["a1", "a5", "a6", "a7", "a8", "a9", "b2", "b3", "b4", "b5", "b6"] { try? fm.removeItem(atPath: standHome() + "/Library/LaunchAgents/\(file).plist") }
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        // Работающего бота в файле нет: его память меняется от замера к замеру и портила бы сравнение пикселей.
        let still = fixtureTOML().replacingOccurrences(of: utilityLabel, with: "com.example.absent-alpha")
        for (name, text) in [("found", still), ("found-empty", nil)] as [(String, String?)] {
            writeBots(text)
            await model.perform(.refresh)
            await model.perform(.find)
            check(await until(15) { model.state.discovery?.scanning == false && model.state.discovery?.found.isEmpty == false && (text == nil ? model.state.file.kind == .missing : model.state.bots.count == 3) }, "\(themeName) \(name): утилита нашла ботов в поддельном доме")
            await model.read()
            let remote = await compareTab(theme, "\(themeName)-\(name)")
            if name == "found", let base = plainBots[themeName] { check(differingPixels(base, remote) > 0, "\(themeName): экран с найденными отличается от экрана без них") }
            await model.perform(.dismissFound)
        }
        // Все виды карточек разом и поиск в ходу: только снимки на хранилище утилиты, чтобы увидеть экран.
        var all = BotsState.empty
        all.file = .ok
        all.discovery = BotsDiscoveryState(scanning: false, found: [
            BotFound(id: "1", name: "news-digest", place: "LaunchAgent com.example.news-digest · ~/proj/news", why: "aiogram в requirements.txt", possible: false, monitorOnly: false),
            BotFound(id: "2", name: "procbot", place: "Процесс · ~/proj/procbot", why: "ключ TELEGRAM_TOKEN в .env", possible: false, monitorOnly: true),
            BotFound(id: "3", name: "helperbot", place: "LaunchAgent com.example.helperbot · ~/proj/plain", why: "по названию (bot, tg, telegram); зависимостей Telegram в папке не нашлось", possible: true, monitorOnly: false),
            BotFound(id: "4", name: "locked", place: "LaunchAgent com.example.locked · ~/Documents/locked", why: "папку проекта проверить не удалось. Нет доступа к папке: разрешите в «Конфиденциальность и безопасность»", possible: true, monitorOnly: false),
        ], skipped: 1)
        pinLocal(all)
        Stand.save(await openLocal(theme), "\(themeName)-found-all-local")
        var scanning = BotsState.empty
        scanning.file = .ok
        scanning.discovery = .scanning
        pinLocal(scanning)
        Stand.save(await openLocal(theme), "\(themeName)-scanning-local")
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
                discoveryPure()
                writerPure()
                discoveryWirePure()
                try? fm.removeItem(atPath: markerDir)
                finish()
            }
        }
        MainActor.assumeIsolated {
            ModuleCheck.main(.bots, foreignAction: LinkWire.encoded(BotsAction.quick(id: "beta", verb: .start, sum: BotRunner.fingerprint(["/usr/bin/touch", marker])))) { utility in
                let realFile = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Utilitumus/bots.toml").path
                let realBefore = (try? fm.attributesOfItem(atPath: realFile))?[.modificationDate] as? Date
                try? fm.createDirectory(atPath: markerDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                logicPure()
                envAndFile()
                isolationPure()
                wirePure()
                discoveryPure()
                writerPure()
                discoveryWirePure()
                await garbage()
                await lease()
                await states()
                await actions()
                await fileProblems()
                await discoveryRemote()
                await pixels()
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standHome() + "/proj/locked")
                try? fm.removeItem(atPath: standHome() + "/proj")
                try? fm.removeItem(atPath: standHome() + "/Library/LaunchAgents")
                writeBots(nil)
                let realAfter = (try? fm.attributesOfItem(atPath: realFile))?[.modificationDate] as? Date
                check(realBefore == realAfter, "настоящий bots.toml не менялся (только дата правки, содержимое не читалось)")
                check(!fm.fileExists(atPath: marker), "за весь прогон ни одна команда бота не выполнена")
                try? fm.removeItem(atPath: markerDir)
            }
        }
    }
}
