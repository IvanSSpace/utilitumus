import AppKit
import SwiftUI

// Вкладка «Вентиляторы» в лаунчере, работа в утилите. Запуск: Tests/run-fans-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Служба вентиляторов в стенде не стоит и не ставится:
// действие installHelper (окно пароля) сюда не посылается нигде, а в утилите стенда статус «нет доступа».

let moduleID = "test.fans"

/// Не одно известное действие или значения вне границ: утилита отвечает ошибкой и ничего не меняет.
let badFansActions: [(String, String)] = [
    ("чужой ключ рядом", #"{"setAllAuto":{},"x":1}"#),
    ("чужой ключ внутри", #"{"setAllAuto":{"x":1}}"#),
    ("два действия", #"{"setAllAuto":{},"refreshRunning":{}}"#),
    ("значение не того типа", #"{"setFullPower":{"_0":1}}"#),
    ("действие без значения", #"{"setFullPower":{}}"#),
    ("повтор ключа", #"{"setFullPower":{"_0":true},"setFullPower":{"_0":false}}"#),
    ("настройки не того числа", #"{"setConfigs":{"_0":[]}}"#),
    ("обороты 1e9", #"{"setConfigs":{"_0":[{"fromTemp":50,"mode":"constant","rpm":1000000000,"sensor":"cpu","toTemp":80}]}}"#),
    ("кривая в обратную сторону", #"{"setConfigs":{"_0":[{"fromTemp":80,"mode":"sensor","rpm":0,"sensor":"cpu","toTemp":50}]}}"#),
    ("игра, которой нет", #"{"addGame":{"key":"нет.такой"}}"#),
    ("лаунчер, которого нет", #"{"setLauncherGame":{"isGame":true,"key":"нет.такого"}}"#),
    ("закрыть чужое по выдуманному id", #"{"closeConflictingApp":{"id":"1"}}"#),
]

func wirePure() {
    let actions: [FansAction] = [.setFullPower(true), .setAllAuto, .setConfigs([FanConfig()]), .closeConflictingApp(id: "a"),
                                 .uninstallHelper, .setGameModeEnabled(true), .addGame(key: "k"), .removeGame(key: "k"),
                                 .setLauncherGame(key: "k", isGame: true), .refreshRunning]
    for action in actions {
        check((try? JSONDecoder().decode(FansAction.self, from: LinkWire.encoded(action))) == action, "FansAction \(action) переживает кодирование")
    }
    // Как в утилите (LinkWire.decodeAction): сверка с каноническим видом ловит повтор ключа, который разбор не видит.
    for (name, payload) in badFansActions.prefix(6) {
        check(LinkWire.decodeAction(FansAction.self, from: Data(payload.utf8), limit: 2048) == nil, "\(name) не разбирается")
    }
}

@MainActor func garbage() async {
    await checkBadActions(FansState.self, id: moduleID, extra: badFansActions.map { ($0.0, Data($0.1.utf8)) })
}

/// Встроенные контроллеры в том же состоянии, что показала утилита.
@MainActor func pinLocal(to state: FansState) {
    FanController.shared.configs = state.configs
    FanController.shared.testPin(fans: state.fans, cpu: state.cpuSensors, gpu: state.gpuSensors, conflict: nil,
                                 safetyTripped: state.safetyTripped, lastError: state.lastError)
}

@MainActor func pixels() async {
    let model = RemoteFansModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    await model.read()
    check(model.responding, "утилита ответила")
    check(!model.cpuSensors.isEmpty, "утилита работает: датчики прочитаны")
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        await model.read()
        modules.setExternal(.fans, false)
        pinLocal(to: model.state)
        let local = await Stand.open(theme)
        Stand.save(local, "\(themeName)-local")
        modules.setExternal(.fans, true)
        await registry.update()
        let remote = await Stand.open(theme)
        Stand.save(remote, "\(themeName)-remote")
        // Два текста внешнего модуля отличаются по замыслу (Q2): строка внизу и, при конфликте, плашка.
        let diff = differingPixels(local, remote)
        let footerRows = 40 * local.pixelsWide
        check(diff <= footerRows, "\(themeName): снимки совпали вне нижней строки, разных пикселей \(diff) (допуск \(footerRows))")
        check(RemoteFansModel.shared.isExternal && !BuiltInFansModel.shared.isExternal, "\(themeName): тексты внешнего модуля только у внешнего")
    }
}

@MainActor func actions() async {
    let model = RemoteFansModel.shared
    await model.read()
    // Доступа в стенде нет: управлять нельзя, ни полная мощность, ни настройки не принимаются.
    await model.perform(.setFullPower(true))
    check(model.actionError != nil && !model.fullPower, "без доступа полная мощность отвергнута: «\(model.actionError ?? "нет")»")
    await model.perform(.setAllAuto)
    check(model.actionError != nil, "без доступа «Всё авто» отвергнуто")
    await model.perform(.uninstallHelper)
    check(model.actionError != nil, "доступа нет: удалять нечего")
}

@MainActor func death(utility: Int32) async {
    let model = RemoteFansModel.shared
    let registry = SatelliteRegistry.shared
    await model.read()
    // Одного SIGKILL мало: launchd поднял бы утилиту по первому обращению, и «не отвечает» зависело бы от того, сколько она прожила.
    killUtilityForGood(utility)
    await pause(0.5)
    await registry.update()
    check(await until(6) { !model.responding }, "утилита убита: модель говорит «не отвечает»")
    check(model.screen(of: .fans, registry) == .notResponding, "вкладка показывает запасной экран")
    let shot = await Stand.open(.dusk)
    Stand.save(shot, "dusk-dead")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.fans, foreignAction: LinkWire.encoded(FansAction.setFullPower(true))) { utility in
                wirePure()
                await garbage()
                await actions()
                await pixels()
                await death(utility: utility)
            }
        }
    }
}
