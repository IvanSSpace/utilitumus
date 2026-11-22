import Foundation

// Провод модуля «Студия»: состояние, действия, путь. Запуск: Tests/run-studio-wire-check.sh

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func wire(_ value: some Encodable) -> Data { LinkWire.encoded(value) }

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    let data = wire(value)
    guard let back = try? JSONDecoder().decode(T.self, from: data) else { return false }
    return back == value && wire(back) == data
}

/// Не пройдёт связь: не разбирается или кодируется обратно не теми же байтами.
func refused(_ json: String) -> Bool {
    let data = Data(json.utf8)
    guard let action = try? JSONDecoder().decode(StudioAction.self, from: data) else { return true }
    return wire(action) != data
}

let state = StudioState(folder: "/tmp/x", phase: .running, message: nil, ownsServer: true, login: 3)
check(roundTrips(state), "состояние: туда и обратно")
check(String(decoding: wire(state), as: UTF8.self)
      == #"{"folder":"\/tmp\/x","login":3,"ownsServer":true,"phase":"running"}"#,
      "состояние: ключи отсортированы, форма закреплена")
let keys = Set(((try? JSONSerialization.jsonObject(with: wire(state))) as? [String: Any] ?? [:]).keys)
check(keys.isSubset(of: ["folder", "login", "message", "ownsServer", "phase"]) && !keys.contains(where: { $0.lowercased().contains("token") }),
      "в состоянии нет ни токена, ни адреса с кодом входа")
// Утилита 0.9.4 ещё присылала адрес с кодом: новый лаунчер читает такое состояние и код отбрасывает.
let withPage = #"{"folder":"\/tmp\/x","login":3,"ownsServer":true,"page":"http:\/\/127.0.0.1:50000\/#b=abcdefghijklmnop","phase":"running"}"#
let decodedOld = try? JSONDecoder().decode(StudioState.self, from: Data(withPage.utf8))
check(decodedOld?.login == 3 && !String(decoding: wire(decodedOld ?? state), as: UTF8.self).contains("#b="), "прежнее состояние с page читается, код не хранится")

let actions: [StudioAction] = [.setFolder("/tmp/a"), .setFolder(""), .newLogin, .openInBrowser, .reconnect, .select("mixer"), .deselect,
                               .openSession("mixer"), .stand("fans"), .release("fans"), .rotate("keyboard"),
                               .task(unit: "mixer", text: "строка\nвторая «кавычки» \"x\""), .handToHub(unit: "mixer", text: "общее"), .commitCases]
check(actions.allSatisfy(roundTrips), "\(actions.count) действий: туда и обратно, те же байты")
check(String(decoding: wire(StudioAction.task(unit: "mixer", text: "a")), as: UTF8.self) == #"{"task":{"text":"a","unit":"mixer"}}"#,
      "task: форма закреплена")
