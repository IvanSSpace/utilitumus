import AppKit
import SwiftUI
import WebKit

// Экран «Студия» от начала до конца, без подмен процесса и сети: настоящий запуск `<папка>/studio`, настоящий URLSession до 127.0.0.1,
// настоящий WKWebView. Вместо Студии — Tests/fake-studio.py во временной папке на случайном порту: те же файлы в .cache, тот же вход
// по одноразовому коду. Настоящая Студия, порт 47870 и её .cache не трогаются. Снимки экрана — в <out>/png.
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

func findWebView(_ view: NSView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    for sub in view.subviews { if let found = findWebView(sub) { return found } }
    return nil
}

@MainActor func evaluate(_ web: WKWebView, _ js: String) async -> String? {
    await withCheckedContinuation { continuation in
        web.evaluateJavaScript(js) { value, _ in continuation.resume(returning: value as? String) }
    }
}

@MainActor enum Stand {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 900, height: 1010), styleMask: [.borderless], backing: .buffered, defer: false)
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
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 1010)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Оболочка экрана рисуется как есть, а содержимое WKWebView берётся его собственным снимком и кладётся на своё место:
    /// cacheDisplay веб-содержимое не отдаёт.
    static func snapshot(_ host: NSView) async -> NSImage {
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        guard let web = findWebView(host) else { return image }
        let config = WKSnapshotConfiguration()
        let shot: NSImage? = await withCheckedContinuation { continuation in
            web.takeSnapshot(with: config) { image, _ in continuation.resume(returning: image) }
        }
        guard let shot else { return image }
        var frame = host.convert(web.bounds, from: web)
        if host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
        image.lockFocus()
        shot.draw(in: frame)
        image.unlockFocus()
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

@MainActor func run(work: URL, out: URL, port: Int) async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let folder = work.appendingPathComponent("studio-folder", isDirectory: true)
    let log = work.appendingPathComponent("requests.log")
    let theme = DSTheme.dusk

    let runner = StudioRunner(folder: folder.path, config: StudioRunner.Config(port: port, startTimeout: 20, pollInterval: 0.1, killAfter: 3),
                              launcher: StudioProcessLauncher(), network: StudioLiveNetwork(), system: StudioLiveSystem())
    let controller = StudioController(runner: runner, defaults: Kit.defaults)
    let model = StudioWindowModel(controller: controller)
    let host = Stand.host(StudioView(model: model), theme)

    // Выключено: папка задана, сервер не идёт.
    _ = controller.handle(LinkWire.encoded(StudioAction.setFolder(folder.path)))
    try? await Task.sleep(for: .milliseconds(300))
    check(controller.state.phase == .stopped && controller.state.folder == folder.path, "папка из экрана сохранена, сервер не запущен")
    Stand.write(await Stand.snapshot(host), to: out.appendingPathComponent("studio-stopped.png"))

    // Включили: настоящий процесс, настоящий вход.
    controller.start()
    let up = await settle(controller.state.phase == .running)
    check(up && controller.state.ownsServer, "включили: Студия запущена этой утилитой")
    check(controller.state.page.flatMap { StudioNavigation.loginURL($0) }?.port == port, "адрес входа: 127.0.0.1 и свой порт")
    let tokenPath = folder.appendingPathComponent(".cache/token")
    let serverPath = folder.appendingPathComponent(".cache/server.json")
    let pid = ((try? Data(contentsOf: serverPath)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["pid"] as? Int ?? 0
    check(pid > 0 && kill(pid_t(pid), 0) == 0, "сервер жив, pid из server.json")
    var mode = stat()
    check(stat(tokenPath.path, &mode) == 0 && mode.st_mode & 0o077 == 0, "токен в .cache с правами 0600")
    let token = (try? String(contentsOf: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    check(!token.isEmpty && !(controller.state.page ?? "").contains(token) && !String(decoding: controller.handle(LinkWire.encoded(StudioAction.newLogin)), as: UTF8.self).contains(token),
          "токена нет ни в адресе, ни в ответе по проводу")

    // Страница загрузилась в WKWebView и вошла по коду.
    let web = await { () -> WKWebView? in
        _ = await settle(findWebView(host) != nil)
        return findWebView(host)
    }()
    check(web != nil, "страница Студии показана в WKWebView внутри экрана")
    guard let web else { return finish(pid) }
    let entered = await settle({ logLines(log).contains("POST /api/session 200") }())
    check(entered, "страница вошла по одноразовому коду (/api/session)")
    var who: String?
    _ = await settle({ false }(), seconds: 0.5)
    for _ in 0..<40 {
        who = await evaluate(web, "document.getElementById('who') && document.getElementById('who').textContent")
        if who == "вход выполнен" { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    check(who == "вход выполнен", "в самой странице видно «вход выполнен» (\(who ?? "nil"))")
    check(web.url?.absoluteString == "http://127.0.0.1:\(port)/", "адрес после входа без кода: \(web.url?.absoluteString ?? "nil")")
    let lines = logLines(log)
    check(lines.contains("GET /api/ping 200") && lines.contains("POST /api/boot 200") && lines.contains("GET / 200"), "сервер видел ping, boot и страницу")
    Stand.write(await Stand.snapshot(host), to: out.appendingPathComponent("studio-running.png"))

    // «Обновить»: новый код, страница грузится заново и входит снова.
    let sessionsBefore = logLines(log).filter { $0 == "POST /api/session 200" }.count
    model.newLogin()
    let refreshed = await settle(logLines(log).filter { $0 == "POST /api/session 200" }.count > sessionsBefore)
    check(refreshed, "«обновить»: новый код входа, страница вошла снова")

    // Страница не может уйти с адреса Студии: file:// не открывается.
    _ = await evaluate(web, "location.href = 'file:///etc/hosts'; 'ok'")
    try? await Task.sleep(for: .milliseconds(800))
    check(web.url?.scheme == "http" && web.url?.host == "127.0.0.1", "переход на file:// отменён: страница на месте (\(web.url?.absoluteString ?? "nil"))")

    // Выключили: свой сервер ушёл, файлы стёрты.
    controller.stop()
    let gone = await settle(kill(pid_t(pid), 0) != 0, seconds: 8)
    check(gone, "выключили: процесс сервера завершился")
    check(!FileManager.default.fileExists(atPath: tokenPath.path) && !FileManager.default.fileExists(atPath: serverPath.path), "токен и server.json стёрты самим сервером")
    check(controller.state.phase == .stopped && controller.state.page == nil, "состояние: остановлена, страницы нет")
    try? await Task.sleep(for: .milliseconds(200))
    check(findWebView(host) == nil, "страница убрана с экрана")
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
    controller.stop()
    try? await Task.sleep(for: .milliseconds(500))
    check(foreign.isRunning, "выключение чужую Студию не убивает")
    foreign.terminate()
    foreign.waitUntilExit()
}

/// Если проверка оборвалась: сервер не оставляем.
@MainActor func finish(_ pid: Int) {
    if pid > 0, kill(pid_t(pid), 0) == 0 { kill(pid_t(pid), SIGTERM) }
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
