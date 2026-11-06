import AppKit
import SwiftUI

// «Голос» в лаунчере, работа в утилите: чужая подпись, отказы на мусор, смерть утилиты. Запуск: Tests/run-voice-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Горячую клавишу и микрофон стенд не трогает (KIT_TEST_DEFAULTS).

let moduleID = "test.voice"
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"resetHotKey":{},"x":1}"#),
    ("чужой ключ внутри действия без значений", #"{"beginTest":{"x":1}}"#),
    ("два действия", #"{"beginTest":{},"endTest":{}}"#),
    ("режима нет", #"{"setMode":{"_0":"fly"}}"#),
    ("setHotKey без модификаторов", #"{"setHotKey":{"keyCode":49}}"#),
    ("массив", #"[{"endTest":{}}]"#),
]

@MainActor func garbage() async {
    await checkBadActions(VoiceState.self, id: moduleID, extra: notOneAction.map { ($0.0, Data($0.1.utf8)) } + [
        ("клавиша без модификаторов", LinkWire.encoded(VoiceAction.setHotKey(keyCode: 49, modifiers: 0))),
        ("идентификатор не программы", LinkWire.encoded(VoiceAction.addExcluded("не id/../"))),
        ("микрофона нет", LinkWire.encoded(VoiceAction.setMic("нет-такого"))),
        ("удалить неустановленную модель", LinkWire.encoded(VoiceAction.deleteModel(.gigaam))),
    ])
}

@MainActor func actions() async {
    let model = RemoteVoiceModel.shared
    await model.read()
    check(model.responding, "утилита отвечает")
    await model.perform(.setMode(.hold))
    check(model.actionError == nil && model.mode == .hold, "режим «пока держу» дошёл до утилиты")
    await model.perform(.setMode(.toggle))
    await model.perform(.setHotKey(keyCode: 49, modifiers: 0))
    check(model.actionError != nil && model.hotKeyLabel == VoiceController.storedState().hotKeyLabel, "клавиша без модификаторов отвергнута")
    // В стенде моделей нет: кнопка «Проверить» отказывает текстом до всякого микрофона.
    await model.perform(.toggleTestRecording)
    check(model.actionError != nil && !model.recording && model.test == nil, "«Проверить» без модели: отказ с текстом, записи нет")
    await model.perform(.beginTest)
    check(model.test != nil, "режим проверки включился действием")
    await model.perform(.endTest)
    check(model.test == nil, "и выключился")
}

@MainActor func death(utility: Int32) async {
    let model = RemoteVoiceModel.shared
    let registry = SatelliteRegistry.shared
    // Модель следит за реестром: он должен сперва услышать живую утилиту, иначе смерть не будет переменой статуса.
    await registry.update()
    _ = await Stand.open(.dusk)
    killUtilityForGood(utility)
    // Таймеров в модели нет: смерть замечает реестр, а модель за ним перечитывает.
    await registry.update()
    check(await until(8) { !model.responding }, "утилита убита: модель показала запасной экран")
    check(model.screen(of: .voice, registry) == .notResponding, "утилита убита: вкладка показывает «не отвечает»")
    let ticks = TickWatch()
    await model.read()
    check(ticks.maxGap <= 0.3, String(format: "чтение мёртвой утилиты: простой главного потока %.3f с", ticks.maxGap))
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.voice, foreignAction: LinkWire.encoded(VoiceAction.beginTest)) { utility in
                await garbage()
                await actions()
                await death(utility: utility)
            }
        }
    }
}
