import AppKit
import SwiftUI

// Вкладка «Микшер» в лаунчере, работа в утилите. Запуск: Tests/run-mixer-remote-check.sh
// Звук не перехватывается: утилита стенда собрана со швом, тапы в ней не создаются. Захват проверяется руками.
// MIXER_PAIR=old-utility: на том конце настоящий Микшер 1.3.0, собранный скриптом из тега.

let moduleID = "test.mixer"
/// Не одно известное действие: разбор отказывает, сколько бы известного в этом ни было.
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"commitVolumes":{},"x":1}"#),
    ("чужой ключ внутри", #"{"reset":{"id":"a","x":1}}"#),
    ("два действия", #"{"commitVolumes":{},"reset":{"id":"a"}}"#),
    ("без значения", #"{"setVolume":{"id":"a"}}"#),
    ("громкость строкой", #"{"setVolume":{"id":"a","value":"1"}}"#),
    ("pid вместо id", #"{"reset":{"id":4242}}"#),
    ("старое действие экрана", #"{"setScreenVisible":{"visible":true}}"#),
    ("commitVolumes не объект", #"{"commitVolumes":1}"#),
    ("эквалайзер без выключателя", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"id":"a","preset":"flat"}}"#),
    ("эквалайзер: чужой ключ", #"{"setEqualizer":{"bands":[0,0,0,0,0,0,0,0,0,0],"enabled":true,"id":"a","preset":"flat","x":1}}"#),
    ("эквалайзер: строки", #"{"setEqualizer":{"bands":["0"],"enabled":true,"id":"a","preset":"flat"}}"#),
]
/// Разбираются, но значения чужие: отказ утилиты. Строка настоящая: иначе отказ был бы за неизвестный id.
func refusedEqualizer(_ id: String) -> [(String, String)] {
    let wire = { (bands: String, preset: String) in "{\"setEqualizer\":{\"bands\":[\(bands)],\"enabled\":true,\"id\":\"\(id)\",\"preset\":\"\(preset)\"}}" }
    let ones = { (n: Int) in Array(repeating: "1", count: n).joined(separator: ",") }
    return [("9 полос", wire(ones(9), "custom")), ("11 полос", wire(ones(11), "custom")), ("13 полос", wire(ones(13), "custom")),
            ("значение 13 дБ", wire("13," + ones(9), "custom")), ("значение −99", wire("-99," + ones(9), "custom")),
            ("чужой режим", wire(ones(10), "чужой")), ("пустой режим", wire(ones(10), ""))]
}

@MainActor func allRows(_ state: MixerState) -> [MixerAppState] { state.apps + state.idleApps + state.presetApps + state.otherApps }

/// Локальный контроллер в том же состоянии, что утилита: списки из её ответа, иконки по id.
@MainActor func pinLocal(to state: MixerState) {
    func rows(_ list: [MixerAppState]) -> [MixerApp] { list.map(MixerApp.init) }
    MixerController.shared.testPin(apps: rows(state.apps), idle: rows(state.idleApps), preset: rows(state.presetApps),
                                   other: rows(state.otherApps), permissionProblem: state.permissionProblem, lastError: state.lastError)
}

func wirePure() {
    let decode = { (text: String) in try? JSONDecoder().decode(MixerAction.self, from: Data(text.utf8)) }
    check(decode(#"{"setVolume":{"id":"com.a","value":0.5}}"#) == .setVolume(id: "com.a", value: 0.5), "настоящее действие разбирается")
    check(decode(#"{"commitVolumes":{}}"#) == .commitVolumes, "commitVolumes разбирается")
    for (name, text) in notOneAction {
        check(decode(text) == nil, "\(name) не разбирается: \(text)")
    }
}

@MainActor func garbage() async {
    await RemoteMixerModel.shared.read()
    let id = allRows(RemoteMixerModel.shared.state).first?.id ?? "нет"
    await checkBadActions(MixerState.self, id: moduleID, extra: (notOneAction + refusedEqualizer(id)).map { ($0.0, Data($0.1.utf8)) })
}

@MainActor func actions() async {
    let model = RemoteMixerModel.shared
    await model.read()
    check(model.responding, "утилита отвечает")
    let state = model.state
    // Приложения, которые играют, не трогаем: тап утилита стенда всё равно не создаст, но строка могла бы исчезнуть.
    guard let target = (state.idleApps + state.otherApps).first else { return check(false, "нет ни одного молчащего приложения для проверки") }
    await model.perform(.setVolume(id: "com.evil.app", value: 0.5))
    check(model.actionError != nil, "чужой id: отказ с текстом («\(model.actionError ?? "нет")»)")
    check(!allRows(model.state).contains { $0.id == "com.evil.app" }, "чужой id в списках не появился")

    await model.perform(.setVolume(id: target.id, value: 0.3))
    await model.perform(.commitVolumes)
    check(model.actionError == nil, "громкость принята без текста ошибки")
    await model.read()
    check(allRows(model.state).first { $0.id == target.id }?.volume == 0.3, "громкость 0,3 видна в состоянии утилиты")
    await model.perform(.setMuted(id: target.id, muted: true))
    await model.read()
    check(model.isMuted(target.id), "без звука виден в состоянии утилиты")
    await model.perform(.reset(id: target.id))
    await model.read()
    let after = allRows(model.state).first { $0.id == target.id }
    check(after?.volume == 1 && after?.muted == false, "reset вернул 100 % и звук")

    // Частые шаги ползунка: в пути одно на ключ, последнее значение доходит.
    for step in 1...20 { model.setVolume(Double(step) / 40, for: target.id) }
    // `setVolume` ставит действие в очередь главного потока: «сразу» значит после одного оборота, ещё до ответа утилиты.
    await Task.yield()
    check(allRows(model.state).first { $0.id == target.id }?.volume == 0.5, "ползунок: сразу виден последний шаг")
    check(await until(3) { allRows(model.state).first { $0.id == target.id }?.volume == 0.5 && model.actionError == nil }, "ползунок: ответ утилиты совпал с последним шагом")
    await model.perform(.reset(id: target.id))
    await model.perform(.commitVolumes)
}

/// Эквалайзер по настоящей связи: значения, выключатель, режим, чужой id, шаги регулятора, запись на диск утилиты.
@MainActor func equalizer() async {
    let model = RemoteMixerModel.shared
    await model.read()
    let rows = allRows(model.state)
    check(!rows.isEmpty && rows.allSatisfy { $0.eq == .off }, "все строки нового Микшера со значениями эквалайзера")
    guard let target = (model.state.idleApps + model.state.otherApps).first else { return check(false, "нет строки для эквалайзера") }
    let row = { allRows(model.state).first { $0.id == target.id } }
    await model.perform(.setEqualizer(id: "com.evil.app", enabled: true, preset: "voice", bands: MixerEq.flat))
    check(model.actionError != nil && !allRows(model.state).contains { $0.id == "com.evil.app" }, "эквалайзер, чужой id: отказ («\(model.actionError ?? "нет")»)")
    let voice = MixerEqSetting(enabled: true, preset: "voice", bands: MixerEq.presets[3].bands!)
    await model.perform(.setEqualizer(id: target.id, enabled: true, preset: "voice", bands: voice.bands))
    await model.perform(.commitVolumes)
    check(model.actionError == nil, "эквалайзер принят без текста ошибки")
    await model.read()
    check(row()?.eq == voice, "значения и режим видны в состоянии утилиты")
    check(await until(3) { Kit.defaults.synchronize(); return MixerEqSettings.read(from: Kit.defaults)[target.id] == voice }, "утилита записала их в свои настройки")
    await model.perform(.setEqualizer(id: target.id, enabled: false, preset: "voice", bands: voice.bands))
    await model.read()
    check(row()?.eq?.enabled == false && row()?.eq?.bands == voice.bands, "выключатель не теряет значения")
    model.setEqualizer(voice.editing(band: 0, to: 3), for: target.id)
    check(row()?.eq?.preset == MixerEq.customID, "правка видна сразу: режим «Свой»")
    // Шаги регулятора: в пути одно на ключ, доходит последнее.
    for step in 0...12 { model.setEqualizer(voice.editing(band: 0, to: Double(step)), for: target.id) }
    await Task.yield()
    check(row()?.eq?.bands[0] == 12, "регулятор: сразу виден последний шаг")
    check(await until(3) { row()?.eq?.bands[0] == 12 && model.actionError == nil }, "регулятор: ответ утилиты совпал с последним шагом")
    await model.perform(.reset(id: target.id))
    await model.read()
    check(row()?.eq == .off, "reset снимает эквалайзер")
    await model.perform(.commitVolumes)
}

/// Настоящий Микшер 1.3.0 с этим лаунчером: всё, что он умел, работает, экран тот же, эквалайзера нет.
@MainActor func oldUtility() async {
    let model = RemoteMixerModel.shared
    await model.read()
    check(model.responding, "Микшер 1.3.0 отвечает новому лаунчеру")
    let rows = allRows(model.state)
    check(!rows.isEmpty && rows.allSatisfy { $0.eq == nil }, "в его строках эквалайзера нет: \(rows.count) строк, кнопок не будет")
    await actions()
    guard let target = (model.state.idleApps + model.state.otherApps).first else { return check(false, "нет строки для проверки") }
    // Экран такого не пошлёт, но если придёт, старый Микшер откажет и останется жив.
    let before = model.state
    await model.perform(.setEqualizer(id: target.id, enabled: true, preset: "voice", bands: MixerEq.flat))
    check(model.actionError == "Непонятная команда" && model.state == before, "действие эквалайзера: отказ («\(model.actionError ?? "нет")»), состояние то же")
    await model.read()
    check(model.responding, "после отказа Микшер 1.3.0 отвечает")
    await pixels(equalizerVariant: false)
    await model.perform(.commitVolumes)
}

/// Вид на контроллере утилиты в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.mixer), animated: false) { _, active in
        AnyView(ModuleScreen(module: .mixer) { MixerView(model: MixerController.shared) }
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.mixer))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .mixer, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

@MainActor func pixels(equalizerVariant: Bool = true) async {
    let model = RemoteMixerModel.shared
    let registry = SatelliteRegistry.shared
    let local = MixerController.shared
    // Как `MixerModule.init` в утилите: два текста экрана зависят от этого.
    local.runsInUtility = true
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for variant in equalizerVariant ? ["live", "volume", "equalizer"] : ["live", "volume"] {
            let target = (model.state.idleApps + model.state.otherApps).first
            await model.perform(.setVolume(id: target?.id ?? "", value: variant == "volume" ? 0.4 : 1))
            if equalizerVariant {
                // Подсвеченная кнопка в строке: вкладка и контроллер утилиты должны совпасть и здесь.
                let lit = variant == "equalizer"
                await model.perform(.setEqualizer(id: target?.id ?? "", enabled: lit, preset: lit ? "voice" : "flat", bands: lit ? MixerEq.presets[3].bands! : MixerEq.flat))
            }
            await model.perform(.commitVolumes)
            await model.read()
            let known = model.state
            pinLocal(to: known)
            let localShot = await openLocal(theme)
            Stand.save(localShot, "\(themeName)-\(variant)-local")

            // Контроллер пустой: экран, читающий его вместо утилиты, проверку не пройдёт.
            local.testPin()
            await registry.update()
            let remoteShot = await Stand.open(theme)
            Stand.save(remoteShot, "\(themeName)-\(variant)-remote")
            check(model.state == known, "\(themeName) \(variant): за время снимка состояние утилиты не менялось")
            let diff = differingPixels(localShot, remoteShot)
            check(diff == 0, "\(themeName) \(variant): снимки совпали, разных пикселей \(diff) из \(localShot.pixelsWide * localShot.pixelsHigh)")
            shots.append(remoteShot)
        }
        check(differingPixels(shots[0], shots[1]) > 0, "\(themeName): громкость утилиты меняет снимок, он не пустой")
        if equalizerVariant { check(differingPixels(shots[0], shots[2]) > 0, "\(themeName): эквалайзер утилиты подсвечивает кнопку на снимке") }
    }
    // Те же списки с другими двумя текстами: сверка видит и это.
    local.runsInUtility = false
    pinLocal(to: model.state)
    let otherTexts = await openLocal(.dusk)
    local.runsInUtility = true
    check(differingPixels(otherTexts, await Stand.open(.dusk)) > 0, "экран с текстами не утилиты и вкладка различаются")
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    local.testPin()
}

/// Пассивная значит остановленная: центр запущен и модуль ещё его, утилита снимает всё и ничего не принимает.
@MainActor func passive() async {
    let defaults = Kit.defaults
    let client = LinkClient(id: moduleID)
    let model = RemoteMixerModel.shared
    await model.read()
    guard let target = (model.state.idleApps + model.state.otherApps).first else { return check(false, "пассивность: нет приложения для проверки") }
    defaults.set(true, forKey: "Test.HubRunning")
    defaults.set("0.6.0", forKey: "Test.HubVersion")
    defaults.set(true, forKey: SatelliteRole.hubModuleOnKey(moduleID))
    defaults.set(false, forKey: SatelliteRole.handedOverKey(moduleID))
    defaults.synchronize()
    try? await client.setEnabled(true)
    await model.read()
    check(allRows(model.state).isEmpty, "пассивная: списков нет, опрос и тапы остановлены")
    await model.perform(.setVolume(id: target.id, value: 0.5))
    check(model.actionError != nil && allRows(model.state).isEmpty, "пассивная: действие отвергнуто («\(model.actionError ?? "нет")»)")
    let line = try? await client.status().line
    check(line == "Ждём передачу от центра", "пассивная: статус говорит почему («\(line ?? "нет")»)")

    defaults.set(true, forKey: SatelliteRole.handedOverKey(moduleID))
    defaults.synchronize()
    try? await client.setEnabled(true)
    var back = false
    for _ in 0..<50 where !back {
        await model.read()
        back = !allRows(model.state).isEmpty
        if !back { await pause(0.1) }
    }
    check(back, "передача: утилита снова работает, списки вернулись")
    defaults.set(false, forKey: "Test.HubRunning")
    defaults.synchronize()
    try? await client.setEnabled(true)
}

/// Утилиту убили: вкладка узнаёт, что она не отвечает.
@MainActor func death(utility: Int32) async {
    let model = RemoteMixerModel.shared
    let registry = SatelliteRegistry.shared
    await model.read()
    check(model.responding && model.screen(of: .mixer, registry) == .module, "до этого экран модуля")
    killUtilityForGood(utility)
    await registry.update()
    check(await until(6) { !model.responding }, "утилиту убили: модель это увидела")
    check(model.screen(of: .mixer, registry) == .notResponding, "и вкладка показывает запасной экран")
    Stand.save(await Stand.open(.dusk), "dusk-not-responding")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.mixer, foreignAction: LinkWire.encoded(MixerAction.commitVolumes)) { utility in
                if ProcessInfo.processInfo.environment["MIXER_PAIR"] == "old-utility" {
                    await oldUtility()
                    return
                }
                wirePure()
                await garbage()
                await actions()
                await equalizer()
                await pixels()
                await passive()
                await death(utility: utility)
            }
        }
    }
}
