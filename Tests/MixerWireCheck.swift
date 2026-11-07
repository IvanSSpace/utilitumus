import AppKit
import SwiftUI

// Состояние, действия, проверки и экран «Микшера». Запуск: Tests/run-mixer-wire-check.sh
// `start()` здесь не вызывается: ни обхода HAL, ни тапов, звук не перехватывается.
// Роли: run <папка> — всё и снимки встроенного экрана; render <папка> — только снимки; compare <до> <после>.

/// Сюда скрипт направляет настройки контроллера в копии исходников.
let mixerStandDefaults = UserDefaults(suiteName: "local.utilitumus.test.mixer")!
/// Начальное значение `showOthers` на экране, та же правка копии.
var standShowOthers = false
/// Начальное значение `eqOpen` у строк, та же правка копии.
var standEqOpen = false

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

#if MIXER_BASELINE
func row(_ id: String, _ name: String, _ color: NSColor, volume: Double = 1, muted: Bool = false) -> MixerApp {
    MixerApp(id: id, name: name, icon: solid(color), volume: volume, muted: muted)
}
#else
/// Без `eq` строка как на связи со старым Микшером: кнопки эквалайзера нет, поэтому снимки сверяются с версией до него.
func row(_ id: String, _ name: String, _ color: NSColor, volume: Double = 1, muted: Bool = false, eq: MixerEqSetting? = nil) -> MixerApp {
    MixerApp(id: id, name: name, icon: solid(color), volume: volume, muted: muted, eq: eq)
}
#endif

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
                                  .reset(id: "com.a"), .commitVolumes, .setEqualizer(id: "com.a", enabled: true, preset: "custom", bands: [6, -3.5, 0, 12, -12, 1, 2, 3, 4, 5]), .setEqualizer(id: "exe:x", enabled: false, preset: "flat", bands: MixerEq.flat)]
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
                         ("не JSON", "{не json"),
                         ("эквалайзер без значений", #"{"setEqualizer":{"enabled":true,"id":"a","preset":"flat"}}"#),
                         ("эквалайзер без id", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"enabled":true,"preset":"flat"}}"#),
                         ("эквалайзер без выключателя", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"id":"a","preset":"flat"}}"#),
                         ("эквалайзер без режима", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a"}}"#),
                         ("эквалайзер: чужой ключ", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a","preset":"flat","x":1}}"#),
                         ("эквалайзер: выключатель числом", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"enabled":1,"id":"a","preset":"flat"}}"#),
                         ("эквалайзер: режим числом", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a","preset":1}}"#),
                         ("эквалайзер: строки", #"{"setEqualizer":{"bands":["0","0","0","0","0","0","0","0","0","0"],"enabled":true,"id":"a","preset":"flat"}}"#),
                         ("эквалайзер: null", #"{"setEqualizer":{"bands":[null,0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a","preset":"flat"}}"#),
                         ("эквалайзер: NaN строкой", #"{"setEqualizer":{"bands":["NaN",0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a","preset":"flat"}}"#),
                         ("эквалайзер: не массив", #"{"setEqualizer":{"bands":5,"enabled":true,"id":"a","preset":"flat"}}"#),
                         ("эквалайзер: вложенный массив", #"{"setEqualizer":{"bands":[[0],0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a","preset":"flat"}}"#),
                         ("эквалайзер: 1e400", #"{"setEqualizer":{"bands":[1e400,0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a","preset":"flat"}}"#)] {
        check(wireDecoded(text) == nil, "\(name) не разбирается: \(text)")
    }
    let withEq = MixerAppState(id: "com.a", name: "A", volume: 1, muted: false, eq: MixerEqSetting(enabled: true, preset: "voice", bands: MixerEq.flat))
    let eqKeys = (try? JSONSerialization.jsonObject(with: sorted(withEq))) as? [String: Any]
    check(eqKeys.map { Set($0.keys) } == ["id", "name", "volume", "muted", "eq"], "в строке нового Микшера ещё и eq")
}

// MARK: - Совместимость: типы связи настоящего Микшера 1.3.0 и лаунчера 0.9.0, взяты из тега скриптом

/// Состояние нового Микшера и его ответ для старого лаунчера, состояние старого для нового, действия в обе стороны. Без этого файла
/// (его кладёт скрипт) проверка не собирается: тихо пропустить её нельзя.
func compatibility() {
    let new = MixerState(
        apps: [MixerAppState(id: "com.a", name: "Музыка", volume: 0.5, muted: false, eq: MixerEqSetting(enabled: true, preset: "bass", bands: MixerEq.presets[1].bands!))],
        idleApps: [MixerAppState(id: "com.b", name: "Чат", volume: 1, muted: true, eq: .off)],
        presetApps: [MixerAppState(id: "com.c", name: "Нет", volume: 1, muted: false, eq: MixerEqSetting(enabled: false, preset: "custom", bands: MixerEq.flat))],
        otherApps: [], permissionProblem: false, lastError: nil)

    // Новый Микшер, лаунчер 0.9.0.
    let forOldHub = try? JSONDecoder().decode(OldMixerState.self, from: sorted(new))
    check(forOldHub?.apps.first?.id == "com.a" && forOldHub?.apps.first?.volume == 0.5 && forOldHub?.idleApps.first?.muted == true && forOldHub?.presetApps.count == 1,
          "лаунчер 0.9.0 читает состояние нового Микшера, поле eq не видит")
    let reply = LinkReply(state: new, error: nil)
    check((try? JSONDecoder().decode(LinkReply<OldMixerState>.self, from: sorted(reply)))?.state.apps.count == 1, "и его ответ на действие")
    let oldActions: [OldMixerAction] = [.setVolume(id: "com.a", value: 0.25), .setMuted(id: "com.a", muted: true), .reset(id: "com.a"), .commitVolumes]
    let newActions: [MixerAction] = [.setVolume(id: "com.a", value: 0.25), .setMuted(id: "com.a", muted: true), .reset(id: "com.a"), .commitVolumes]
    for (old, expected) in zip(oldActions, newActions) {
        let bytes = LinkWire.encoded(old)
        check(LinkWire.decodeAction(MixerAction.self, from: bytes, limit: 512) == expected, "новый Микшер принимает от лаунчера 0.9.0: \(String(decoding: bytes, as: UTF8.self))")
    }

    // Старый Микшер 1.3.0, новый лаунчер.
    let oldState = OldMixerState(apps: [OldMixerAppState(id: "com.a", name: "Музыка", volume: 0.5, muted: false)],
                                 idleApps: [OldMixerAppState(id: "com.b", name: "Чат", volume: 1, muted: true)],
                                 presetApps: [], otherApps: [], permissionProblem: true, lastError: "Тап не получает звук")
    let oldBytes = sorted(oldState)
    let forNewHub = try? JSONDecoder().decode(MixerState.self, from: oldBytes)
    check(forNewHub != nil && forNewHub?.apps.first?.eq == nil && forNewHub?.idleApps.first?.eq == nil, "новый лаунчер читает состояние Микшера 1.3.0, эквалайзера у строк нет")
    check(forNewHub.map(sorted) == oldBytes, "и без эквалайзера байты те же: nil по связи не идёт")
    for (new, old) in zip(newActions, oldActions) {
        let bytes = LinkWire.encoded(new)
        check(LinkWire.decodeAction(OldMixerAction.self, from: bytes, limit: 512) == old, "Микшер 1.3.0 принимает от нового лаунчера: \(String(decoding: bytes, as: UTF8.self))")
    }
    // Экран такого не пошлёт: кнопки нет. Но если придёт, старый откажет словами, а новый лаунчер прочитает отказ.
    let sent = LinkWire.encoded(MixerAction.setEqualizer(id: "com.a", enabled: true, preset: "voice", bands: MixerEq.flat))
    let answer = LinkWire.handle(sent, as: OldMixerAction.self, limit: 512, state: { oldState }) { _ in "не должно дойти" }
    let read = try? JSONDecoder().decode(LinkReply<MixerState>.self, from: answer)
    check(read?.error == "Непонятная команда" && read?.state.apps.first?.volume == 0.5, "Микшер 1.3.0 на действие эквалайзера: отказ «\(read?.error ?? "нет")», состояние то же")
    // Самое длинное настоящее действие укладывается в предел связи.
    let longest = LinkWire.encoded(MixerAction.setEqualizer(id: String(repeating: "a", count: 255), enabled: false, preset: "podcast", bands: [Double](repeating: -11.5, count: 10)))
    check(longest.count < 512, "действие с id из 255 байт: \(longest.count) байт, предел 512")
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
    let one = { (band: Int, value: Double) -> [Double] in
        var bands = MixerEq.flat
        bands[band] = value
        return bands
    }
    let eqBad: [(String, [Double])] = [("пусто", []), ("5 полос", [Double](repeating: 0, count: 5)), ("9 полос", [Double](repeating: 0, count: 9)), ("11 полос", [Double](repeating: 0, count: 11)), ("13 полос", [Double](repeating: 1, count: 13)),
                                       ("12,5 дБ", one(0, 12.5)), ("−12,5 дБ", one(9, -12.5)), ("NaN", one(1, .nan)),
                                       ("+Inf", one(2, .infinity)), ("−Inf", one(3, -.infinity)), ("1e308", one(4, 1e308))]
    for (name, bands) in eqBad {
        let error = c.handle(.setEqualizer(id: "com.a.music", enabled: true, preset: "custom", bands: bands))
        check(error != nil, "эквалайзер, \(name): отказ («\(error ?? "нет")»)")
        check(c.wireState == before && c.equalizer(for: "com.a.music") == .off, "эквалайзер, \(name): состояние то же")
    }
    for name in ["", "чужой", "Голос", String(repeating: "x", count: 100)] {
        check(c.handle(.setEqualizer(id: "com.a.music", enabled: true, preset: name, bands: MixerEq.flat)) != nil && c.wireState == before, "эквалайзер, режим «\(name.prefix(8))»: отказ")
    }
    for id in strangers {
        check(c.handle(.setEqualizer(id: id, enabled: true, preset: "voice", bands: MixerEq.flat)) != nil, "эквалайзер, чужой id \(id.count > 40 ? "длинный" : id): отказ")
    }
    // Настоящим входом, байтами: разбор тоже считается.
    let ones = { (n: Int) in Array(repeating: "1", count: n).joined(separator: ",") }
    let wire = { (bands: String) in "{\"setEqualizer\":{\"bands\":[\(bands)],\"enabled\":true,\"id\":\"com.a.music\",\"preset\":\"custom\"}}" }
    let raw: [(String, String)] = [
        ("9 полос", wire(ones(9))), ("11 полос", wire(ones(11))), ("13 полос", wire(ones(13))),
        ("значение 99", wire("99," + ones(9))),
        ("NaN в JSON", wire("NaN," + ones(9))),
        ("1e999 в JSON", wire("1e999," + ones(9))),
        ("не канонично", "{\"setEqualizer\":{\"id\":\"com.a.music\",\"bands\":[\(ones(10))],\"enabled\":true,\"preset\":\"custom\"}}"),
        ("очень длинное", wire(ones(400))),
    ]
    for (name, text) in raw {
        let reply = try? JSONDecoder().decode(LinkReply<MixerState>.self, from: c.handle(Data(text.utf8)))
        check(reply?.error != nil && reply?.state == before, "эквалайзер, байтами, \(name): отказ («\(reply?.error ?? "нет")»), состояние то же")
    }
    check((try? JSONDecoder().decode(LinkReply<MixerState>.self, from: c.handle(Data(wire(ones(10)).utf8))))?.error == nil, "ровно 10 чисел байтами приняты")
    _ = c.handle(.reset(id: "com.a.music"))
    _ = c.handle(.commitVolumes)
    check(persisted() == savedBefore, "после отказов на диске ни одного чужого id")
    check(MixerEqSettings.read(from: mixerStandDefaults).isEmpty, "после отказов и сброса на диске нет ни одного эквалайзера")
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
    check(c.handle(.reset(id: "com.a.music")) == nil && c.wireState.apps.first == MixerAppState(id: "com.a.music", name: "Музыка", volume: 1, muted: false, eq: .off), "reset возвращает 100 % и звук")

    // Эквалайзер: те же правила, что у громкости.
    let voice = MixerEqSetting(enabled: true, preset: "voice", bands: MixerEq.presets[3].bands!)
    let send = { (id: String, s: MixerEqSetting) in c.handle(.setEqualizer(id: id, enabled: s.enabled, preset: s.preset, bands: s.bands)) }
    check(send("com.a.music", voice) == nil, "эквалайзер принят")
    check(c.wireState.apps.first?.eq == voice, "сразу виден в состоянии")
    check(c.apps.first?.eq == nil, "список пока не публикуется: шаг регулятора не перерисовывает экран")
    check(c.handle(.commitVolumes) == nil && MixerEqSettings.read(from: mixerStandDefaults) == ["com.a.music": voice], "commitVolumes пишет эквалайзер на диск")
    var off = voice
    off.enabled = false
    check(send("com.a.music", off) == nil && c.equalizer(for: "com.a.music") == off && c.handle(.commitVolumes) == nil, "выключатель принят")
    check(c.equalizer(for: "com.a.music").bands == voice.bands && MixerEqSettings.read(from: mixerStandDefaults) == ["com.a.music": off], "значения выключенного помнятся и на диске")
    let flatOn = MixerEqSetting(enabled: true, preset: "flat", bands: MixerEq.flat)
    check(send("com.c.idle", voice) == nil && send("com.c.idle", .off) == nil && c.equalizer(for: "com.c.idle") == .off, "молчащему можно настроить заранее и снять")
    check(send("com.c.idle", flatOn) == nil && c.equalizer(for: "com.c.idle") == flatOn, "включённый ровный помнится")
    check(send("com.c.idle", .off) == nil && c.handle(.commitVolumes) == nil && MixerEqSettings.read(from: mixerStandDefaults) == ["com.a.music": off], "ненастроенного на диске нет")
    check(c.handle(.reset(id: "com.a.music")) == nil && c.equalizer(for: "com.a.music") == .off && MixerEqSettings.read(from: mixerStandDefaults).isEmpty, "reset снимает и эквалайзер")
    // Громкости на месте: старая версия читает свой ключ.
    check(c.handle(.setVolume(id: "com.a.music", value: 0.5)) == nil && c.handle(.commitVolumes) == nil && persisted()["com.a.music"] == 0.5, "ключ громкостей прежний")
    check(c.handle(.reset(id: "com.a.music")) == nil, "и сброшен")
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
    // Два запущенных с одним id (дев-сборка рядом с настоящей, значки у них разные): поиск по id отдаёт один на оба, сравнивать не с чем.
    let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let twice = Dictionary(grouping: regular.compactMap(\.bundleIdentifier)) { $0 }.filter { $0.value.count > 1 }.keys
    for app in regular where !twice.contains(app.bundleIdentifier ?? "") {
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
    var equalizerCalls: [MixerEqSetting] = []
    var commits = 0
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
    func setEqualizer(_ setting: MixerEqSetting, for id: String) { equalizerCalls.append(setting) }
    func reset(_ id: String) {}
    func commitVolumes() { commits += 1 }
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
        preset = [MixerApp(id: app.id, name: "Не запущено", icon: NSWorkspace.shared.icon(forFile: app.path), volume: 0.25, muted: false, eq: MixerEqSetting(enabled: true, preset: "custom", bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 3]))]
    }
    let apps = [MixerApp(id: "com.apple.finder", name: "Finder", icon: finder?.icon ?? generic, volume: 0.4, muted: false, eq: MixerEqSetting(enabled: true, preset: "bass", bands: MixerEq.presets[1].bands!)),
                MixerApp(id: "exe:afplay", name: "afplay", icon: generic, volume: 0.6, muted: true, eq: .off)]
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
        c.testPin(apps: [MixerApp(id: "com.apple.finder", name: "Finder", icon: generic, volume: 0.4, muted: false, eq: MixerEqSetting(enabled: true, preset: "bass", bands: MixerEq.presets[1].bands!))] + apps.dropFirst(), preset: preset, permissionProblem: true, lastError: "Тап не получает звук")
        let wrong = await snapshot(MixerView(model: c), theme: theme)
        check(differingPixels(local, wrong) > 0, "\(themeName): другая иконка видна на снимке")
        c.testPin(apps: apps, preset: preset, permissionProblem: true, lastError: "Тап не получает звук")
    }
    await equalizerScreens()
}

// MARK: - Экран эквалайзера

/// Какие пиксели отличаются: левая и правая граница по ширине, в пикселях снимка.
func differingColumns(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> ClosedRange<Int>? {
    guard let pa = a.bitmapData, let pb = b.bitmapData, a.bytesPerRow == b.bytesPerRow, a.pixelsHigh == b.pixelsHigh else { return 0...a.pixelsWide }
    let pixelBytes = a.bitsPerPixel / 8
    var low = Int.max, high = -1
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide where memcmp(pa + y * a.bytesPerRow + x * pixelBytes, pb + y * b.bytesPerRow + x * pixelBytes, pixelBytes) != 0 {
            low = min(low, x)
            high = max(high, x)
        }
    }
    return high < 0 ? nil : low...high
}

/// Настоящие события мыши в регулятор: перетаскивание, щелчок, двойной щелчок. Окно за экраном, системы они не касаются.
@MainActor func equalizerGestures() async {
    func model(_ eq: MixerEqSetting) -> FakeMixer {
        FakeMixer(MixerState(apps: [MixerAppState(id: "com.a.music", name: "Музыка", volume: 0.6, muted: false, eq: eq)], idleApps: [], presetApps: [], otherApps: [], permissionProblem: false, lastError: nil))
    }
    let start = MixerEqSetting(enabled: true, preset: "voice", bands: MixerEq.presets[3].bands!)
    standEqOpen = true
    defer { standEqOpen = false }
    let fake = model(start)
    let shot = await snapshot(MixerView(model: fake), theme: .dusk)
    guard let host = window.contentView, let data = shot.bitmapData else { return check(false, "регулятор: нет снимка") }
    // Первая полоса: самая левая чисто белая точка ниже заголовка, это левый край её ручки.
    let scale = shot.pixelsWide / 738
    var knob: NSPoint?
    search: for x in 0..<shot.pixelsWide {
        for y in (150 * scale)..<(500 * scale) {
            let p = data + y * shot.bytesPerRow + x * shot.bitsPerPixel / 8
            if p[0] == 255, p[1] == 255, p[2] == 255, p[3] == 255 {
                knob = NSPoint(x: CGFloat(x) / CGFloat(scale) + 8, y: CGFloat(y) / CGFloat(scale))
                break search
            }
        }
    }
    guard let knob else { return check(false, "регулятор: ручка не найдена") }
    func send(_ type: NSEvent.EventType, _ at: NSPoint, clicks: Int = 1) {
        let point = host.convert(at, to: nil)
        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) {
            window.sendEvent(event)
        }
    }
    func click(_ at: NSPoint, clicks: Int = 1) async {
        send(.leftMouseDown, at, clicks: clicks)
        await pause(0.02)
        send(.leftMouseUp, at, clicks: clicks)
        await pause(0.02)
    }
    // Один щелчок значение не меняет: иначе двойной сначала сдвигал бы ручку.
    await click(knob)
    await pause(0.4)
    check(fake.equalizerCalls.isEmpty, "щелчок по ручке значение не меняет")

    // Вверх на 20 pt: половина дорожки в 76 pt значит 12 дБ, то есть около +6.
    send(.leftMouseDown, knob)
    for step in 1...5 {
        await pause(0.02)
        send(.leftMouseDragged, NSPoint(x: knob.x, y: knob.y - CGFloat(step) * 4))
    }
    await pause(0.02)
    send(.leftMouseUp, NSPoint(x: knob.x, y: knob.y - 20))
    await pause(0.1)
    let dragged = fake.equalizerCalls.last
    check(dragged.map { $0.bands[0] > start.bands[0] + 4 && $0.bands[1...] == start.bands[1...] } == true, "перетаскивание вверх поднимает только свою полосу: \(dragged?.bands[0] ?? .nan)")
    check(dragged?.preset == MixerEq.customID, "ручная правка переключила режим на «Свой»")
    check(fake.commits > 0, "отпускание сохраняет")

    fake.equalizerCalls = []
    await click(knob, clicks: 1)
    await click(knob, clicks: 2)
    await pause(0.2)
    check(fake.equalizerCalls.last.map { $0.bands[0] == 0 && $0.bands[1...] == start.bands[1...] } == true, "двойной щелчок возвращает полосу в 0: \(fake.equalizerCalls.last?.bands[0] ?? .nan)")

    // Выключенный: регуляторы не откликаются.
    var off = start
    off.enabled = false
    let quiet = model(off)
    _ = await snapshot(MixerView(model: quiet), theme: .dusk)
    guard window.contentView != nil else { return }
    let quietHostPoint = knob
    let hostNow = window.contentView!
    func sendQuiet(_ type: NSEvent.EventType, _ at: NSPoint) {
        if let event = NSEvent.mouseEvent(with: type, location: hostNow.convert(at, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { window.sendEvent(event) }
    }
    sendQuiet(.leftMouseDown, quietHostPoint)
    await pause(0.02)
    sendQuiet(.leftMouseDragged, NSPoint(x: quietHostPoint.x, y: quietHostPoint.y - 20))
    await pause(0.02)
    sendQuiet(.leftMouseUp, NSPoint(x: quietHostPoint.x, y: quietHostPoint.y - 20))
    await pause(0.1)
    check(quiet.equalizerCalls.isEmpty, "выключенный: перетаскивание не меняет значения")

    // Выключатель: первый элемент панели слева. Отпускание сначала в очередь, тумблер ждёт его сам.
    let toggle = model(start)
    _ = await snapshot(MixerView(model: toggle), theme: .dusk)
    let toggleHost = window.contentView!
    var flipped = false
    // Над дорожками: первая дорожка начинается ниже выключателя, щелчок по ней значения не меняет.
    for y in stride(from: CGFloat(165), through: 195, by: 5) where !flipped {
        for x in stride(from: CGFloat(50), through: 94, by: 8) where !flipped {
            let point = toggleHost.convert(NSPoint(x: x, y: y), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { continue }
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            await pause(0.02)
            flipped = !toggle.equalizerCalls.isEmpty
        }
    }
    let flippedTo = toggle.equalizerCalls.last
    check(flippedTo?.enabled == false && flippedTo?.bands == start.bands && flippedTo?.preset == start.preset, "выключатель выключает, значения и режим те же")
}

/// Снимки в папке `MIXER_EQ_PNG` (не задана — рядом с остальными): строка закрыта, раскрыта, активна; Сумерки, Графит, Цветная.
@MainActor func equalizerScreens() async {
    let c = MixerController.shared
    let dir = ProcessInfo.processInfo.environment["MIXER_EQ_PNG"] ?? NSTemporaryDirectory() + "mixer-eq-png"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let active = MixerEqSetting(enabled: true, preset: "custom", bands: [6, 3, 0, -1.5, 0, 0, 2.5, 4, 5, 6])
    let voice = MixerEqSetting(enabled: true, preset: "voice", bands: MixerEq.presets[3].bands!)
    var disabled = active
    disabled.enabled = false
    let pin = { (eq: MixerEqSetting) in
        c.testPin(apps: [row("com.a.music", "Музыка", .systemRed, volume: 0.6, eq: eq)])
    }
    func save(_ shot: NSBitmapImageRep, _ name: String) {
        try? shot.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    // Старые снимки другого вида не должны лежать рядом.
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".png") { try? FileManager.default.removeItem(atPath: "\(dir)/\(name)") }
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("graphite", DSTheme.graphite), ("vivid", DSTheme.vivid)] {
        standEqOpen = false
        pin(.off)
        let closed = await snapshot(MixerView(), theme: theme)
        pin(active)
        let lit = await snapshot(MixerView(), theme: theme)
        pin(disabled)
        let closedDisabled = await snapshot(MixerView(), theme: theme)
        standEqOpen = true
        pin(.off)
        let open = await snapshot(MixerView(), theme: theme)
        pin(active)
        let openLit = await snapshot(MixerView(), theme: theme)
        pin(voice)
        let openVoice = await snapshot(MixerView(), theme: theme)
        pin(disabled)
        let openOff = await snapshot(MixerView(), theme: theme)
        standEqOpen = false
        for (name, shot) in [("closed", closed), ("active", lit), ("open", open), ("open-active", openLit), ("open-voice", openVoice), ("open-off", openOff)] {
            save(shot, "\(themeName)-\(name)")
        }
        // Кнопка 24 pt: подсветка меняет только её, раскладка стоит на месте.
        let scale = lit.pixelsWide / 738
        if let columns = differingColumns(closed, lit) {
            check(columns.count <= 26 * scale, "\(themeName): активная кнопка меняет только себя, отличие шириной \(columns.count) пикселей при масштабе \(scale)")
        } else {
            check(false, "\(themeName): активная кнопка не видна")
        }
        check(differingPixels(closed, closedDisabled) == 0, "\(themeName): выключенный со значениями в закрытой строке не подсвечен")
        check(differingPixels(closed, open) > 0, "\(themeName): раскрытая строка видна")
        check(differingPixels(open, openLit) > 0 && differingPixels(openLit, openVoice) > 0, "\(themeName): значения регуляторов и режим видны")
        check(differingPixels(openLit, openOff) > 0, "\(themeName): выключенный приглушён, но виден")
    }
    await equalizerGestures()
    // Со старым Микшером кнопки нет: строка без `eq` не то же, что строка с ней.
    c.testPin(apps: [row("com.a.music", "Музыка", .systemRed, volume: 0.6)])
    let noEqualizer = await snapshot(MixerView(), theme: .dusk)
    pin(.off)
    check(differingPixels(noEqualizer, await snapshot(MixerView(), theme: .dusk)) > 0, "строка со старым Микшером без кнопки эквалайзера")
    // Открытый без значений: панели нет, на экране та же строка.
    standEqOpen = true
    c.testPin(apps: [row("com.a.music", "Музыка", .systemRed, volume: 0.6)])
    check(differingPixels(noEqualizer, await snapshot(MixerView(), theme: .dusk)) == 0, "без значений панели нет, даже если строка считается раскрытой")
    standEqOpen = false
    // Модель со старой стороны: состояние из байтов Микшера 1.3.0, экран открывается.
    let old = OldMixerState(apps: [OldMixerAppState(id: "com.a.music", name: "Музыка", volume: 0.6, muted: false)], idleApps: [], presetApps: [], otherApps: [], permissionProblem: false, lastError: nil)
    guard let received = try? JSONDecoder().decode(MixerState.self, from: sorted(old)) else { return check(false, "старое состояние не прочитано") }
    let remote = await snapshot(MixerView(model: FakeMixer(received)), theme: .dusk)
    check(remote.pixelsWide == noEqualizer.pixelsWide && differingPixels(remote, noEqualizer) < remote.pixelsWide * remote.pixelsHigh / 100, "экран на состоянии Микшера 1.3.0 открывается, без эквалайзера: отличается только значок приложения")
    window.contentView = nil
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
            case "eq-write":
                let c = MixerController.shared
                c.testPin(apps: [row("com.next.run", "Следующий запуск", .red, eq: .off)])
                check(c.handle(.setEqualizer(id: "com.next.run", enabled: true, preset: "night", bands: MixerEq.presets[6].bands!)) == nil, "настройка принята")
                check(c.handle(.commitVolumes) == nil, "и записана")
                mixerStandDefaults.synchronize()
                finish()
            case "eq-read":
                // Здесь нет ни одной записи: контроллер читает настройки при создании, как утилита после перезапуска.
                let saved = MixerController.shared.equalizer(for: "com.next.run")
                check(saved == MixerEqSetting(enabled: true, preset: "night", bands: MixerEq.presets[6].bands!), "другой процесс прочитал настройку приложения по его id: \(saved.preset)")
                check(saved.isActive, "значит, тап будет создан при первом звуке")
                finish()
            case "run":
                wirePure()
                compatibility()
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
