import AppKit
import SwiftUI

// Состояние, действия, проверки и экран «Микшера». Запуск: Tests/run-mixer-wire-check.sh
// `start()` здесь не вызывается: ни обхода HAL, ни тапов, звук не перехватывается.
// Роли: run <папка> — всё и снимки встроенного экрана; render <папка> — только снимки; compare <до> <после>.

/// Сюда скрипт направляет настройки контроллера в копии исходников.
let mixerStandDefaults = UserDefaults(suiteName: "local.utilitumus.test.mixer")!
/// Начальное значение `showOthers` на экране, та же правка копии.
var standShowOthers = false

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func finish() -> Never {
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - Снимки

@MainActor let window: NSWindow = {
    let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 1000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    window.orderBack(nil)
    return window
}()

/// Тема задаётся прямо в окружении: запись в настройки задела бы другие стенды.
@MainActor func snapshot(_ screen: some View, theme: DSTheme) async -> NSBitmapImageRep {
    let root = screen
        .environment(\.pageActive, true)
        .environment(\.dsTint, theme.accent(.mixer))
        .background(ZStack { Color.black; theme.card })
        .environment(\.dsTheme, theme)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 738, height: 1000)
    window.contentView = host
    await pause(0.5)
    host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
}

func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData else {
        return max(a.pixelsWide * a.pixelsHigh, b.pixelsWide * b.pixelsHigh)
    }
    let pixelBytes = a.bitsPerPixel / 8
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide where memcmp(pa + y * a.bytesPerRow + x * pixelBytes, pb + y * b.bytesPerRow + x * pixelBytes, pixelBytes) != 0 {
            count += 1
        }
    }
    return count
}

func solid(_ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        color.setFill()
        rect.fill()
        return true
    }
}

func row(_ id: String, _ name: String, _ color: NSColor, volume: Double = 1, muted: Bool = false) -> MixerApp {
    MixerApp(id: id, name: name, icon: solid(color), volume: volume, muted: muted)
}

// MARK: - Встроенный экран в закреплённых состояниях

struct Scene {
    let name: String
    var showOthers = false
    let pin: @MainActor () -> Void
}

@MainActor let scenes: [Scene] = {
    let c = MixerController.shared
    let playing = [row("com.a.music", "Музыка", .systemRed, volume: 0.4),
                   row("com.b.call", "Созвон", .systemBlue),
                   row("exe:afplay", "afplay", .systemGreen, volume: 0.15, muted: true)]
    let idle = [row("com.c.browser", "Браузер", .systemOrange, volume: 0.7), row("com.d.chat", "Чат", .systemPink, muted: true)]
    let preset = [row("com.e.gone", "Не запущено", .systemPurple, volume: 0.25), row("com.f.gone", "Тоже нет", .systemTeal, muted: true)]
    let other = [row("com.g.notes", "Заметки", .systemYellow), row("com.h.finder", "Файлы", .systemGray, volume: 0.5)]
    return [
        Scene(name: "empty") { c.testPin() },
        Scene(name: "playing") { c.testPin(apps: playing) },
        Scene(name: "all") { c.testPin(apps: playing, idle: idle, preset: preset, other: other) },
        Scene(name: "others-open", showOthers: true) { c.testPin(apps: playing, idle: idle, preset: preset, other: other) },
        Scene(name: "no-permission") { c.testPin(apps: playing, permissionProblem: true) },
        Scene(name: "no-permission-error") { c.testPin(permissionProblem: true, lastError: "Тап не получает звук") },
    ]
}()

/// Снимки настоящего встроенного экрана: в старой версии `MixerView()` тот же вызов.
@MainActor func renderBuiltIn(to dir: String) async -> [String: NSBitmapImageRep] {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var shots: [String: NSBitmapImageRep] = [:]
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        for scene in scenes {
            scene.pin()
            standShowOthers = scene.showOthers
            let shot = await snapshot(MixerView(), theme: theme)
            let name = "\(themeName)-\(scene.name)"
            shots[name] = shot
            try? shot.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
    standShowOthers = false
    return shots
}

#if !MIXER_BASELINE
func compare(_ before: String, _ after: String) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: before)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    check(names.count == 12, "снимков до правки \(names.count)")
    for name in names {
        guard let a = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(before)/\(name)"))) ?? Data()),
              let b = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: "\(after)/\(name)"))) ?? Data()) else {
            check(false, "\(name): снимок не прочитан")
            continue
        }
        let diff = differingPixels(a, b)
        check(diff == 0, "до и после правки \(name): разных пикселей \(diff) из \(a.pixelsWide * a.pixelsHigh)")
    }
}
#endif

#if !MIXER_BASELINE

// MARK: - Кодирование

func sorted(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(value)) ?? Data()
}

