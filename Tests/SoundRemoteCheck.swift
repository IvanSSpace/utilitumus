import AppKit
import SwiftUI

// Вкладка «Звук» в центре, работа в утилите. Запуск: Tests/run-sound-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Утилита собрана со швом: монитор читает настоящие устройства,
// но в этой сборке ничего не пишет, поэтому устройство по умолчанию у этого Mac не меняется.

let moduleID = "test.sound"
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"selectSystemOutput":{},"x":1}"#),
    ("два действия", #"{"selectSystemOutput":{},"setBluetoothLocked":{"_0":true}}"#),
    ("чужой ключ внутри", #"{"selectSystemOutput":{"x":1}}"#),
    ("действие без значения", #"{"selectInput":{}}"#),
    ("значение не того типа", #"{"setBluetoothLocked":{"_0":1}}"#),
    ("повтор ключа", #"{"setBluetoothLocked":{"_0":true},"setBluetoothLocked":{"_0":false}}"#),
    ("длинный uid", #"{"selectOutput":{"_0":""# + String(repeating: "a", count: 5000) + #""}}"#),
]

@MainActor func physical(_ devices: [DisplayDevice], _ marker: String) -> (all: [DisplayDevice], builtIn: DisplayDevice?) {
    let list = devices.filter { $0.transport.isPhysical }
    return (list, SoundPolicy.builtIn(in: list, marker: marker))
}

/// Настоящая утилита приходит в состояние через модель центра. Встроенное устройство берётся из её же списка.
@MainActor func drive(_ name: String) async {
    let model = RemoteSoundModel.shared
    await model.read()
    let speakers = physical(model.displayOutputs, SoundPolicy.speakerMarker).builtIn
    await model.perform(.setBluetoothLocked(true))
    if let speakers { await model.perform(.selectOutput(speakers.uid)) }
    switch name {
    case "unlocked": await model.perform(.setBluetoothLocked(false))
    case "system-output": await model.perform(.selectSystemOutput)
    default: break
    }
    await model.read()
}

/// Встроенные объекты в том же состоянии, что утилита.
@MainActor func pinLocal(to state: SoundState) {
    let monitor = MonitorState.shared
    monitor.currentInputName = state.currentInputName
    monitor.currentInputIsBluetooth = state.currentInputIsBluetooth
    monitor.currentOutputName = state.currentOutputName
    monitor.displayInputs = state.displayInputs
    monitor.displayOutputs = state.displayOutputs
    PrimaryInputStore.shared.select(state.primaryInputUID)
    PrimaryOutputStore.shared.select(state.outputChoice)
    LockState.shared.isLocked = state.isBluetoothLocked
}

@MainActor func garbage() async {
    await checkBadActions(SoundState.self, id: moduleID, extra: notOneAction.map { ($0.0, Data($0.1.utf8)) } + [
        ("неизвестный микрофон", LinkWire.encoded(SoundAction.selectInput("нет-такого"))),
        ("неизвестный выход", LinkWire.encoded(SoundAction.selectOutput("нет-такого"))),
    ])
}

@MainActor func actions() async {
    let model = RemoteSoundModel.shared
    await model.read()
    check(model.responding && !model.displayInputs.isEmpty && !model.displayOutputs.isEmpty, "утилита ответила, список устройств не пуст: \(model.displayInputs.count) входов, \(model.displayOutputs.count) выходов")
    await model.perform(.setBluetoothLocked(false))
    check(!model.isBluetoothLocked && model.actionError == nil, "блокировку сняли, ответ утилиты показан")
    await model.perform(.setBluetoothLocked(true))
    check(model.isBluetoothLocked, "и вернули")
    await model.perform(.selectInput("нет-такого"))
    check(model.actionError != nil && model.primaryInputUID == nil, "несуществующий микрофон: текст ошибки, выбор прежний")
    await model.perform(.selectSystemOutput)
    check(model.outputChoice == .system && model.actionError == nil, "«Как решит macOS» принят")
    let builtIn = physical(model.displayOutputs, SoundPolicy.speakerMarker).builtIn
    if let builtIn { await model.perform(.selectOutput(builtIn.uid)) }
    check(model.outputChoice == .builtIn, "динамики MacBook выбраны обратно")
    let other = LinkClient(id: moduleID)
    _ = try? await other.moduleAction(LinkWire.encoded(SoundAction.setBluetoothLocked(false)))
    check(await until(2) { !model.isBluetoothLocked }, "настройку поменяли снаружи: центр увидел по statusChanged")
    await model.perform(.setBluetoothLocked(true))
}

@MainActor func pixels() async {
    let model = RemoteSoundModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for name in ["default", "unlocked", "system-output"] {
            await drive(name)
            check(model.responding, "\(themeName) \(name): утилита в нужном состоянии")
            modules.setExternal(.sound, false)
            pinLocal(to: model.state)
            let local = await Stand.open(theme)
            Stand.save(local, "\(themeName)-\(name)-local")

            modules.setExternal(.sound, true)
            await registry.update()
            check(registry.isEnabled(.sound), "\(themeName) \(name): реестр видит утилиту включённой")
            let remote = await Stand.open(theme)
            Stand.save(remote, "\(themeName)-\(name)-remote")
            let diff = differingPixels(local, remote)
            check(diff == 0, "\(themeName) \(name): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            shots.append(remote)
        }
        check(differingPixels(shots[0], shots[1]) > 0 && differingPixels(shots[0], shots[2]) > 0, "\(themeName): три состояния выглядят по-разному, снимки не пустые")
        await drive("default")
    }
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    let other = LinkClient(id: moduleID)
    modules.setOn(.sound, false)
    modules.setExternal(.sound, false)
    let local = await Stand.open(.dusk)
    modules.setOn(.sound, true)
    modules.setExternal(.sound, true)
    try? await other.setEnabled(false)
    await registry.update()
    let remote = await Stand.open(.dusk)
    Stand.save(remote, "dusk-off-remote")
    let diff = differingPixels(local, remote)
    check(diff == 0, "выключенный модуль: снимки совпали, разных пикселей \(diff)")
    try? await other.setEnabled(true)
    await registry.update()
    await model.read()
}

/// Пассивная утилита остановлена: центр ведёт модуль сам, второго писателя устройства нет.
@MainActor func passive() async {
    let model = RemoteSoundModel.shared
    let other = LinkClient(id: moduleID)
    await model.read()
    await model.perform(.setBluetoothLocked(true))
    Kit.defaults.set(true, forKey: "Test.HubRunning")
    Kit.defaults.set("0.6.0", forKey: "Test.HubVersion")
    Kit.defaults.set(true, forKey: SatelliteRole.hubModuleOnKey(moduleID))
    Kit.defaults.set(false, forKey: SatelliteRole.handedOverKey(moduleID))
    Kit.defaults.synchronize()
    try? await other.setEnabled(true)
    let status = try? await other.status()
    check(status?.line == "Ждём передачу от центра", "пассивная: строка статуса «\(status?.line ?? "нет")»")
    await model.perform(.setBluetoothLocked(false))
    check(model.actionError != nil && model.isBluetoothLocked, "пассивная: действие отвергнуто с текстом, настройка прежняя")
    // Пока утилита стояла, центр поменял настройку; когда передача состоялась, она это видит.
    Kit.defaults.set(false, forKey: "MicGuardBluetoothLocked")
    Kit.defaults.set(true, forKey: SatelliteRole.handedOverKey(moduleID))
    Kit.defaults.synchronize()
    try? await other.setEnabled(true)
    await model.read()
    check(await until(3) { !model.isBluetoothLocked }, "после передачи утилита работает и увидела настройку, сделанную центром")
    await model.perform(.setBluetoothLocked(true))
    check(model.actionError == nil && model.isBluetoothLocked, "после передачи действие снова принимается")
    Kit.defaults.set(false, forKey: "Test.HubRunning")
    try? await other.setEnabled(true)
    await model.read()
}

@MainActor func hung(utility: Int32) async {
    let model = RemoteSoundModel.shared
    await model.read()
    let before = model.state
    kill(utility, SIGSTOP)
    let ticks = TickWatch()
    let started = ProcessInfo.processInfo.systemUptime
    await model.perform(.setBluetoothLocked(!before.isBluetoothLocked))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 2.5, String(format: "зависшая утилита: действие сдалось за %.2f с, не больше 2,5", elapsed))
    check(ticks.maxGap <= 0.3, String(format: "зависшая утилита: простой главного потока %.3f с, не больше 0,3", ticks.maxGap))
    check(model.state == before && model.actionError != nil, "зависшая утилита: прежнее состояние и текст «\(model.actionError ?? "нет")»")
    Stand.save(await Stand.open(.dusk), "dusk-action-failed")
    kill(utility, SIGCONT)
    await pause(0.5)
    let fresh = try? await JSONDecoder().decode(SoundState.self, from: LinkClient(id: moduleID).moduleState())
    check(await until(2) { fresh != nil && model.state == fresh }, "после разморозки центр показывает то же, что утилита")
    await model.perform(.setBluetoothLocked(true))
    await model.read()
    check(model.actionError == nil && model.responding, "после разморозки ошибок нет")
}

/// Утилита убита: центр не зависает и не падает. launchd поднимает её по обращению к сервису, и это тоже верный исход.
@MainActor func died(utility: Int32) async {
    let model = RemoteSoundModel.shared
    await model.read()
    kill(utility, SIGKILL)
    let ticks = TickWatch()
    let started = ProcessInfo.processInfo.systemUptime
    await model.perform(.setBluetoothLocked(false))
    await model.read()
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 8, String(format: "убитая утилита: центр ответил за %.2f с", elapsed))
    check(ticks.maxGap <= 0.3, String(format: "убитая утилита: простой главного потока %.3f с, не больше 0,3", ticks.maxGap))
    print("     после убийства: responding=\(model.responding), ошибка «\(model.actionError ?? "нет")»")
    let shot = await Stand.open(.dusk)
    Stand.save(shot, "dusk-after-kill")
    check(shot.pixelsWide > 0, "экран после убийства собран")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.sound, foreignAction: LinkWire.encoded(SoundAction.setBluetoothLocked(false))) { utility in
                for (name, payload) in notOneAction {
                    check((try? JSONDecoder().decode(SoundAction.self, from: Data(payload.utf8))) == nil, "\(name) не разбирается")
                }
                await garbage()
                await actions()
                await pixels()
                await passive()
                await hung(utility: utility)
                await died(utility: utility)
            }
        }
    }
}
