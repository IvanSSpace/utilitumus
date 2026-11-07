import AppKit
import Carbon.HIToolbox
import SwiftUI

// «Голос» в лаунчере, работа в утилите: чужая подпись, отказы на мусор, сверка вкладки с экраном утилиты, смерть утилиты. Запуск: Tests/run-voice-remote-check.sh
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

/// Вид на контроллере утилиты в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme, @ViewBuilder _ content: @escaping () -> some View) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.voice), animated: false) { _, active in
        AnyView(content()
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.voice))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .voice, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

struct VoiceScene {
    let name: String
    let mode: VoiceMode
    let excluded: [String]
    let keyCode: UInt32
    let modifiers: UInt32
}

let voiceScenes = [
    VoiceScene(name: "default", mode: .toggle, excluded: [], keyCode: VoiceHotKey.defaultKeyCode, modifiers: VoiceHotKey.defaultModifiers),
    VoiceScene(name: "hold", mode: .hold, excluded: [], keyCode: VoiceHotKey.defaultKeyCode, modifiers: VoiceHotKey.defaultModifiers),
    VoiceScene(name: "excluded-hotkey", mode: .toggle, excluded: ["com.example.voice-check"], keyCode: 49, modifiers: UInt32(cmdKey | shiftKey)),
]

/// Настоящая утилита приходит в состояние через модель центра. Горячую клавишу стенд и утилита не занимают: у обеих модуль не запущен.
@MainActor func drive(_ scene: VoiceScene) async {
    let model = RemoteVoiceModel.shared
    await model.read()
    await model.perform(.setMode(scene.mode))
    await model.perform(.setHotKey(keyCode: scene.keyCode, modifiers: scene.modifiers))
    for id in model.excludedApps where !scene.excluded.contains(id) { await model.perform(.removeExcluded(id)) }
    for id in scene.excluded where !model.excludedApps.contains(id) { await model.perform(.addExcluded(id)) }
    await model.read()
}

/// Контроллер утилиты, собранный в стенд, в том же состоянии. Настоящую клавишу он не занимает: `start` не вызывался.
@MainActor func pinLocal(to scene: VoiceScene, state: VoiceState) {
    let controller = VoiceController.shared
    controller.mode = state.mode
    controller.micUID = state.micUID
    controller.setHotKey(keyCode: scene.keyCode, modifiers: scene.modifiers)
    for id in controller.excludedApps where !state.excludedApps.contains(id) { controller.removeExcluded(id) }
    for id in state.excludedApps where !controller.excludedApps.contains(id) { controller.addExcluded(id) }
    VoiceModelStore.shared.selected = state.selected
}

@MainActor func pixels() async {
    let model = RemoteVoiceModel.shared
    let registry = SatelliteRegistry.shared
    let flow = SetupFlow.shared
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for scene in voiceScenes {
            let name = "\(themeName) \(scene.name)"
            await drive(scene)
            check(model.responding && model.actionError == nil && model.mode == scene.mode && model.excludedApps == scene.excluded, "\(name): утилита в нужном состоянии")
            pinLocal(to: scene, state: model.state)
            check(VoiceController.shared.hotKeyLabel == model.hotKeyLabel, "\(name): клавиша у контроллера та же, «\(model.hotKeyLabel)»")
            await registry.update()
            check(registry.isEnabled(.voice), "\(name): реестр видит утилиту включённой")
            AccessState.shared.refresh()

            // Настройка не закончена: сначала шаги, они приходят от утилиты.
            if AccessState.shared.blocked.contains(.voice) {
                let local = await openLocal(theme) { ModuleScreen(module: .voice) { VoiceView(voice: VoiceLocalModel.shared) } }
                Stand.save(local, "\(themeName)-\(scene.name)-steps-local")
                let remote = await Stand.open(theme)
                Stand.save(remote, "\(themeName)-\(scene.name)-steps-remote")
                let diff = differingPixels(local, remote)
                check(diff == 0, "\(name), шаги настройки: снимки совпали, разных пикселей \(diff)")
            }

            flow.postpone(.voice)
            let local = await openLocal(theme) { ModuleScreen(module: .voice) { VoiceView(voice: VoiceLocalModel.shared) } }
            Stand.save(local, "\(themeName)-\(scene.name)-local")
            let remote = await Stand.open(theme)
            Stand.save(remote, "\(themeName)-\(scene.name)-remote")
            let diff = differingPixels(local, remote)
            check(diff == 0, "\(name): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            shots.append(remote)
            // `show` снимает отложенность, `finish` закрывает принудительный показ: как было до сценария.
            flow.show(.voice)
            flow.finish(.voice)
        }
        check(zip(shots, shots.dropFirst()).allSatisfy { differingPixels($0, $1) > 0 }, "\(themeName): состояния выглядят по-разному, снимки не пустые")
        await drive(voiceScenes[0])
    }
    // Выключенная утилита: тот самый экран «модуль выключен».
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    let other = LinkClient(id: moduleID)
    let local = await openLocal(.dusk) { ModuleOffView(module: .voice) {} more: {} }
    Stand.save(local, "dusk-off-local")
    try? await other.setEnabled(false)
    await registry.update()
    let remote = await Stand.open(.dusk)
    Stand.save(remote, "dusk-off-remote")
    let diff = differingPixels(local, remote)
    check(diff == 0, "выключенный модуль: снимки совпали, разных пикселей \(diff)")
    try? await other.setEnabled(true)
    await registry.update()
    await model.read()
    pinLocal(to: voiceScenes[0], state: model.state)
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
                await pixels()
                await death(utility: utility)
            }
        }
    }
}
