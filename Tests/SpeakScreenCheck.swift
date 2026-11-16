import AppKit
import SwiftUI

// Экран «Озвучки» так, как его собирает центр: только Sources/Modules/Speak/UI, Kit и модель вкладки центра на подставной связи.
// Утилиты, звука, AX, сочетания и сети нет. Запуск: Tests/run-speak-screen-check.sh <папка снимков>.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func pause(_ seconds: Double = 0.3) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

let fixtureVoices = [
    SpeakVoiceRow(id: "ru.milena", name: "Milena", language: "ru-RU", quality: .regular),
    SpeakVoiceRow(id: "ru.katya", name: "Katya", language: "ru-RU", quality: .enhanced),
    SpeakVoiceRow(id: "ru.yuri", name: "Yuri", language: "ru-RU", quality: .premium),
    SpeakVoiceRow(id: "en.samantha", name: "Samantha", language: "en-US", quality: .regular),
    SpeakVoiceRow(id: "en.daniel", name: "Daniel", language: "en-GB", quality: .enhanced),
    SpeakVoiceRow(id: "en.alex", name: "Alex", language: "en-US", quality: .enhanced),
]

func fixtureState(phase: SpeakPhase = .idle) -> SpeakState {
    SpeakState(speed: 1.5, pinnedVoices: [:], voices: fixtureVoices, phase: phase, message: nil,
               hotKeyLabel: VoiceHotKey.label(keyCode: SpeakKeys.defaultKeyCode, modifiers: SpeakKeys.defaultModifiers),
               hotKeyError: nil, keyCode: SpeakKeys.defaultKeyCode, modifiers: SpeakKeys.defaultModifiers,
               accessibilityTrusted: true, canStart: true)
}

/// Модель-фикстура: показывает заданное состояние, каждое нажатие записывает действием связи.
@MainActor
final class FixtureSpeakModel: SpeakModel {
    @Published var state: SpeakState
    var sent: [SpeakAction] = []

    init(_ state: SpeakState) { self.state = state }

    var speed: Double { state.speed }
    var pinnedVoices: [String: String] { state.pinnedVoices }
    var voices: [SpeakVoiceRow] { state.voices }
    var phase: SpeakPhase { state.phase }
    var message: String? { state.message }
    var hotKeyLabel: String { state.hotKeyLabel }
    var hotKeyError: String? { state.hotKeyError }
    var accessibilityTrusted: Bool { state.accessibilityTrusted }
    var canStart: Bool { state.canStart }

    func setSpeed(_ value: Double) { sent.append(.setSpeed(value)) }
    func stepSpeed(_ direction: Int) { sent.append(.stepSpeed(direction)) }
    func setVoiceAuto() { sent.append(.setVoiceAuto) }
    func pinVoice(language: String, id: String) { sent.append(.pinVoice(language: language, id: id)) }
    func unpin(language: String) { sent.append(.unpin(language: language)) }
    func pause() { sent.append(.pause) }
    func resume() { sent.append(.resume) }
    func stopSpeaking() { sent.append(.stop) }
    func refreshPermissions() { sent.append(.refreshPermissions) }
    func requestAccessibility() { sent.append(.requestAccessibility) }
    func setHotKey(keyCode: UInt32, modifiers: UInt32) { sent.append(.setHotKey(keyCode: keyCode, modifiers: modifiers)) }
    func resetHotKey() { sent.append(.resetHotKey) }
    func suspendHotKey() { sent.append(.suspendHotKey) }
    func resumeHotKey() { sent.append(.resumeHotKey) }
}

/// Имя действия. Новый case сломает сборку проверки, пока его сюда не добавят.
func actionName(_ action: SpeakAction) -> String {
    switch action {
    case .setSpeed: return "setSpeed"
    case .stepSpeed: return "stepSpeed"
    case .setVoiceAuto: return "setVoiceAuto"
    case .pinVoice: return "pinVoice"
    case .unpin: return "unpin"
    case .pause: return "pause"
    case .resume: return "resume"
    case .stop: return "stop"
    case .setHotKey: return "setHotKey"
    case .resetHotKey: return "resetHotKey"
    case .suspendHotKey: return "suspendHotKey"
    case .resumeHotKey: return "resumeHotKey"
    case .refreshPermissions: return "refreshPermissions"
    case .requestAccessibility: return "requestAccessibility"
    }
}
let allActionNames: Set<String> = ["setSpeed", "stepSpeed", "setVoiceAuto", "pinVoice", "unpin", "pause", "resume", "stop",
                                   "setHotKey", "resetHotKey", "suspendHotKey", "resumeHotKey", "refreshPermissions",
                                   "requestAccessibility"]

// MARK: - Снимки

