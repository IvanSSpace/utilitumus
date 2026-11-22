import Combine
import CoreGraphics
import Foundation
import ImageIO

// Родной экран «Студии» со стороны утилиты: опрос /api/state только при открытом экране, снимок для провода, дело выбранной,
// значки, действия по утилите с теми же телами, что у страницы, и ошибки сервера (401, таймаут, 409, 500, сервер пропал).
// Процесс, система и сеть подменены: настоящая Студия, порт 47870 и её .cache не трогаются, папки временные.
// Запуск: Tests/run-studio-board-check.sh

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// MARK: Подмены

final class FakeSystem: StudioSystem {
    let uid: uid_t = geteuid()
    var owners: [Int32: uid_t] = [:]
    func owner(ofPid pid: Int32) -> uid_t? { owners[pid] }
    func listens(pid: Int32, port: Int) -> Bool { owners[pid] != nil }
}

/// Запускать здесь нечего: проверяется подключение к уже работающей Студии.
struct NoLauncher: StudioLauncher {
    func launch(executable: URL, directory: URL, environment: [String: String],
                onExit: @escaping @Sendable (Int32) -> Void) throws -> StudioProcess { throw URLError(.cannotConnectToHost) }
}

/// Сервер Студии в памяти. Отвечает как app/studio.py: 401 без токена, {"error"} на отказ, {"message"} на действие.
final class FakeStudio: StudioNetwork, @unchecked Sendable {
    struct Request: Equatable { let method: String; let path: String; let token: String; let body: String? }
    private let lock = NSLock()
    private var log: [Request] = []
    var token: String
    var stateJSON: String
    var down = false
    var timeoutPaths: Set<String> = []
    /// Путь → ошибка сети (обрыв, слишком длинный ответ). Запрос при этом уже дошёл до сервера.
    var failPaths: [String: URLError.Code] = [:]
    /// Путь → (код, тело) вместо обычного ответа.
    var overrides: [String: (Int, String)] = [:]
    /// Задержка ответа на действие: проверяет «действие ещё идёт».
    var actionDelay: TimeInterval = 0