/// Как будет читать общий помощник связи: разбор и сверка с кодированием, чужой ключ разбор не видит.
func wireDecoded(_ text: String) -> MixerAction? {
    let data = Data(text.utf8)
    guard let action = try? JSONDecoder().decode(MixerAction.self, from: data), sorted(action) == data else { return nil }
    return action
}

let sampleState = MixerState(
    apps: [MixerAppState(id: "com.a.music", name: "Музыка «1»", volume: 0.57, muted: false),
           MixerAppState(id: "exe:afplay", name: "afplay", volume: 1.0 / 3, muted: true)],
    idleApps: [MixerAppState(id: "com.c", name: "Браузер", volume: 1, muted: false)],
    presetApps: [MixerAppState(id: "com.e", name: "Не запущено", volume: 0, muted: true)],
    otherApps: [MixerAppState(id: "com.g", name: "Заметки", volume: 0.5, muted: false)],
    permissionProblem: true, lastError: "Тап не получает звук")

func wirePure() {
    for (name, state) in [("полное", sampleState),
                          ("пустое", MixerState(apps: [], idleApps: [], presetApps: [], otherApps: [], permissionProblem: false, lastError: nil))] {
        let data = sorted(state)
        let back = try? JSONDecoder().decode(MixerState.self, from: data)
        check(back == state && back.map(sorted) == data, "состояние \(name) переживает кодирование, байты те же")
    }
    let rowKeys = (try? JSONSerialization.jsonObject(with: sorted(sampleState.apps[0]))) as? [String: Any]
    check(rowKeys.map { Set($0.keys) } == ["id", "name", "volume", "muted"], "в строке только id, name, volume, muted: иконки по связи нет")
    let old = #"{"apps":[],"idleApps":[],"otherApps":[],"permissionProblem":false,"presetApps":[],"будущее":1}"#
    check((try? JSONDecoder().decode(MixerState.self, from: Data(old.utf8))) != nil, "без lastError и с новым полем состояние читается")

    let actions: [MixerAction] = [.setVolume(id: "com.a/b", value: 0.57), .setVolume(id: "exe:x", value: 1.0 / 3), .setMuted(id: "com.a", muted: true),
                                  .reset(id: "com.a"), .commitVolumes]
    for action in actions {
        let text = String(decoding: sorted(action), as: UTF8.self)
        check(wireDecoded(text) == action, "действие переживает кодирование: \(text)")
    }
    for (name, text) in [("неизвестное действие", #"{"explode":{}}"#),
                         ("чужой ключ рядом", #"{"commitVolumes":{},"x":1}"#),
                         ("чужой ключ внутри", #"{"reset":{"id":"a","x":1}}"#),
                         ("два действия", #"{"commitVolumes":{},"reset":{"id":"a"}}"#),
                         ("без значения", #"{"setVolume":{"id":"a"}}"#),
                         ("громкость строкой", #"{"setVolume":{"id":"a","value":"1"}}"#),
                         ("pid вместо id", #"{"reset":{"id":4242}}"#),
                         ("пустой объект", "{}"),
                         ("не JSON", "{не json")] {
        check(wireDecoded(text) == nil, "\(name) не разбирается: \(text)")
    }
}

// MARK: - Проверки контроллера

@MainActor func validations() {
    let c = MixerController.shared
    let persisted = { mixerStandDefaults.dictionary(forKey: "MixerVolumes") as? [String: Double] ?? [:] }
    let pin = {
        c.testPin(apps: [row("com.a.music", "Музыка", .red)], idle: [row("com.c.idle", "Молчит", .red)],
                  preset: [row("com.e.preset", "Нет", .red, volume: 0.25)], other: [row("com.g.other", "Другое", .red)])
    }
    pin()
    check(c.handle(.commitVolumes) == nil, "commitVolumes принят")
    let savedBefore = persisted()
    check(savedBefore == ["com.e.preset": 0.25], "на диске только настроенное заранее")
    let before = c.wireState
    check(before.apps.map(\.id) == ["com.a.music"] && before.presetApps.first?.volume == 0.25, "wireState строит состояние из списков")

    let strangers = ["", "com.evil.app", "/Applications/Evil.app", "4242", "exe:evil", "com.apple.finder", String(repeating: "a", count: 100_000)]
    let refused: [(String, MixerAction)] = strangers.flatMap { id -> [(String, MixerAction)] in
        let shown = id.count > 40 ? "длинный id" : "«\(id)»"
        return [("setVolume \(shown)", .setVolume(id: id, value: 0.5)), ("setMuted \(shown)", .setMuted(id: id, muted: true)), ("reset \(shown)", .reset(id: id))]
    } + [("громкость NaN", .setVolume(id: "com.a.music", value: .nan)),
         ("громкость +∞", .setVolume(id: "com.a.music", value: .infinity)),
         ("громкость −∞", .setVolume(id: "com.a.music", value: -.infinity))]
    for (name, action) in refused {
        let error = c.handle(action)
        check(error != nil, "\(name): отказ («\(error ?? "нет")»)")
        check(c.wireState == before && !c.isMuted("com.evil.app"), "\(name): состояние то же")
    }
    _ = c.handle(.commitVolumes)
    check(persisted() == savedBefore, "после отказов на диске ни одного чужого id")
    check(c.volume(for: "com.a.music") == 1, "после отказов громкость та же")

    for id in ["com.a.music", "com.c.idle", "com.e.preset", "com.g.other"] {
        check(c.handle(.setMuted(id: id, muted: true)) == nil && c.isMuted(id), "id из показанного списка принят: \(id)")
        check(c.handle(.setMuted(id: id, muted: false)) == nil && !c.isMuted(id), "и снят: \(id)")
    }
    pin()

    check(c.handle(.setVolume(id: "com.a.music", value: 0.3)) == nil, "громкость 0,3 принята")
    check(c.apps.first?.volume == 1, "шаг ползунка списки пока не публикует")
    check(c.wireState.apps.first?.volume == 0.3, "но состояние уже говорит 0,3: ответ не откатит ползунок")
    check(c.handle(.commitVolumes) == nil && c.apps.first?.volume == 0.3 && persisted()["com.a.music"] == 0.3, "commitVolumes публикует и пишет на диск")
    check(c.handle(.setVolume(id: "com.a.music", value: 5)) == nil && c.volume(for: "com.a.music") == 1, "громкость 5 зажата до 1")
    check(c.handle(.setVolume(id: "com.a.music", value: -3)) == nil && c.volume(for: "com.a.music") == 0, "громкость −3 зажата до 0")
    check(c.handle(.setMuted(id: "com.a.music", muted: true)) == nil && c.wireState.apps.first?.muted == true, "setMuted виден в состоянии")
    check(c.handle(.reset(id: "com.a.music")) == nil && c.wireState.apps.first == MixerAppState(id: "com.a.music", name: "Музыка", volume: 1, muted: false), "reset возвращает 100 % и звук")
    c.setScreenLease(true); c.setScreenLease(false); c.setScreenVisible(true); c.setScreenVisible(false)

    c.stop()
    check(c.handle(.setVolume(id: "com.a.music", value: 0.5)) != nil && c.volume(for: "com.a.music") == 1, "после stop() списков нет, действие отвергнуто")
}

// MARK: - Иконки

func drawn(_ image: NSImage) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 52, pixelsHigh: 52, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: 52, height: 52))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func blank(_ rep: NSBitmapImageRep) -> Bool {
    (0..<rep.bytesPerRow * rep.pixelsHigh).allSatisfy { rep.bitmapData![$0] == 0 }
}

/// Приложение из системы, которое сейчас не запущено: пример «Настроены заранее».
func installedNotRunning() -> (id: String, path: String)? {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let dir = "/System/Applications"
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".app") {
        let path = "\(dir)/\(name)"
        if let id = Bundle(path: path)?.bundleIdentifier, !running.contains(id),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return (id, path) }
    }
    return nil
}

@MainActor func icons() {
    let generic = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
    check(!blank(drawn(generic)), "общий значок нарисован")
    check(differingPixels(drawn(MixerAppIcon.icon(for: "exe:afplay")), drawn(generic)) == 0, "exe: — общий значок")
    check(differingPixels(drawn(MixerAppIcon.icon(for: "com.utilitumus.no.such.app")), drawn(generic)) == 0, "неизвестный id — общий значок")

    // Те же источники, что у контроллера: `app.icon` в списках, `icon(forFile:)` в «Настроены заранее».
    var compared = 0, viaID = 0, viaFile = 0
    var fileDiffers: [String] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let id = app.bundleIdentifier, let icon = app.icon, let url = app.bundleURL else { continue }
        let reference = drawn(icon)
        compared += 1
        if differingPixels(reference, drawn(MixerAppIcon.icon(for: id))) == 0 { viaID += 1 }
        if differingPixels(reference, drawn(NSWorkspace.shared.icon(forFile: url.path))) == 0 { viaFile += 1 } else { fileDiffers.append(id) }
    }
    check(compared > 0 && viaID == compared, "запущенные: иконка по id как NSRunningApplication.icon, совпало \(viaID) из \(compared)")
    print("     проба обзора: NSRunningApplication.icon и icon(forFile:) совпали \(viaFile) из \(compared)" + (fileDiffers.isEmpty ? "" : ", разные: \(fileDiffers.joined(separator: ", "))"))

    if let app = installedNotRunning() {
        let reference = NSWorkspace.shared.icon(forFile: app.path)
        check(!blank(drawn(reference)) && differingPixels(drawn(MixerAppIcon.icon(for: app.id)), drawn(reference)) == 0, "незапущенное \(app.id): иконка как у «Настроены заранее»")
    } else {
        print("     все приложения из /System/Applications запущены: незапущенное не проверено")
    }
}

// MARK: - Экран с подставной моделью

/// Как будет работать модель лаунчера: списки из `MixerState`, иконки свои.
@MainActor final class FakeMixer: MixerModel {
    @Published var state: MixerState
    private(set) var visibility: [Bool] = []
    init(_ state: MixerState) { self.state = state }

    var apps: [MixerApp] { state.apps.map(MixerApp.init) }
    var idleApps: [MixerApp] { state.idleApps.map(MixerApp.init) }
    var presetApps: [MixerApp] { state.presetApps.map(MixerApp.init) }
    var otherApps: [MixerApp] { state.otherApps.map(MixerApp.init) }
    var permissionProblem: Bool { state.permissionProblem }
    var lastError: String? { state.lastError }
    var runsInUtility: Bool { false }
    func isMuted(_ id: String) -> Bool { false }
    func setVolume(_ value: Double, for id: String) {}
    func setMuted(_ value: Bool, for id: String) {}
    func reset(_ id: String) {}
    func commitVolumes() {}
    func setScreenVisible(_ value: Bool) { visibility.append(value) }
}

@MainActor func screens(_ builtIn: [String: NSBitmapImageRep]) async {
    let names = builtIn.keys.sorted()
    let dusk = names.filter { $0.hasPrefix("dusk-") }.compactMap { builtIn[$0] }
    var same = true
    for i in dusk.indices { for j in dusk.indices where i < j { same = same && differingPixels(dusk[i], dusk[j]) > 0 } }
    check(same && dusk.count == 6, "\(dusk.count) состояний экрана выглядят по-разному, снимки не пустые")
    check(differingPixels(builtIn["dusk-all"]!, builtIn["calm-all"]!) > 0, "тема меняет снимок")

    // Весь путь: контроллер → JSON → модель лаунчера с иконками по id. У контроллера иконки из его же источников.
    let c = MixerController.shared
    let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
    let generic = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
    var preset: [MixerApp] = []
    if let app = installedNotRunning() {
        preset = [MixerApp(id: app.id, name: "Не запущено", icon: NSWorkspace.shared.icon(forFile: app.path), volume: 0.25, muted: false)]
    }
    let apps = [MixerApp(id: "com.apple.finder", name: "Finder", icon: finder?.icon ?? generic, volume: 0.4, muted: false),
                MixerApp(id: "exe:afplay", name: "afplay", icon: generic, volume: 0.6, muted: true)]
    c.testPin(apps: apps, preset: preset, permissionProblem: true, lastError: "Тап не получает звук")
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        let local = await snapshot(MixerView(model: c), theme: theme)
        guard let received = try? JSONDecoder().decode(MixerState.self, from: sorted(c.wireState)) else { return check(false, "состояние не прочитано") }
        let fake = FakeMixer(received)
        let remote = await snapshot(MixerView(model: fake), theme: theme)
        let diff = differingPixels(local, remote)
        check(diff == 0, "\(themeName): контроллер и подставная модель с иконками по id, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
        check(fake.visibility == [true], "\(themeName): экран сказал модели, что открыт")
        window.contentView = nil
        await pause(0.2)
        check(fake.visibility == [true, false], "\(themeName): и что закрыт")

        // Снимок замечает чужую иконку: сравнение выше не пустое.
        c.testPin(apps: [MixerApp(id: "com.apple.finder", name: "Finder", icon: generic, volume: 0.4, muted: false)] + apps.dropFirst(), preset: preset, permissionProblem: true, lastError: "Тап не получает звук")
        let wrong = await snapshot(MixerView(model: c), theme: theme)
        check(differingPixels(local, wrong) > 0, "\(themeName): другая иконка видна на снимке")
        c.testPin(apps: apps, preset: preset, permissionProblem: true, lastError: "Тап не получает звук")
    }
}

#endif

// MARK: - Вход

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            switch args[1] {
            case "render":
                _ = await renderBuiltIn(to: args[2])
                finish()
            #if !MIXER_BASELINE
            case "compare":
                compare(args[2], args[3])
                finish()
            case "run":
                wirePure()
                validations()
                icons()
                let shots = await renderBuiltIn(to: args[2])
                await screens(shots)
                finish()
            #endif
            default:
                fatalError("неизвестная роль")
            }
        }
        app.run()
    }
}
