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
        .beginTest, .endTest,
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
    check(!json.contains("phase") && !json.contains("level"), "в состоянии нет фазы записи и уровня звука")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated { run() }
        print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
