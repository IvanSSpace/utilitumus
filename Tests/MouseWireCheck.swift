import AppKit
import SwiftUI

// Модель, связь и экран модуля «Мышь». Запуск: Tests/run-mouse-wire-check.sh

let mouseCheckDefaults = UserDefaults(suiteName: "local.utilitumus.test.mouse-wire")!

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func wire(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try! encoder.encode(value)
}

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    let data = wire(value)
    guard let back = try? JSONDecoder().decode(T.self, from: data) else { return false }
    return back == value && wire(back) == data
}

/// Не пройдёт связь: не разбирается или кодируется обратно не теми же байтами (сверка общего помощника).
func refused(_ json: String) -> Bool {
    let data = Data(json.utf8)
    guard let action = try? JSONDecoder().decode(MouseAction.self, from: data) else { return true }
    return wire(action) != data
}

// MARK: - Связь

func wirePure() {
    let settings = MouseSettings(mouseDirection: .system, magicMouseDirection: .reversed, smoothEnabled: true,
                                 speed: 2.5, smoothness: 0.25)
    let state = MouseState(settings: settings, axTrusted: true, tapActive: false)
    check(roundTrips(state), "состояние: туда и обратно")
    check(String(decoding: wire(state), as: UTF8.self) == #"{"axTrusted":true,"settings":{"magicMouseDirection":"reversed","mouseDirection":"system","smoothEnabled":true,"smoothness":0.25,"speed":2.5},"tapActive":false}"#,
          "состояние: ключи отсортированы, форма закреплена")

    let actions: [MouseAction] = [
        .setMouseDirection(.reversed), .setMagicMouseDirection(.system), .setSmoothEnabled(true),
        .setSpeed(0.1 + 0.2), .setSmoothness(1.0 / 3), .refreshAccess, .requestAccess,
    ]
    check(actions.allSatisfy(roundTrips), "\(actions.count) действий: туда и обратно, те же байты")
    check(String(decoding: wire(MouseAction.setSpeed(1.5)), as: UTF8.self) == #"{"setSpeed":{"_0":1.5}}"#, "setSpeed: форма закреплена")

    for (name, json) in [
        ("чужое действие", #"{"explode":{}}"#),
        ("нет такого направления", #"{"setMouseDirection":{"_0":"sideways"}}"#),
        ("два действия", #"{"refreshAccess":{},"requestAccess":{}}"#),
        ("чужой ключ рядом", #"{"refreshAccess":{},"x":1}"#),
        ("чужой ключ внутри", #"{"setSpeed":{"_0":1.5,"x":1}}"#),
        ("скорость не число", #"{"setSpeed":{"_0":"nan"}}"#),
        ("скорость больше Double", #"{"setSpeed":{"_0":1e999}}"#),
        ("флаг не того типа", #"{"setSmoothEnabled":{"_0":1}}"#),
    ] {
        check(refused(json), "по связи не пройдёт: \(name)")
    }
}

// MARK: - Обработчик

@MainActor func handler() {
    let controller = MouseController.shared
    func saved() -> MouseSettings { MouseSettings.load(from: mouseCheckDefaults) }

    check(controller.handle(.setMouseDirection(.reversed)) == nil && controller.settings.mouseDirection == .reversed, "направление мыши")
    check(controller.handle(.setMagicMouseDirection(.reversed)) == nil && controller.settings.magicMouseDirection == .reversed, "направление Magic Mouse")
    check(controller.handle(.setSmoothEnabled(true)) == nil && controller.settings.smoothEnabled, "плавность включена")
    check(controller.handle(.setSpeed(2.3)) == nil && controller.settings.speed == 2.3, "скорость в диапазоне как есть")
    check(controller.handle(.setSmoothness(0.7)) == nil && controller.settings.smoothness == 0.7, "плавность в диапазоне как есть")
    check(saved() == controller.settings, "настройки записаны в suite стенда")
    check(UserDefaults.standard.object(forKey: "Mouse.Speed") == nil, ".standard не тронут")
    check(!controller.tapActive, "tap не запущен: контроллер не стартовал")

    for (name, action) in [
        ("скорость NaN", MouseAction.setSpeed(.nan)), ("скорость +inf", .setSpeed(.infinity)), ("скорость -inf", .setSpeed(-.infinity)),
        ("плавность NaN", .setSmoothness(.nan)), ("плавность +inf", .setSmoothness(.infinity)), ("плавность -inf", .setSmoothness(-.infinity)),
    ] {
        let before = controller.wireState
        let error = controller.handle(action)
        check(error != nil && controller.wireState == before && saved() == controller.settings, "\(name): отказ «\(error ?? "нет")», состояние то же")
    }

    for (name, action, speed, smoothness) in [
        ("скорость выше", MouseAction.setSpeed(100), 3.0, 0.7), ("скорость ниже", .setSpeed(-1), 0.5, 0.7),
        ("плавность выше", .setSmoothness(2), 0.5, 1.0), ("плавность ниже", .setSmoothness(-0.5), 0.5, 0.0),
    ] {
        check(controller.handle(action) == nil && controller.settings.speed == speed && controller.settings.smoothness == smoothness
              && saved() == controller.settings, "\(name): ограничена, скорость \(controller.settings.speed), плавность \(controller.settings.smoothness)")
    }

    let real = AXIsProcessTrusted()
    controller.testPin(axTrusted: !real, tapActive: false)
    check(controller.handle(.refreshAccess) == nil && controller.axTrusted == real, "refreshAccess читает настоящий доступ")
    let requests = controller.testAccessRequests
    check(controller.handle(.requestAccess) == nil && controller.testAccessRequests == requests + 1, "requestAccess доходит до запроса (заглушён)")

    controller.settings = MouseSettings()
    check(controller.wireState == MouseState(settings: MouseSettings(), axTrusted: controller.axTrusted, tapActive: false), "wireState собран из контроллера")
}

// MARK: - Экран

@MainActor final class FakeMouse: MouseModel {
    @Published var settings = MouseSettings()
    @Published var axTrusted = false
    @Published var tapActive = false
    var refreshes = 0
    func refreshAccess() { refreshes += 1 }
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor enum Stand {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    /// Корень как у страницы модуля, фон окна заменён непрозрачным цветом: он в `App`.
    /// Тема задана прямо: общий suite Kit стенд не пишет.
    static func host(_ view: some View, _ theme: DSTheme) -> NSView {
        let host = NSHostingView(rootView: view
            .environment(\.dsTint, theme.accent(.mouse))
            .background(ZStack { Color(white: 0.1); theme.card })
            .environment(\.dsTheme, theme)
            .preferredColorScheme(.dark)
            .ignoresSafeArea())
        host.frame = NSRect(x: 0, y: 0, width: 738, height: 660)
        window.contentView = host
        return host
    }

    static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
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

struct Scene {
    let name: String
    let settings: MouseSettings
    let axTrusted: Bool
    let tapActive: Bool
}

let scenes = [
    Scene(name: "как-в-системе", settings: MouseSettings(), axTrusted: false, tapActive: false),
    Scene(name: "обратное-работает", settings: MouseSettings(mouseDirection: .reversed), axTrusted: true, tapActive: true),
    Scene(name: "нет-доступа", settings: MouseSettings(magicMouseDirection: .reversed, smoothEnabled: true, speed: 2.3, smoothness: 0.7), axTrusted: false, tapActive: false),
    Scene(name: "запускаю", settings: MouseSettings(smoothEnabled: true, speed: 0.5, smoothness: 0), axTrusted: true, tapActive: false),
]

@MainActor func screen(out: String) async {
    let controller = MouseController.shared
    let fake = FakeMouse()
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        var shots: [NSBitmapImageRep] = []
        for scene in scenes {
            controller.settings = scene.settings
            fake.settings = scene.settings
            fake.axTrusted = scene.axTrusted
            fake.tapActive = scene.tapActive

            // onPageActive читает настоящий доступ при появлении, поэтому состояние ставится и после него.
            func shot(_ view: some View) async -> NSBitmapImageRep {
                let host = Stand.host(view, theme)
                await pause(0.3)
                controller.testPin(axTrusted: scene.axTrusted, tapActive: scene.tapActive)
                await pause(0.3)
                return Stand.snapshot(host)
            }
            let before = await shot(LegacyMouseView())
            let after = await shot(MouseView())
            let viaFake = await shot(MouseView(model: fake))
            let total = after.pixelsWide * after.pixelsHigh
            check(differingPixels(before, after) == 0, "\(themeName) \(scene.name): до и после, разных пикселей \(differingPixels(before, after)) из \(total)")
            check(differingPixels(after, viaFake) == 0, "\(themeName) \(scene.name): поддельная модель, разных пикселей \(differingPixels(after, viaFake))")
            try? after.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/png/\(themeName)-\(scene.name).png"))
            shots.append(after)
        }
        check(zip(shots, shots.dropFirst()).allSatisfy { differingPixels($0, $1) > 0 }, "\(themeName): состояния выглядят по-разному, снимки не пустые")
    }

    check(fake.refreshes > 0, "экран при появлении просит модель обновить доступ (\(fake.refreshes))")

    // Экран следит за моделью, а не за контроллером.
    fake.settings = MouseSettings()
    let host = Stand.host(MouseView(model: fake), .dusk)
    await pause(0.5)
    let plain = Stand.snapshot(host)
    fake.settings.smoothEnabled = true
    await pause(0.5)
    check(differingPixels(plain, Stand.snapshot(host)) > 0, "поддельная модель поменялась, экран перерисован")
}

@main enum MouseWireCheck {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        wirePure()
        handler()
        await screen(out: CommandLine.arguments[1])
        print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
