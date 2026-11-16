import AppKit

// Подмены для проверок «Озвучки»: синтезатор без звука, чтение выделения без AX, сочетание без Carbon.
// Общие для Tests/SpeakCoreCheck.swift и Tests/SpeakPrivacyCheck.swift.

/// Запись другого процесса, как у центра.
func foreignDefaults(_ arguments: String...) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

@MainActor
final class FakeSynth: SpeechSynthesizing {
    var onStart: ((Int) -> Void)?
    var onFinish: ((Int) -> Void)?
    var onRange: ((Int, NSRange) -> Void)?
    struct Spoken { let text: String; let voiceID: String?; let rate: Float; let id: Int }
    var spoken: [Spoken] = []
    var calls: [String] = []
    var voiceList: [SpeakVoiceRow] = []
    /// Как у настоящего: остановка отвечает «закончилось». Сразу или позже (`flush`).
    var finishOnStopNow = true
    var pendingFinish: [Int] = []
    private var lastID = 0

    func speak(_ text: String, voiceID: String?, rate: Float) -> Int {
        lastID += 1
        spoken.append(Spoken(text: text, voiceID: voiceID, rate: rate, id: lastID))
        calls.append("speak")
        return lastID
    }
    func pause() { calls.append("pause") }
    func resume() { calls.append("resume") }
    func stop() {
        calls.append("stop")
        guard let last = spoken.last?.id else { return }
        if finishOnStopNow { onFinish?(last) } else { pendingFinish.append(last) }
    }
    func flush() {
        let ids = pendingFinish
        pendingFinish = []
        for id in ids { onFinish?(id) }
    }
    func voices() -> [SpeakVoiceRow] { voiceList }
    var last: Spoken? { spoken.last }
}

@MainActor
final class FakeReader: SelectionReading {
    var result: SelectionResult = .none
    var reads = 0
    func read() -> SelectionResult {
        reads += 1
        return result
    }
}

@MainActor
final class FakeHotKey: SpeakHotKeyBinding {
    var onPress: (() -> Void)?
    var registered: (keyCode: UInt32, modifiers: UInt32)?
    var registerCalls = 0
    var busy = false
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        registerCalls += 1
        guard !busy else { registered = nil; return false }
        registered = (keyCode, modifiers)
        return true
    }
    func unregister() { registered = nil }
    func press() { onPress?() }
}

let voices = [
    SpeakVoiceRow(id: "ru.milena", name: "Milena", language: "ru-RU", quality: .regular),
    SpeakVoiceRow(id: "ru.katya", name: "Katya", language: "ru-RU", quality: .enhanced),
    SpeakVoiceRow(id: "ru.yuri.premium", name: "Yuri", language: "ru-RU", quality: .premium),
    SpeakVoiceRow(id: "en.samantha", name: "Samantha", language: "en-US", quality: .regular),
    SpeakVoiceRow(id: "en.daniel", name: "Daniel", language: "en-GB", quality: .enhanced),
    SpeakVoiceRow(id: "en.alex", name: "Alex", language: "en-US", quality: .enhanced),
]
let russian = "Привет! Сегодня отличная погода, пойдём гулять в парк у реки."
let english = "The weather is lovely today, let us go for a long walk by the river."

/// Контроллер на подменах. Каждый новый — как утилита после перезапуска: настройки только из Kit.defaults.
@MainActor
struct Stand {
    let synth = FakeSynth()
    let reader = FakeReader()
    let hotKey = FakeHotKey()
    let controller: SpeakController

    init(preferred: [String] = ["ru-RU", "en-US"]) {
        synth.voiceList = voices
        controller = SpeakController(synthesizer: synth, reader: reader, hotKey: hotKey,
                                     trusted: { true }, preferredLanguages: { preferred })
    }
}
