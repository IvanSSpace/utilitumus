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

let state = StudioState(folder: "/tmp/x", phase: .running, message: nil, ownsServer: true,
                        page: "http://127.0.0.1:50000/#b=abcdefghijklmnop", login: 3)
check(roundTrips(state), "состояние: туда и обратно")
check(String(decoding: wire(state), as: UTF8.self)
      == #"{"folder":"\/tmp\/x","login":3,"ownsServer":true,"page":"http:\/\/127.0.0.1:50000\/#b=abcdefghijklmnop","phase":"running"}"#,
      "состояние: ключи отсортированы, форма закреплена")
let keys = Set(((try? JSONSerialization.jsonObject(with: wire(state))) as? [String: Any] ?? [:]).keys)
check(keys.isSubset(of: ["folder", "login", "message", "ownsServer", "page", "phase"]) && !keys.contains(where: { $0.lowercased().contains("token") }),
      "в состоянии нет поля токена")

let actions: [StudioAction] = [.setFolder("/tmp/a"), .setFolder(""), .newLogin]
check(actions.allSatisfy(roundTrips), "\(actions.count) действия: туда и обратно, те же байты")
check(String(decoding: wire(StudioAction.newLogin), as: UTF8.self) == #"{"newLogin":{}}"#, "newLogin: форма закреплена")
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
] {
    check(refused(json), "отказ: \(name)")
}

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
