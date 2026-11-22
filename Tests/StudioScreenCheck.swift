import AppKit
import SwiftUI

// Экран «Студия» от начала до конца, без подмен процесса и сети: настоящий запуск `<папка>/studio`, настоящий URLSession до
// 127.0.0.1, родной экран на SwiftUI. Вместо Студии — Tests/fake-studio.py во временной папке на случайном порту: те же файлы в
// .cache, тот же JSON API. Опрос только при открытом экране, снимок утилит, значки, дело выбранной, действия с телами страницы,
// отказы сервера строками, «Открыть в браузере» по одноразовому коду. Настоящая Студия, порт 47870 и её .cache не трогаются.
// Снимки экрана — в <out>/png.
// Запуск: Tests/run-studio-screen-check.sh

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func settle(_ what: @autoclosure () -> Bool, seconds: Double = 20) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if what() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return what()
}

@MainActor enum Stand {
    static let size = NSSize(width: 1180, height: 960)
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    static func host(_ view: some View, _ theme: DSTheme) -> NSView {
        let host = NSHostingView(rootView: view
            .environment(\.dsTint, theme.accent(.studio))
            .background(ZStack { Color(white: 0.1); theme.card })
            .environment(\.dsTheme, theme)
            .preferredColorScheme(.dark)
            .ignoresSafeArea())
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    static func snapshot(_ host: NSView) async -> NSImage {
        // SwiftUI рисует на следующем проходе: даём ему кадр.
        try? await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

func logLines(_ log: URL) -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

/// Тела POST, как их получил сервер: путь и разобранный JSON.
func bodies(_ log: URL) -> [(path: String, body: [String: Any])] {
    logLines(URL(fileURLWithPath: log.path + ".bodies")).compactMap { line in
        guard let item = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let path = item["path"] as? String else { return nil }
        return (path, item["body"] as? [String: Any] ?? [:])
    }
}

@MainActor func send(_ controller: StudioController, _ action: StudioAction) -> String? {
    (try? JSONDecoder().decode(LinkReply<StudioState>.self, from: controller.handle(LinkWire.encoded(action))))?.error
}

@MainActor func run(work: URL, out: URL, port: Int) async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let folder = work.appendingPathComponent("studio-folder", isDirectory: true)
    let log = work.appendingPathComponent("requests.log")
    let theme = DSTheme.dusk

    let runner = StudioRunner(folder: folder.path, config: StudioRunner.Config(port: port, startTimeout: 20, pollInterval: 0.1, killAfter: 3),
                              launcher: StudioProcessLauncher(), network: StudioLiveNetwork(), system: StudioLiveSystem())
    // Браузер подменён: на стенде настоящий не открывается, а адрес нужно проверить.
    var opened: [URL] = []
    let controller = StudioController(runner: runner, defaults: Kit.defaults, openURL: { opened.append($0) })
    controller.board.interval = 0.3
    let model = StudioWindowModel(controller: controller)
    let host = Stand.host(StudioView(model: model), theme)
    let board = { controller.state.board }

    // Выключено: папка задана, сервер не идёт.
    check(send(controller, .setFolder(folder.path)) == nil, "папка принята")
    try? await Task.sleep(for: .milliseconds(300))
    check(controller.state.phase == .stopped && controller.state.folder == folder.path, "папка из экрана сохранена, сервер не запущен")
    Stand.write(await Stand.snapshot(host), to: out.appendingPathComponent("studio-stopped.png"))

    // Включили: настоящий процесс.
    controller.start()
    let up = await settle(controller.state.phase == .running)
    check(up && controller.state.ownsServer, "включили: Студия запущена этой утилитой")
    let tokenPath = folder.appendingPathComponent(".cache/token")
    let serverPath = folder.appendingPathComponent(".cache/server.json")
    let pid = ((try? Data(contentsOf: serverPath)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["pid"] as? Int ?? 0
    check(pid > 0 && kill(pid_t(pid), 0) == 0, "сервер жив, pid из server.json")
    var mode = stat()
    check(stat(tokenPath.path, &mode) == 0 && mode.st_mode & 0o077 == 0, "токен в .cache с правами 0600")
    let token = (try? String(contentsOf: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    // Экран закрыт: /api/state не опрашивается.
    try? await Task.sleep(for: .milliseconds(1000))
    check(!logLines(log).contains { $0.hasPrefix("GET /api/state") }, "экран закрыт: опроса нет")
    check(board() == nil, "экран закрыт: снимка нет")

    // Открыли экран: снимок, значки.
    controller.screenOpen(true)
    check(await settle(board()?.units.count == 8), "экран открыт: снимок из /api/state (\(board()?.units.count ?? 0) записей)")
    check(await settle(board()?.icons["mixer"] != nil && board()?.icons["fans"] != nil), "значки mixer и fans пришли")
    check((board()?.icons.values.map(\.count).max() ?? .max) <= StudioBoardParser.maxIconBytes, "значки в пределе провода")
    let wire = String(decoding: LinkWire.encoded(controller.state), as: UTF8.self)
    check(!token.isEmpty && !wire.contains(token), "на проводе нет токена")
    check(wire.utf8.count < 200_000, "состояние на проводе компактное (\(wire.utf8.count) байт)")
    check(logLines(log).contains("GET /api/state 200") && !logLines(log).contains { $0.contains(" 401") }, "запросы к API с токеном, без 401")
    Stand.write(await Stand.snapshot(host), to: out.appendingPathComponent("studio-board.png"))

    // Выбрали утилиту: дело и очередь.
    check(send(controller, .select("mixer")) == nil, "выбрали mixer")
    check(await settle(board()?.detail?.id == "mixer" && board()?.detail?.caseText.isEmpty == false), "дело mixer пришло")
    check(logLines(log).contains("GET /api/unit/mixer 200"), "дело только выбранной: /api/unit/mixer")
    check(!logLines(log).contains("GET /api/unit/fans 200"), "дело невыбранной не просим")
    Stand.write(await Stand.snapshot(host), to: out.appendingPathComponent("studio-detail.png"))

    // Действия: тела как у страницы.
    func lastBody(_ path: String) -> [String: Any]? { bodies(log).last { $0.path == path }?.body }
    check(send(controller, .task(unit: "mixer", text: "Превью скриншотов\nс Рабочего стола")) == nil, "задача мастеру отправлена")
    check(await settle(lastBody("/api/unit/mixer/task")?["text"] as? String == "Превью скриншотов\nс Рабочего стола"),
          "сервер получил {text} с переводом строки")
    check(await settle(board()?.notice?.text.hasPrefix("Задача №") == true && board()?.notice?.isError == false), "ответ сервера уведомлением")
    check(await settle(board()?.detail?.queue.contains { $0.text.hasPrefix("Превью скриншотов") } == true), "задача видна в очереди")
    _ = await settle(board()?.working.isEmpty == true)
    check(send(controller, .handToHub(unit: "mixer", text: "Общий выпуск иконок")) == nil, "«Отдать хабу» отправлено")
    check(await settle(lastBody("/api/unit/mixer/hub")?["text"] as? String == "Общий выпуск иконок"), "сервер получил /hub с {text}")
    check(await settle(board()?.hubTasks.contains { $0.name == "Общий выпуск иконок" } == true), "задача появилась у хаба")
    _ = await settle(board()?.working.isEmpty == true)
    check(send(controller, .rotate("mixer")) == nil, "смена мастера отправлена")
    check(await settle(board()?.unit("mixer")?.rotation?.running == true), "смена мастера идёт: видно в снимке")
    _ = await settle(board()?.working.isEmpty == true)
    check(send(controller, .stand("mixer")) == nil, "стенд отправлен")
    check(await settle(board()?.notice?.text == "Стенд собирается в терминале Orca"), "стенд: ответ сервера")
    _ = await settle(board()?.working.isEmpty == true)
    check(send(controller, .release("mixer")) == nil, "патч отправлен")
    check(await settle(board()?.notice?.text.hasPrefix("Просьба о патче") == true), "патч: ответ сервера")
    _ = await settle(board()?.working.isEmpty == true)
    check(send(controller, .commitCases) == nil, "«Записать дела» отправлено")
    check(await settle(board()?.notice?.text == "Записал дела: mixer"), "«Записать дела»: ответ сервера")
    check(["/api/unit/mixer/rotate", "/api/unit/mixer/stand", "/api/unit/mixer/release", "/api/commit"].allSatisfy { path in
        bodies(log).contains { $0.path == path && $0.body.isEmpty }
    }, "действия без текста: тело {} как у страницы")

    // Отказы сервера — его строкой, без падений.
    check(send(controller, .openSession("fans")) == nil, "открыть сессию fans отправлено")
    check(await settle(board()?.notice?.text == "Мастер ждёт ответа в своём терминале: сначала ответь ему" && board()?.notice?.isError == true),
          "409: строка сервера как ошибка")
    Stand.write(await Stand.snapshot(host), to: out.appendingPathComponent("studio-error.png"))
    _ = await settle(board()?.working.isEmpty == true)
    check(send(controller, .task(unit: "fans", text: "БУМ")) == nil, "задача, на которой сервер падает")
    check(await settle(board()?.notice?.text == "Внутренняя ошибка Studio: подробности в её терминале"), "500: строка сервера")
    check(send(controller, .task(unit: "fans", text: " \n ")) == "Напиши задачу", "пустая задача: отказ на месте, до сервера не идёт")
    check(controller.state.phase == .running, "после отказов модуль работает")

    // Открыть в браузере: одноразовый код берёт и открывает утилита, на провод он не попадает.
    check(!logLines(log).contains { $0.hasPrefix("POST /api/boot") }, "без «В браузере» код входа не берётся вовсе")
    model.openInBrowser()
    check(await settle(opened.count == 1 && logLines(log).contains("POST /api/boot 200")), "«В браузере»: утилита взяла код и открыла адрес")
    check(opened.first.flatMap { StudioNavigation.loginURL($0.absoluteString) }?.port == port && opened.first?.absoluteString.contains(token) == false,
          "адрес для браузера: 127.0.0.1, свой порт, код вместо токена")
    let fragment = opened.first?.fragment ?? "нет"
    check(!String(decoding: LinkWire.encoded(controller.state), as: UTF8.self).contains(fragment), "кода входа на проводе нет")

    // Настоящая сеть: длинный ответ обрывается на пределе, а не читается целиком.
    let live = StudioLiveNetwork()
    var cut: URLError.Code?
    do { _ = try await live.request(method: "GET", port: port, path: "/icons/mixer.png", token: "", body: nil, maxBytes: 64, timeout: 5) }
    catch { cut = (error as? URLError)?.code }
    check(cut == .dataLengthExceedsMaximum, "длинный ответ оборван на пределе (\(cut.map { "\($0.rawValue)" } ?? "прочитан"))")
    let whole = try? await live.request(method: "GET", port: port, path: "/icons/mixer.png", token: "", body: nil, maxBytes: 512 * 1024, timeout: 5)
    check(whole?.status == 200 && whole?.data.starts(with: [0x89, 0x50]) == true, "в пределе — читается целиком")

    // Закрыли экран: опрос остановлен.
    controller.screenOpen(false)
    try? await Task.sleep(for: .milliseconds(400))
    let polls = logLines(log).filter { $0.hasPrefix("GET /api/state") }.count
    try? await Task.sleep(for: .milliseconds(1200))
    check(logLines(log).filter { $0.hasPrefix("GET /api/state") }.count == polls, "экран закрыт: опрос остановлен")
    check(board() == nil, "экран закрыт: снимок забыт")

    // Выключили: свой сервер ушёл, файлы стёрты.
    controller.screenOpen(true)
    _ = await settle(board() != nil)
    controller.stop()
    let gone = await settle(kill(pid_t(pid), 0) != 0, seconds: 8)
    check(gone, "выключили: процесс сервера завершился")
    check(!FileManager.default.fileExists(atPath: tokenPath.path) && !FileManager.default.fileExists(atPath: serverPath.path), "токен и server.json стёрты самим сервером")
    check(controller.state.phase == .stopped && board() == nil, "состояние: остановлена, снимка нет")
    Stand.write(await Stand.snapshot(host), to: out.appendingPathComponent("studio-after-stop.png"))

    // Чужой сервер: запускаем как «кого-то другого», утилита подключается и при выключении не убивает.
    let foreign = Process()
    foreign.executableURL = folder.appendingPathComponent("studio")
    foreign.currentDirectoryURL = folder
    foreign.environment = ["PATH": "/usr/bin:/bin", "STUDIO_PORT": String(port), "STUDIO_OPEN": "none", "FAKE_STUDIO_LOG": log.path]
    foreign.standardOutput = FileHandle.nullDevice
    foreign.standardError = FileHandle.nullDevice
    try? foreign.run()
    defer { if foreign.isRunning { foreign.terminate() } }
    _ = await settle(FileManager.default.fileExists(atPath: serverPath.path))
    controller.start()
    let joined = await settle(controller.state.phase == .running)
    check(joined && !controller.state.ownsServer, "чужая Студия: подключились, не запускали своё")
    check(await settle(board()?.units.isEmpty == false), "с чужой Студией экран тоже показывает утилиты")
    controller.stop()
    try? await Task.sleep(for: .milliseconds(500))
    check(foreign.isRunning, "выключение чужую Студию не убивает")
    foreign.terminate()
    foreign.waitUntilExit()
}

@main
struct Check {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        let work = URL(fileURLWithPath: args[1], isDirectory: true)
        precondition(work.path.contains("studio-screen-check"), "работаем только во временной папке проверки")
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        await run(work: work, out: out, port: Int(args[3])!)
        print(failures == 0 ? "ВСЁ ЗЕЛЁНОЕ" : "ПРОВАЛОВ: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