@MainActor enum Shots {
    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    /// Как страница в окне центра: фон модуля, карточка, тёмная тема. Тема задана прямо: настройки не читаются.
    static func render(_ view: some View, width: CGFloat, height: CGFloat) async -> NSBitmapImageRep {
        let theme = DSTheme.dusk
        let host = NSHostingView(rootView: AnyView(view
            .environment(\.pageActive, true)
            .environment(\.dsTheme, theme)
            .background(ZStack {
                LinearGradient(colors: theme.background(.speak), startPoint: .top, endPoint: .bottom)
                theme.card
            })
            .preferredColorScheme(.dark)
            .ignoresSafeArea()))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView = host
        await pause(0.6)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, _ dir: String, _ name: String) {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return check(false, "\(name): PNG не собрался") }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        do {
            try png.write(to: url)
            print("     снимок: \(url.path)")
        } catch {
            check(false, "\(name): не записан (\(error.localizedDescription))")
        }
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
        for x in 0..<a.pixelsWide where memcmp(pa + y * a.bytesPerRow + x * pixelBytes, pb + y * a.bytesPerRow + x * pixelBytes, pixelBytes) != 0 {
            count += 1
        }
    }
    return count
}

// MARK: - Подписи

@MainActor func labels() {
    check(SpeakSpeed.label(1) == "1×" && SpeakSpeed.label(1.5) == "1.5×" && SpeakSpeed.label(0.75) == "0.75×" && SpeakSpeed.label(3) == "3×",
          "скорость: 1×, 1.5×, 0.75×, 3×")
    check(SpeakVoiceNames.language("ru") == "Русский" && SpeakVoiceNames.language("en") == "Английский",
          "языки по-русски с большой буквы (\(SpeakVoiceNames.language("ru")), \(SpeakVoiceNames.language("en")))")
    let english = fixtureVoices.filter { $0.languageKey == "en" }
    let daniel = SpeakVoiceNames.title(english.first { $0.id == "en.daniel" }!, among: english)
    check(daniel.contains("Daniel") && daniel.contains("Великобритания") && daniel.contains("улучшенный"),
          "голос: имя, страна при разных странах, качество (\(daniel))")
    let russian = fixtureVoices.filter { $0.languageKey == "ru" }
    let yuri = SpeakVoiceNames.title(russian.first { $0.id == "ru.yuri" }!, among: russian)
    check(yuri == "Yuri · премиум", "у единственной страны страна не пишется (\(yuri))")
    check(SpeakVoiceNames.title(russian[0], among: russian) == "Milena", "у обычного голоса пометки нет")
}

// MARK: - Модель центра: каждое нажатие — одно действие, которое утилита примет