check(String(decoding: wire(StudioAction.commitCases), as: UTF8.self) == #"{"commitCases":{}}"#, "commitCases: форма закреплена")
check(String(decoding: wire(StudioAction.select("fans")), as: UTF8.self) == #"{"select":{"_0":"fans"}}"#, "select: форма закреплена")
let longest = StudioAction.task(unit: String(repeating: "a", count: 32), text: String(repeating: "\u{1}", count: StudioText.maxLength))
check(wire(longest).count <= StudioAction.wireLimit, "самое длинное действие влезает в предел провода (\(wire(longest).count) байт)")
check(String(decoding: wire(StudioAction.newLogin), as: UTF8.self) == #"{"newLogin":{}}"#, "newLogin (лаунчер 0.9.4): форма закреплена")
check(String(decoding: wire(StudioAction.openInBrowser), as: UTF8.self) == #"{"openInBrowser":{}}"#, "openInBrowser: форма закреплена")
check(String(decoding: wire(StudioAction.setFolder("/a")), as: UTF8.self) == #"{"setFolder":{"_0":"\/a"}}"#, "setFolder: форма закреплена")

for (name, json) in [
    ("неизвестное", #"{"run":{}}"#),
    ("два действия", #"{"newLogin":{},"setFolder":{"_0":"/a"}}"#),
    ("чужое поле у newLogin", #"{"newLogin":{"x":1}}"#),
    ("чужое поле у setFolder", #"{"setFolder":{"_0":"/a","x":1}}"#),
    ("число вместо строки", #"{"setFolder":{"_0":5}}"#),
    ("без значения", #"{"setFolder":{}}"#),
    ("пусто", "{}"),
    ("мусор", "не json"),
    ("task без текста", #"{"task":{"unit":"mixer"}}"#),
    ("task с лишним полем", #"{"task":{"text":"a","unit":"mixer","x":1}}"#),
    ("task без меток", #"{"task":{"_0":"mixer","_1":"a"}}"#),
    ("handToHub текст числом", #"{"handToHub":{"text":1,"unit":"mixer"}}"#),
    ("commitCases с полем", #"{"commitCases":{"x":1}}"#),
    ("reconnect с полем", #"{"reconnect":{"_0":"x"}}"#),
    ("select без id", #"{"select":{}}"#),
    ("deselect с id", #"{"deselect":{"_0":"mixer"}}"#),
    ("rotate массивом", #"{"rotate":{"_0":["mixer"]}}"#),
    ("неканонический порядок ключей", #"{"task":{"unit":"mixer","text":"a"}}"#),
] {
    check(refused(json), "отказ: \(name)")
}

// Текст задачи: чистится до сервера.
check(StudioText.task("  сделай\u{1B}[2J это \n") == "сделай[2J это", "задача: ESC и края убраны")
check(StudioText.task("a\u{7F}b\tc\nd") == "ab\tc\nd", "задача: DEL убран, табуляция и перевод строки остались")
check(StudioText.task("   \n ") == nil, "задача: пустая — отказ")
check(StudioText.task(String(repeating: "я", count: StudioText.maxLength)) != nil, "задача: ровно предел проходит")
check(StudioText.task(String(repeating: "я", count: StudioText.maxLength + 1)) == nil, "задача: длиннее предела — отказ")

// id утилиты.
check(["mixer", "a", String(repeating: "z", count: 32)].allSatisfy(StudioUnitID.isValid), "id: строчная латиница")
check(!["", "Mixer", "mix-er", "mix er", "../x", "mixer1", "миксер", String(repeating: "z", count: 33)].contains(where: StudioUnitID.isValid),
      "id: остальное — отказ")

// Снимок на проводе.
func unit(_ id: String, kind: StudioUnitKind = .utility, version: String? = "1.0", status: String? = "stable", bugs: Int = 0,
          title: String? = nil) -> StudioUnit {
    StudioUnit(id: id, kind: kind, title: title ?? id.capitalized, summary: "", tint: "#0a84ff", version: version, status: status,
               openTasks: 1, bugs: bugs, hasIcon: false, branch: "mod/\(id)", ahead: 2, master: .working, contextPct: 61,
               lastActive: 1_700_000_000_000, rotation: StudioRotation(stage: "handover", message: "пишет дело"))
}
var full = state
full.board = StudioBoard(units: [unit("mixer"), unit("orchestrator", kind: .orchestrator)],
                         hubTasks: [StudioHubTask(name: "Выпуск", status: "todo", comment: "")], orcaError: "Orca: нет",
                         icons: ["mixer": Data([0x89, 0x50, 0x4E, 0x47])], selected: "mixer",
                         detail: StudioDetail(id: "mixer", caseText: "## Дело\n- пункт", casePath: "/x/case.md", queue: [StudioQueueItem(done: false, text: "t")]),
                         notice: StudioNotice(id: 3, text: "Готово", isError: false), problem: nil, working: ["mixer"])
check(roundTrips(full), "состояние со снимком: туда и обратно, те же байты")
let fullText = String(decoding: wire(full), as: UTF8.self).lowercased()
check(!fullText.contains("token") && !fullText.contains("x-studio"), "в снимке нет токена и его заголовка")
check(String(decoding: wire(state), as: UTF8.self).contains("board") == false, "без снимка ключа board на проводе нет")
let old = #"{"folder":"\/tmp\/x","login":3,"ownsServer":true,"phase":"running"}"#
check((try? JSONDecoder().decode(StudioState.self, from: Data(old.utf8)))?.board == nil, "состояние прежней утилиты (без board) читается")

// Статус и фильтры — как у страницы (app.js: statusKey, match).
check(unit("a", version: nil, status: "stable").statusKey == .dev, "не выпущена — в разработке")
check(unit("a", status: "wip").statusKey == .work && unit("a", status: "ready").statusKey == .ready, "wip — в работе, ready — готова")
check(unit("a", status: "stable", bugs: 2).statusKey == .bug && unit("a", status: nil).statusKey == .stable, "стабильная с багами — баг; без дела — стабильна")
check(unit("a", status: "ready", bugs: 2).statusKey == .ready, "готова с багами остаётся готовой (фильтр «С багами» её всё равно видит)")
check(StudioFilter.bug.matches(unit("a", status: "ready", bugs: 2), query: ""), "фильтр «С багами»: и по счётчику")
check(!StudioFilter.all.matches(unit("launcher", kind: .launcher), query: ""), "лаунчер и хаб не в сетке")
check(StudioFilter.all.matches(unit("mixer", title: "Микшер"), query: "микш") && StudioFilter.all.matches(unit("mixer", title: "Микшер"), query: "MIX"),
      "поиск: по названию без регистра и по id")
check(!StudioFilter.all.matches(unit("mixer", title: "Микшер"), query: "вент"), "поиск: мимо — не видно")
check(StudioAgo.text(nil) == "ещё не работал", "время: мастер не работал")
let now = Date(timeIntervalSince1970: 1_700_000_000)
check(StudioAgo.text(1_700_000_000_000 - 30_000, now: now) == "сейчас" && StudioAgo.text(1_700_000_000_000 - 5 * 60_000, now: now) == "5 мин назад"
      && StudioAgo.text(1_700_000_000_000 - 3 * 3_600_000, now: now) == "3 ч назад" && StudioAgo.text(1_700_000_000_000 - 24 * 3_600_000, now: now) == "вчера",
      "время: сейчас, минуты, часы, вчера")

// Markdown дела: без ссылок, заголовок дела пропущен.
let blocks = StudioMarkdown.blocks("# Дело\n\n## Состояние\n- [x] сделано\n- [ ] нет\n* просто\nабзац `код` **жирно**")
check(blocks == [.heading("Состояние"), .bullet("сделано", done: true), .bullet("нет", done: false), .bullet("просто", done: nil),
                 .paragraph("абзац `код` **жирно**")], "markdown: блоки как у страницы")
check(StudioMarkdown.spans("a `b` **c** d") == [.plain("a "), .code("b"), .plain(" "), .bold("c"), .plain(" d")], "markdown: код и жирный")
check(StudioMarkdown.spans("``  ** **") == [.plain("``  "), .bold(" ")] || StudioMarkdown.spans("``").allSatisfy { if case .plain = $0 { return true } else { return false } },
      "markdown: пустой код не ломает разбор")
let link = StudioMarkdown.attributed("[жми](file:///etc/passwd) <https://evil.example> **ж**")
check(link.runs.allSatisfy { $0.link == nil }, "markdown: ссылки не оживают")
check(String(link.characters).contains("[жми](file:///etc/passwd)"), "markdown: текст ссылки показан как есть")

// Путь к папке.
check(StudioPath.validated("") == "", "путь: пусто — «не задана»")
check(StudioPath.validated("/a/b") == "/a/b", "путь: обычный")
check(StudioPath.validated("/a//b/") == "/a/b", "путь: лишние слэши убраны")
for bad in ["a/b", "~/x", "/a/../b", "/a/./b", "/..", "/", "//", "/a\nb", "/a\u{0}b", "/a\u{7F}b", String(repeating: "/a", count: 600)] {
    check(StudioPath.validated(bad) == nil, "путь: отказ «\(bad.prefix(14).debugDescription)»")
}

// Настройки: по умолчанию пусто, остальное из своего suite.
Kit.defaults.removeObject(forKey: StudioKeys.folder)
check(StudioState.stored().folder == "" && StudioState.stored().phase == .stopped, "по умолчанию папка пуста, остановлена")
Kit.defaults.set("/tmp/studio-wire-check", forKey: StudioKeys.folder)
check(StudioState.stored().folder == "/tmp/studio-wire-check", "папка из настроек")
Kit.defaults.set("../evil", forKey: StudioKeys.folder)
check(StudioState.stored().folder == "", "кривая папка в настройках не читается")
Kit.defaults.removeObject(forKey: StudioKeys.folder)

print(failures == 0 ? "ВСЁ ЗЕЛЁНОЕ" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