    init(token: String, state: String) {
        self.token = token
        stateJSON = state
    }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }
    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }
    func set(_ change: (FakeStudio) -> Void) { lock.lock(); change(self); lock.unlock() }

    private func note(_ method: String, _ path: String, _ token: String, _ body: Data?) -> (token: String, down: Bool, timeout: Bool, override: (Int, String)?, state: String, fail: URLError.Code?) {
        lock.lock(); defer { lock.unlock() }
        log.append(Request(method: method, path: path, token: token, body: body.map { String(decoding: $0, as: UTF8.self) }))
        return (self.token, down, timeoutPaths.contains(path), overrides[path], stateJSON, failPaths[path])
    }

    func get(port: Int, path: String, token: String) async throws -> Data {
        let s = note("GET", path, token, nil)
        guard !s.down, token == s.token else { throw URLError(.cannotConnectToHost) }
        if path == "/api/ping" { return Data(#"{"app":"utilitumus-studio"}"#.utf8) }
        throw URLError(.badServerResponse)
    }

    func post(port: Int, path: String, token: String) async throws -> Data {
        let s = note("POST", path, token, nil)
        guard !s.down, token == s.token else { throw URLError(.cannotConnectToHost) }
        if path == "/api/boot" { return Data(#"{"boot":"bootbootbootbootboot"}"#.utf8) }
        throw URLError(.badServerResponse)
    }

    func request(method: String, port: Int, path: String, token: String, body: Data?, maxBytes: Int,
                 timeout: TimeInterval) async throws -> StudioReply {
        let s = note(method, path, token, body)
        if s.down { throw URLError(.cannotConnectToHost) }
        if s.timeout { throw URLError(.timedOut) }
        if let fail = s.fail { throw URLError(fail) }
        guard token == s.token else { return reply(401, #"{"error":"Нужен токен"}"#) }
        if let override = s.override { return reply(override.0, override.1) }
        if method == "POST", path.hasPrefix("/api/unit/") || path == "/api/commit" {
            if actionDelay > 0 { try? await Task.sleep(for: .seconds(actionDelay)) }
        }
        switch (method, path) {
        case ("GET", "/api/state"): return reply(200, s.state)
        case ("GET", let p) where p.hasPrefix("/api/unit/"):
            return reply(200, ###"{"case":"## Состояние\n- пункт `код`","queue":[{"done":false,"text":"задача"},{"done":true,"text":"старая"}],"casePath":"/s/utilities/mixer/case.md"}"###)
        case ("GET", "/icons/mixer.png"): return reply(200, String(decoding: pngData, as: UTF8.self), raw: pngData)
        case ("POST", "/api/commit"): return reply(200, #"{"message":"Записал дела: mixer"}"#)
        case ("POST", let p) where p.hasSuffix("/task"): return reply(200, #"{"message":"Задача №3 в очереди и у мастера"}"#)
        case ("POST", let p) where p.hasPrefix("/api/unit/"): return reply(200, #"{"message":"Сделано"}"#)
        default: return reply(404, #"{"error":"Нет такой страницы"}"#)
        }
    }

    private func reply(_ status: Int, _ text: String, raw: Data? = nil) -> StudioReply {
        StudioReply(status: status, data: raw ?? Data(text.utf8))
    }
}

/// Однотонный PNG 256×256 (как отдаёт Студия), собранный ImageIO.
let pngData: Data = {
    let side = 256
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = 10; pixels[i + 1] = 132; pixels[i + 2] = 255; pixels[i + 3] = 255 }
    let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}()

func unitJSON(_ id: String, kind: String = "utility", title: String? = nil, version: String? = "1.0", icon: Bool = false) -> String {
    let v = version.map { "\"\($0)\"" } ?? "null"
    return ##"{"id":"\##(id)","kind":"\##(kind)","title":"\##(title ?? id)","summary":"s","tint":"#0a84ff","version":\##(v),"status":"wip","openTasks":2,"bugs":0,"icon":\##(icon),"worktree":{"path":"/secret/\##(id)","branch":"mod/\##(id)","ahead":3},"master":{"state":"working","session":{"id":"sess","lastActive":1700000000000,"contextTokens":1,"contextPct":64}},"rotation":null}"##
}

let goodState = #"{"units":[\#(unitJSON("mixer", title: "Микшер", icon: true)),\#(unitJSON("fans", title: "Вентиляторы")),\#(unitJSON("launcher", kind: "launcher")),\#(unitJSON("orchestrator", kind: "orchestrator", version: nil))],"hubTasks":[{"name":"Выпуск","status":"todo","comment":"c"}],"orcaError":null}"#

// MARK: Стенд

let root: URL = {
    let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    precondition(url.path.contains("studio-board-check"), "стенд работает только во временной папке проверки")
    return url
}()
let fm = FileManager.default
var counter = 0

func makeFolder(token: String, port: Int, pid: Int32) -> URL {
    counter += 1
    let folder = root.appendingPathComponent("folder-\(counter)", isDirectory: true)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    writeServer(folder, port: port, pid: pid, token: token)
    return folder
}

func writeServer(_ folder: URL, port: Int, pid: Int32, token: String) {
    let cache = folder.appendingPathComponent(".cache", isDirectory: true)
    try? fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.removeItem(at: cache.appendingPathComponent("token"))
    fm.createFile(atPath: cache.appendingPathComponent("token").path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    try? fm.removeItem(at: cache.appendingPathComponent("server.json"))
    fm.createFile(atPath: cache.appendingPathComponent("server.json").path, contents: Data(#"{"port": \#(port), "pid": \#(pid)}"#.utf8),
                  attributes: [.posixPermissions: 0o600])
}

@MainActor func settle(_ what: @autoclosure () -> Bool, seconds: Double = 3) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if what() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return what()
}

@MainActor struct Rig {
    let controller: StudioController
    let studio: FakeStudio
    let system: FakeSystem
    let folder: URL
    let port: Int
    var runner: StudioRunner { controller.runner }
    var board: StudioBoard? { controller.state.board }
}

let suite = UserDefaults(suiteName: ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? "local.utilitumus.test.kit.studio-board")!

@MainActor func rig(token: String = "tokentokentokentoken1", state: String = goodState) async -> Rig {
    let port = 42000 + Int.random(in: 0..<3000)
    let pid: Int32 = 61000 + Int32(counter)
    let folder = makeFolder(token: token, port: port, pid: pid)
    let system = FakeSystem()
    system.owners[pid] = system.uid
    let studio = FakeStudio(token: token, state: state)
    let runner = StudioRunner(folder: folder.path, config: StudioRunner.Config(port: port, startTimeout: 1, pollInterval: 0.01, killAfter: 0.1),
                              launcher: NoLauncher(), network: studio, system: system)
    suite.set(folder.path, forKey: StudioKeys.folder)
    let controller = StudioController(runner: runner, defaults: suite)
    controller.board.interval = 0.05
    controller.start()
    _ = await settle(controller.state.phase == .running)
    return Rig(controller: controller, studio: studio, system: system, folder: folder, port: port)
}

func wire(_ action: StudioAction) -> Data { LinkWire.encoded(action) }
@MainActor func reply(_ rig: Rig, _ action: StudioAction) -> LinkReply<StudioState>? {
    try? JSONDecoder().decode(LinkReply<StudioState>.self, from: rig.controller.handle(wire(action)))
}

// MARK: Проверки

@MainActor func run() async {
    // Экран закрыт: опроса нет.
    var r = await rig()
    check(r.controller.state.phase == .running, "подключились к работающей Студии")
    try? await Task.sleep(for: .milliseconds(300))
    check(r.studio.count("/api/state") == 0 && r.board == nil, "экран закрыт: /api/state не опрашивается, снимка нет")

    // Экран открыт: опрос и снимок.
    r.controller.screenOpen(true)
    check(await settle(r.board?.units.count == 4), "экран открыт: снимок пришёл (4 записи)")
    let mixer = r.board?.unit("mixer")
    check(mixer?.title == "Микшер" && mixer?.branch == "mod/mixer" && mixer?.ahead == 3 && mixer?.contextPct == 64 && mixer?.master == .working,
          "поля утилиты: название, ветка, впереди, контекст, мастер")
    check(r.board?.hubTasks.first?.name == "Выпуск", "задачи хаба в снимке")
    check(await settle(r.board?.icons["mixer"] != nil), "значок пришёл")
    let icon = r.board?.icons["mixer"] ?? Data()
    check(icon.count <= StudioBoardParser.maxIconBytes && icon.starts(with: [0x89, 0x50, 0x4E, 0x47]), "значок: PNG в пределе (\(icon.count) байт)")
    _ = await settle(r.studio.count("/api/state") >= 6)
    check(r.studio.count("/icons/mixer.png") == 1, "значок берётся один раз, не на каждом опросе")
    check(r.studio.count("/icons/fans.png") == 0, "без значка у сервера значок не просим")
    let text = String(decoding: LinkWire.encoded(r.controller.state), as: UTF8.self)
    check(!text.contains("tokentokentoken") && !text.contains("/secret/") && !text.contains("sess"),
          "на проводе нет токена, пути папки мастера и id сессии")
    check(r.studio.requests.allSatisfy { $0.token == "tokentokentokentoken1" }, "все запросы с токеном Студии")

    // Выбор утилиты: дело грузится сразу, дальше на каждом третьем опросе.
    check(reply(r, .select("mixer"))?.error == nil, "выбор mixer принят")
    check(await settle(r.board?.detail?.id == "mixer"), "дело mixer пришло")
    check(r.board?.detail?.queue.count == 2 && r.board?.detail?.caseText.contains("## Состояние") == true, "очередь и дело разобраны")
    let statesBefore = r.studio.count("/api/state"), detailsBefore = r.studio.count("/api/unit/mixer")
    _ = await settle(r.studio.count("/api/state") >= statesBefore + 9)
    let polls = r.studio.count("/api/state") - statesBefore, details = r.studio.count("/api/unit/mixer") - detailsBefore
    check(details >= 2 && details <= polls / 2, "дело перечитывается не на каждом опросе (\(details) из \(polls))")
    check(reply(r, .select("nope"))?.error == "Нет такой утилиты", "выбор неизвестной — отказ")
    check(reply(r, .select("../x"))?.error == "Нет такой утилиты", "выбор с кривым id — отказ")
    _ = reply(r, .deselect)
    check(r.board?.selected == nil && r.board?.detail == nil, "снятие выбора убирает дело")

    // Действия: те же пути и тела, что у страницы.
    let posts = { r.studio.requests.filter { $0.method == "POST" && $0.path.hasPrefix("/api/") && $0.path != "/api/boot" } }
    check(reply(r, .task(unit: "mixer", text: "  сделай\u{1B} превью \n"))?.error == nil, "задача мастеру принята")
    check(await settle(posts().last?.path == "/api/unit/mixer/task"), "задача: POST /api/unit/mixer/task")
    check(posts().last?.body == #"{"text":"сделай превью"}"#, "задача: тело {text}, текст очищен (\(posts().last?.body ?? "nil"))")
    check(await settle(r.board?.notice?.text == "Задача №3 в очереди и у мастера" && r.board?.notice?.isError == false), "ответ сервера уведомлением")
    check(await settle(r.board?.working.isEmpty == true), "после ответа утилита свободна")
    let n1 = r.board?.notice?.id ?? 0
    _ = reply(r, .handToHub(unit: "mixer", text: "общее"))
    check(await settle(posts().last?.path == "/api/unit/mixer/hub" && posts().last?.body == #"{"text":"общее"}"#), "«Отдать хабу»: /hub с {text}")
    check(await settle((r.board?.notice?.id ?? 0) > n1), "каждое новое уведомление с новым номером")
    for (action, path) in [(StudioAction.openSession("mixer"), "/api/unit/mixer/open"), (.stand("mixer"), "/api/unit/mixer/stand"),
                           (.release("mixer"), "/api/unit/mixer/release"), (.rotate("mixer"), "/api/unit/mixer/rotate"),
                           (.commitCases, "/api/commit")] {
        _ = await settle(r.board?.working.isEmpty == true)
        check(reply(r, action)?.error == nil, "\(path): принято")
        check(await settle(posts().last?.path == path), "\(path): ушло на сервер")
        check(posts().last?.body == nil, "\(path): тело как у страницы ({} по умолчанию)")
    }
    _ = await settle(r.board?.notice?.text == "Записал дела: mixer")
    check(r.board?.notice?.text == "Записал дела: mixer", "«Записать дела»: ответ сервера")
    let sent = posts().count
    check(reply(r, .task(unit: "mixer", text: "  \n "))?.error == "Напиши задачу", "пустая задача — отказ на месте")
    check(reply(r, .task(unit: "mixer", text: String(repeating: "я", count: StudioText.maxLength + 1)))?.error?.contains("длиннее") == true,
          "длинная задача — отказ на месте")
    check(reply(r, .openSession("ghost"))?.error == "Нет такой утилиты", "действие над неизвестной — отказ")
    try? await Task.sleep(for: .milliseconds(100))
    check(posts().count == sent, "отказанные на месте до сервера не дошли")

    // Одно действие на утилиту сразу.
    r.studio.set { $0.actionDelay = 0.4 }
    _ = await settle(r.board?.working.isEmpty == true)
    check(reply(r, .stand("mixer"))?.error == nil, "долгое действие начато")
    check(r.board?.working == ["mixer"], "утилита помечена занятой")
    check(reply(r, .release("mixer"))?.error == "Это действие ещё идёт", "второе действие той же утилиты — отказ")
    check(reply(r, .stand("fans"))?.error == nil, "другая утилита при этом свободна")
    check(await settle(r.board?.working.isEmpty == true), "оба действия закончились")
    r.studio.set { $0.actionDelay = 0 }

    // Отказы сервера: его собственная строка.
    r.studio.set { $0.overrides["/api/unit/fans/open"] = (409, #"{"error":"Мастер ждёт ответа в своём терминале: сначала ответь ему"}"#) }
    _ = reply(r, .openSession("fans"))
    check(await settle(r.board?.notice?.text == "Мастер ждёт ответа в своём терминале: сначала ответь ему" && r.board?.notice?.isError == true),
          "409: строка сервера, как ошибка")
    r.studio.set { $0.overrides["/api/unit/fans/stand"] = (500, #"{"error":"Внутренняя ошибка Studio: подробности в её терминале"}"#) }
    _ = await settle(r.board?.working.isEmpty == true)
    _ = reply(r, .stand("fans"))
    check(await settle(r.board?.notice?.text == "Внутренняя ошибка Studio: подробности в её терминале"), "500: строка сервера")
    r.studio.set { $0.overrides["/api/unit/fans/release"] = (502, "<html>прокси</html>") }
    _ = await settle(r.board?.working.isEmpty == true)
    _ = reply(r, .release("fans"))
    check(await settle(r.board?.notice?.text == "Студия ответила ошибкой (502)"), "непонятный отказ: код, без чужой разметки")
    r.studio.set { $0.overrides["/api/unit/fans/rotate"] = (409, #"{"error":"\u001b[31mкрасный\u0007 \#(String(repeating: "x", count: 600))"}"#) }
    _ = await settle(r.board?.working.isEmpty == true)
    _ = reply(r, .rotate("fans"))
    check(await settle(r.board?.notice?.text.hasPrefix("[31mкрасный") == true), "строка сервера без управляющих знаков")
    check((r.board?.notice?.text.count ?? 999) <= 240, "строка сервера обрезана")

    // Обрыв после отправки: POST не повторяется (задача ушла бы дважды), модуль работает.
    _ = await settle(r.board?.working.isEmpty == true)
    r.studio.set { $0.failPaths["/api/unit/mixer/task"] = .networkConnectionLost }
    let tasksBefore = r.studio.count("/api/unit/mixer/task")
    _ = reply(r, .task(unit: "mixer", text: "один раз"))
    check(await settle(r.board?.notice?.text == "Студия не отвечает"), "обрыв: строка «не отвечает»")
    check(r.studio.count("/api/unit/mixer/task") == tasksBefore + 1, "обрыв: POST ушёл ровно один раз")
    check(r.controller.state.phase == .running, "обрыв, а сервер жив: модуль работает")
    r.studio.set { $0.failPaths["/api/unit/mixer/task"] = .dataLengthExceedsMaximum }
    _ = await settle(r.board?.working.isEmpty == true)
    _ = reply(r, .task(unit: "mixer", text: "длинно"))
    check(await settle(r.board?.notice?.text == "Студия ответила слишком длинно"), "длинный ответ: своя строка, без повтора")
    r.studio.set { $0.failPaths = [:] }

    // Частый выбор с провода не плодит запросов дела.
    r.studio.set { $0.actionDelay = 0 }
    let detailBefore = r.studio.count("/api/unit/fans")
    for _ in 0..<30 { _ = reply(r, .select("fans")) }
    try? await Task.sleep(for: .milliseconds(200))
    check(r.studio.count("/api/unit/fans") - detailBefore <= 3, "30 выборов подряд: дело запрошено \(r.studio.count("/api/unit/fans") - detailBefore) раз")
    _ = reply(r, .deselect)

    // Таймаут: строка, сервер не считается пропавшим.
    r.studio.set { $0.timeoutPaths = ["/api/state"] }
    check(await settle(r.board?.problem == "Студия не ответила вовремя"), "таймаут: понятная строка")
    check(r.controller.state.phase == .running && r.board?.units.count == 4, "таймаут: прежний снимок на месте, модуль работает")
    r.studio.set { $0.timeoutPaths = [] }
    check(await settle(r.board?.problem == nil), "ответил — строка ушла")

    // Студию перезапустили: новый токен в файлах, старый даёт 401. Утилита перечитывает файлы и повторяет.
    r.studio.set { $0.token = "newtokennewtokennewtoken2" }
    writeServer(r.folder, port: r.port, pid: 61000 + Int32(counter - 1), token: "newtokennewtokennewtoken2")
    let before401 = r.studio.requests.count
    check(await settle(r.studio.requests.dropFirst(before401).contains { $0.path == "/api/state" && $0.token == "newtokennewtokennewtoken2" }),
          "401: файлы перечитаны, опрос идёт с новым токеном")
    check(r.controller.state.phase == .running && r.board?.problem == nil, "401: модуль работает, ошибки нет")
    let oldTokenAfter = r.studio.requests.dropFirst(before401).filter { $0.path == "/api/state" && $0.token == "tokentokentokentoken1" }.count
    check(oldTokenAfter <= 1, "старый токен больше не уходит (\(oldTokenAfter))")

    // Токен сменился, а файлы старые: 401 остаётся — понятная строка, без петли.
    r.studio.set { $0.token = "thirdtokenthirdtoken3" }
    check(await settle(r.board?.problem == StudioAPIFailure.unauthorized.line), "401 без нового токена: строка «перезапущена»")

    // Экран закрыли: опрос остановлен, снимок забыт.
    r.studio.set { $0.token = "newtokennewtokennewtoken2" }
    r.controller.screenOpen(false)
    try? await Task.sleep(for: .milliseconds(80))
    let closedAt = r.studio.count("/api/state")
    try? await Task.sleep(for: .milliseconds(400))
    check(r.studio.count("/api/state") == closedAt, "экран закрыт: опрос остановлен")
    check(r.board == nil, "экран закрыт: снимка нет")
    check(reply(r, .openSession("mixer"))?.error == "Нет такой утилиты", "без снимка действия не идут")

    // Сервер пропал: ошибка модуля, без падения, опроса нет.
    r.controller.screenOpen(true)
    _ = await settle(r.board?.units.count == 4)
    r.studio.set { $0.down = true }
    r.system.owners = [:]
    check(await settle(r.controller.state.phase == .failed), "сервер пропал: модуль в ошибке")
    check(r.controller.state.message == "Студия перестала отвечать" && r.board == nil, "строка ошибки, снимок убран")
    let deadAt = r.studio.count("/api/state")
    try? await Task.sleep(for: .milliseconds(300))
    check(r.studio.count("/api/state") == deadAt, "после ошибки не опрашиваем")
    check(reply(r, .stand("mixer"))?.error == "Студия не запущена", "действия при ошибке — отказ строкой")
    r.controller.stop()

    // Кривой ответ: строка, без падения; плохие записи отброшены, поля обрезаны.
    r = await rig(token: "tokentokentokentoken9", state: "не json")
    r.controller.screenOpen(true)
    check(await settle(r.board?.problem == "Студия ответила непонятно"), "не JSON: «ответила непонятно»")
    let junk = #"{"units":[{"id":"Bad-Id","kind":"utility","title":"x"},{"id":"bidi","kind":"utility","title":"a\u202Eexe.txt\u200B\u2028b\u0085c","summary":"\u2066x\u2069"},{"id":"ok","kind":"alien","title":"x"},{"id":"good","kind":"utility","title":"\u001b[2Jзаг\nоловок","tint":"red","openTasks":"7","bugs":-3,"master":{"state":"dancing"}},{"id":"good","kind":"utility","title":"дубль"}],"hubTasks":"нет","orcaError":5}"#
    r.studio.set { $0.stateJSON = junk }
    check(await settle(r.board?.units.count == 2), "плохие id, неизвестный вид и дубли отброшены")
    check(r.board?.unit("bidi")?.title == "aexe.txt b" + "c" && r.board?.unit("bidi")?.summary == "x",
          "bidi-переворот, нулевая ширина, C1 убраны, разделитель строк стал пробелом (\(r.board?.unit("bidi")?.title.debugDescription ?? "nil"))")
    let good = r.board?.unit("good")
    check(good?.title == "[2Jзаг оловок", "управляющие знаки и переводы строки убраны из названия (\(good?.title ?? "nil"))")
    check(good?.tint == "#8e8e93" && good?.openTasks == 0 && good?.bugs == 0 && good?.master == StudioMasterState.none, "кривые поля — значения по умолчанию")
    check(r.board?.hubTasks.isEmpty == true && r.board?.orcaError == nil, "кривые задачи хаба и ошибка Orca не показываются")
    var ids: [String] = []
    for i in 0..<200 {
        let a = String(UnicodeScalar(UInt8(97 + i % 26))), b = String(UnicodeScalar(UInt8(97 + (i / 26) % 26)))
        ids.append("u" + a + b)
    }
    let many = "{\"units\":[" + ids.map { unitJSON($0) }.joined(separator: ",") + "]}"
    r.studio.set { $0.stateJSON = many }
    check(await settle((r.board?.units.count ?? 0) == StudioBoardParser.maxUnits), "записей не больше \(StudioBoardParser.maxUnits)")
    r.controller.stop()
    check(r.board == nil, "выключили: снимок забыт")

    // Значки: только PNG и только размера значка.
    check(StudioBoardParser.icon(from: pngData) != nil, "значок: PNG 256 принят")
    check(StudioBoardParser.icon(from: image(side: 2000, type: "public.png")) == nil, "значок: PNG 2000 точек — отказ до декодера")
    check(StudioBoardParser.icon(from: image(side: 64, type: "public.jpeg")) == nil, "значок: JPEG — отказ")
    check(StudioBoardParser.icon(from: image(side: 64, type: "public.tiff")) == nil, "значок: TIFF — отказ")
    var spoofed = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); spoofed.append(image(side: 64, type: "public.tiff"))
    check(StudioBoardParser.icon(from: spoofed) == nil, "значок: подпись PNG, внутри не PNG — отказ")

    // Текст задачи: невидимые знаки не уходят в терминал мастера.
    check(StudioText.task("a\u{9B}31mb\u{202E}c\u{200B}d\u{2028}e") == "a31mbcde", "задача: C1, bidi, нулевая ширина, U+2028 убраны")
}

func image(side: Int, type: String) -> Data {
    var pixels = [UInt8](repeating: 200, count: side * side * 4)
    let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

@main
struct Check {
    @MainActor static func main() async {
        await run()
        suite.removePersistentDomain(forName: ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? "local.utilitumus.test.kit.studio-board")
        print(failures == 0 ? "ВСЁ ЗЕЛЁНОЕ" : "ПРОВАЛОВ: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