@MainActor func remoteActions() async {
    var sent: [Data] = []
    var utility = fixtureState()
    var refuse: String?
    let link = RemoteModuleLink(
        state: { LinkWire.encoded(utility) },
        action: { data in
            sent.append(data)
            // Утилита: принимает только то, что примет её строгий разбор, и сама решает, что применить.
            if refuse == nil, let action = LinkWire.decodeAction(SpeakAction.self, from: data, limit: 512) {
                switch action {
                case .setSpeed(let value): utility.speed = SpeakSpeed.clamped(value) ?? utility.speed
                case .stepSpeed(let direction): utility.speed = SpeakSpeed.stepped(utility.speed, direction)
                case .setVoiceAuto: utility.pinnedVoices = [:]
                case .pinVoice(let language, let id): utility.pinnedVoices[language] = id
                case .unpin(let language): utility.pinnedVoices[language] = nil
                default: break
                }
            }
            return LinkWire.encoded(LinkReply(state: utility, error: refuse))
        }, setWatch: { _ in }, onPing: { _ in })
    let remote = RemoteSpeakModel(id: "test.speak-screen", link: link, canRead: { true })
    await remote.read()
    check(remote.state == utility, "модель центра показывает состояние утилиты")

    let presses: [(String, () -> Void, SpeakAction)] = [
        ("скорость", { remote.setSpeed(2) }, .setSpeed(2)),
        ("быстрее", { remote.stepSpeed(1) }, .stepSpeed(1)),
        ("медленнее", { remote.stepSpeed(-1) }, .stepSpeed(-1)),
        ("всё на «Авто»", { remote.setVoiceAuto() }, .setVoiceAuto),
        ("закрепить голос", { remote.pinVoice(language: "ru", id: "ru.katya") }, .pinVoice(language: "ru", id: "ru.katya")),
        ("«Авто» для языка", { remote.unpin(language: "ru") }, .unpin(language: "ru")),
        ("пауза", { remote.pause() }, .pause),
        ("продолжить", { remote.resume() }, .resume),
        ("стоп", { remote.stopSpeaking() }, .stop),
        ("сочетание", { remote.setHotKey(keyCode: 1, modifiers: 256) }, .setHotKey(keyCode: 1, modifiers: 256)),
        ("вернуть сочетание", { remote.resetHotKey() }, .resetHotKey),
        ("запись сочетания: снять", { remote.suspendHotKey() }, .suspendHotKey),
        ("запись сочетания: вернуть", { remote.resumeHotKey() }, .resumeHotKey),
        ("перечитать права", { remote.refreshPermissions() }, .refreshPermissions),
        ("дать доступ", { remote.requestAccessibility() }, .requestAccessibility),
    ]
    var covered: Set<String> = []
    for (name, press, expected) in presses {
        sent = []
        press()
        await pause(0.05)
        let decoded = sent.count == 1 ? LinkWire.decodeAction(SpeakAction.self, from: sent[0], limit: 512) : nil
        check(decoded == expected, "«\(name)» уходит одним действием \(actionName(expected)), утилита его принимает")
        covered.insert(actionName(expected))
    }
    check(covered == allActionNames, "нажатиями покрыты все действия связи (\(covered.count) из \(allActionNames.count))")

    // Сразу видно, не дожидаясь утилиты: скорость и голоса.
    utility = fixtureState()
    await remote.read()
    remote.setSpeed(5)
    check(remote.speed == 3, "скорость за краем видна сразу краем: 3× (\(remote.speed))")
    await pause(0.05)
    check(remote.speed == 3, "утилита подтвердила 3×")
    remote.stepSpeed(-1)
    check(remote.speed == 2.75, "«−» виден сразу: 2.75× (\(remote.speed))")
    remote.pinVoice(language: "ru", id: "ru.katya")
    check(remote.pinnedVoices == ["ru": "ru.katya"], "закреплённый голос виден сразу")
    remote.setHotKey(keyCode: 1, modifiers: 256)
    check(remote.hotKeyLabel == VoiceHotKey.label(keyCode: 1, modifiers: 256), "новое сочетание видно сразу (\(remote.hotKeyLabel))")
    await pause(0.05)
    refuse = "Такой скорости нет"
    remote.setSpeed(1.25)
    check(remote.speed == 1.25, "до ответа — новое значение")
    await pause(0.05)
    check(remote.speed == 2.75 && remote.actionError == "Такой скорости нет", "отказ утилиты: значение откатилось, текст отказа на экране")
    refuse = nil

    // Запись сочетания на экране центра: текущее снимается и возвращается действиями связи.
    let recorder = HotKeyRecorder()
    sent = []
    recorder.start(remote)
    check(recorder.isRecording, "запись сочетания началась")
    recorder.stop()
    await pause(0.05)
    let recorded = sent.compactMap { LinkWire.decodeAction(SpeakAction.self, from: $0, limit: 512) }
    check(recorded == [.suspendHotKey, .resumeHotKey], "запись: suspendHotKey, затем resumeHotKey (\(recorded.map(actionName)))")
}

// MARK: - Экран

@MainActor func screens(_ dir: String) async {
    // Один экран на обе модели: модель центра на том же состоянии рисует то же самое.
    let idle = fixtureState()
    let fixture = FixtureSpeakModel(idle)
    let link = RemoteModuleLink(state: { LinkWire.encoded(idle) }, action: { _ in LinkWire.encoded(LinkReply(state: idle)) },
                                setWatch: { _ in }, onPing: { _ in })
    let remote = RemoteSpeakModel(id: "test.speak-screen-same", link: link, canRead: { true })
    await remote.read()
    let local = await Shots.render(SpeakView(model: fixture), width: 738, height: 1500)
    let center = await Shots.render(SpeakView(model: remote), width: 738, height: 1500)
    check(differingPixels(local, center) == 0, "экран на модели центра совпал с экраном на фикстуре до пикселя")
    Shots.save(local, dir, "speak-screen-idle")
    check(fixture.sent == [.refreshPermissions], "открытие экрана перечитывает права действием связи (\(fixture.sent.map(actionName)))")

    var busy = fixtureState(phase: .speaking)
    busy.pinnedVoices = ["ru": "ru.katya", "de": "de.gone"]
    busy.message = SpeakMessage.needAccess
    busy.hotKeyError = SpeakMessage.hotKeyBusy
    busy.accessibilityTrusted = false
    let speaking = await Shots.render(SpeakView(model: FixtureSpeakModel(busy)), width: 738, height: 1600)
    Shots.save(speaking, dir, "speak-screen-speaking")
    check(differingPixels(local, speaking) > 0, "снимки разные, не пустые")

    // Узкое окно утилиты (SpeakModule.windowSize 620): ничего не должно уехать за край.
    var paused = busy
    paused.phase = .paused
    Shots.save(await Shots.render(SpeakView(model: FixtureSpeakModel(paused)), width: 620, height: 1700), dir, "speak-screen-narrow-paused")
}

@main
enum SpeakScreenCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            print("ПРОВАЛ: нужна папка снимков")
            exit(1)
        }
        Task { @MainActor in
            labels()
            await remoteActions()
            await screens(arguments[1])
            print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }
}
