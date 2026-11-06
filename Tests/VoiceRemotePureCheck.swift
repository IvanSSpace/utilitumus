import Foundation

// «Голос» как утилита, без процессов, микрофона, клавиши и настоящих моделей: строгий разбор действий,
// хвосты загрузки (создание стора их не трогает), ответ на действия по связи. Папка дома подменена скриптом.

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func run() {
    let all: [VoiceAction] = [
        .setMode(.hold), .setMic(nil), .setMic("uid-1"), .addExcluded("com.apple.Safari"), .removeExcluded("a.b"),
        .setHotKey(keyCode: 49, modifiers: 4096), .resetHotKey, .suspendHotKey, .resumeHotKey, .refreshPermissions,
        .requestAccessibility, .download(.gigaam), .cancelDownload(.parakeet), .deleteModel(.gigaam), .selectModel(.parakeet),
        .beginTest, .endTest, .toggleTestRecording,
    ]
    for action in all {
        check(LinkWire.decodeAction(VoiceAction.self, from: LinkWire.encoded(action), limit: 512) == action, "туда и обратно: \(action)")
    }
    let bad = [
        "повтор действия": #"{"resetHotKey":{},"endTest":{}}"#,
        "чужое поле у действия без значений": #"{"resetHotKey":{"x":1}}"#,
        "чужое поле у значения": #"{"setMode":{"_0":"toggle","y":1}}"#,
        "нет режима": #"{"setMode":{"_0":"fly"}}"#,
        "setHotKey без поля": #"{"setHotKey":{"keyCode":1}}"#,
        "setHotKey с лишним": #"{"setHotKey":{"keyCode":1,"modifiers":2,"z":3}}"#,
        "setMic с числом": #"{"setMic":{"_0":5}}"#,
        "чужое поле у кнопки проверки": #"{"toggleTestRecording":{"x":1}}"#,
        "кнопка проверки со значением": #"{"toggleTestRecording":{"_0":true}}"#,
        "неизвестное": #"{"record":{}}"#,
        "пустое": "{}",
    ]
    for (name, text) in bad {
        check(LinkWire.decodeAction(VoiceAction.self, from: Data(text.utf8), limit: 512) == nil, "отказ: \(name)")
    }
    check(LinkWire.decodeAction(VoiceAction.self, from: LinkWire.encoded(VoiceAction.addExcluded(String(repeating: "a", count: 600))), limit: 512) == nil,
          "отказ: длиннее лимита")

    // Хвосты чужой загрузки: создание стора их не стирает, стирает только запуск модуля, и один раз.
    let root = VoiceModelStore.modelsRoot
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appendingPathComponent(".download-x.tar.bz2"), staging = root.appendingPathComponent(".staging-y")
    FileManager.default.createFile(atPath: archive.path, contents: Data([1]))
    try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let store = VoiceModelStore.shared
    check(FileManager.default.fileExists(atPath: archive.path) && FileManager.default.fileExists(atPath: staging.path),
          "создание стора чужую загрузку не стёрло")
    store.cleanLeftoversOnce()
    check(!FileManager.default.fileExists(atPath: archive.path) && !FileManager.default.fileExists(atPath: staging.path),
          "запуск модуля хвосты убрал")
    FileManager.default.createFile(atPath: archive.path, contents: Data([1]))
    store.cleanLeftoversOnce()
    check(FileManager.default.fileExists(atPath: archive.path), "второй раз за процесс не трогает")
    try? FileManager.default.removeItem(at: archive)

    // Ответ на действия по связи: состояние не меняется от отказа и нет фазы записи.
    let controller = VoiceController.shared
    let before = controller.wireState
    let reply = try? JSONDecoder().decode(LinkReply<VoiceState>.self, from: controller.handle(Data(#"{"explode":{}}"#.utf8)))
    check(reply?.error != nil && reply?.state == before, "мусор: ошибка и прежнее состояние")
    let mode = try? JSONDecoder().decode(LinkReply<VoiceState>.self, from: controller.handle(LinkWire.encoded(VoiceAction.setMode(.hold))))
    check(mode?.error == nil && mode?.state.mode == .hold, "setMode проходит")
    _ = controller.handle(LinkWire.encoded(VoiceAction.setMode(.toggle)))
    let json = String(decoding: LinkWire.encoded(before), as: UTF8.self)
    check(json.contains("\"recording\":false") && !json.contains("phase") && !json.contains("level"),
          "в состоянии есть только флаг записи, фазы и уровня звука нет")
}

// MARK: - Кнопка «Проверить»: запись в поле проверки без настоящего микрофона

/// Подставная запись: микрофон не трогает, считает включения и выключения.
final class FakeCapture: VoiceCapturing, @unchecked Sendable {
    nonisolated(unsafe) var starts = 0
    nonisolated(unsafe) var finishes = 0
    nonisolated(unsafe) var running = false
    var count: Int { running ? 16_000 : 0 }
    var level: Float { 0 }
    func start(deviceUID: String?) throws { starts += 1; running = true }
    func finish() -> [Float] { finishes += 1; running = false; return Array(repeating: 0.1, count: 16_000) }
}

@MainActor func waitUntil(_ seconds: Double = 3, _ done: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    return done()
}

@MainActor func testButton() async {
    let c = VoiceController.shared
    let cap = FakeCapture()
    var asked = 0
    var delay = 0.0
    var said = "привет"
    c.seam.recorder = cap
    c.seam.grabsEsc = false
    c.seam.micStatus = { .authorized }
    c.seam.requestMic = { _ in asked += 1 }
    c.seam.readyModel = { .gigaam }
    c.seam.transcribe = { _, _ in
        try await Task.sleep(for: .seconds(delay))
        return said
    }
    func hudMessage() -> String? {
        if case let .message(text, _) = VoiceHUD.shared.model.kind { return text }
        return nil
    }
    func pasteboardText() -> String? { Kit.pasteboard.string(forType: .string) }
    let pasteBefore = pasteboardText()
    func idle() -> Bool { c.phase == .idle && !cap.running && c.wireState.test == nil && !c.wireState.recording }

    // Отказы дают текст и ничего не включают.
    c.seam.readyModel = { nil }
    var refusal = c.handle(.toggleTestRecording)
    check(refusal != nil && cap.starts == 0 && idle(), "нет модели: отказ с текстом, микрофон не включён")
    c.seam.readyModel = { .gigaam }
    c.seam.micStatus = { .denied }
    refusal = c.handle(.toggleTestRecording)
    check(refusal != nil && cap.starts == 0 && idle() && asked == 0, "микрофон запрещён: отказ с текстом, запись не началась")
    c.seam.micStatus = { .notDetermined }
    refusal = c.handle(.toggleTestRecording)
    check(refusal != nil && cap.starts == 0 && idle() && asked == 1, "разрешение не выдано: просим один раз, запись не началась")
    c.seam.micStatus = { .authorized }

    // Первое нажатие начинает запись, второе заканчивает, текст попадает в состояние.
    check(c.handle(.toggleTestRecording) == nil && cap.starts == 1 && cap.running, "первое нажатие: запись началась")
    check(c.phase == .recording && c.wireState.recording && c.wireState.test == VoiceTestState(phrase: nil, serial: 0), "идёт запись, режим проверки включён")
    check(c.handle(.beginTest) == nil && c.phase == .recording, "повторное включение режима запись не обрывает")
    try? await Task.sleep(for: .milliseconds(400))
    check(c.handle(.toggleTestRecording) == nil && !cap.running && cap.finishes == 1, "второе нажатие: запись закончена")
    check(await waitUntil { c.wireState.test?.phrase == "привет" } && c.phase == .idle, "распознанный текст пришёл в состояние")
    check(pasteboardText() == pasteBefore, "в буфер обмена ничего не попало")
    _ = c.handle(.endTest)

    // Уход с экрана посреди записи.
    cap.starts = 0; cap.finishes = 0
    check(c.handle(.toggleTestRecording) == nil && cap.running, "запись для ухода с экрана началась")
    _ = c.handle(.endTest)
    check(idle() && cap.finishes == 1, "уход с экрана: запись остановлена, микрофон выключен, режим снят")

    // Уход с экрана во время распознавания: текст не приходит и никуда не вставляется.
    delay = 0.5; said = "секрет-вставки"
    check(c.handle(.toggleTestRecording) == nil, "запись для ухода при распознавании началась")
    try? await Task.sleep(for: .milliseconds(400))
    _ = c.handle(.toggleTestRecording)
    check(c.phase == .transcribing, "идёт распознавание")
    check(c.handle(.toggleTestRecording) != nil, "нажатие во время распознавания: отказ с текстом")
    _ = c.handle(.endTest)
    try? await Task.sleep(for: .milliseconds(800))
    check(idle() && c.wireState.test == nil && pasteboardText() == pasteBefore, "уход при распознавании: текст отброшен, в буфере ничего нет")

    // Режим проверки кончился сам (срок), пока шла запись: текст пропадает, а не вставляется в чужую программу.
    delay = 0
    check(c.handle(.toggleTestRecording) == nil, "запись для истёкшего режима началась")
    c.beginTest(now: Date() - VoiceTestState.lifetime - 1)
    try? await Task.sleep(for: .milliseconds(400))
    _ = c.handle(.toggleTestRecording)
    check(await waitUntil { c.phase == .idle && hudMessage() != nil }, "режим истёк: запись доведена до конца")
    check(hudMessage()?.contains("не вставлен") == true && pasteboardText() == pasteBefore, "режим истёк: текст не вставлен, буфер не тронут")

    // Остановка модуля.
    c.endTest()
    check(c.handle(.toggleTestRecording) == nil && cap.running, "запись для отмены началась")
    c.stop()
    check(idle(), "остановка модуля обрывает запись проверки")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated { run() }
        Task { @MainActor in
            await testButton()
            print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
