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

/// Контроллер утилиты, собранный в стенд, в том же состоянии, что показала утилита. Такта и SMC у него нет: он не запущен.
@MainActor func pinLocal(to state: FansState) {
    FanController.shared.configs = state.configs
    FanController.shared.testPin(fans: state.fans, cpu: state.cpuSensors, gpu: state.gpuSensors, conflict: nil,
                                 safetyTripped: state.safetyTripped, lastError: state.lastError)
}

/// Экран утилиты на её контроллере в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.fans), animated: false) { _, active in
        AnyView(ModuleScreen(module: .fans) { FansView(model: BuiltInFansModel.shared) }
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.fans))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .fans, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

/// Строки снимка, где есть хоть один разный пиксель: первая и последняя. nil — снимки совпали или размер другой.
func differingRowBand(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> ClosedRange<Int>? {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let pa = a.bitmapData, let pb = b.bitmapData else { return nil }
    let rows = (0..<a.pixelsHigh).filter { memcmp(pa + $0 * a.bytesPerRow, pb + $0 * a.bytesPerRow, a.bytesPerRow) != 0 }
    guard let first = rows.first, let last = rows.last else { return nil }
    return first...last
}


/// Служба в стенде не стоит: без «Позже» на месте экрана чек-лист, и сверялись бы два чек-листа.
@MainActor func showModuleScreen() async {
    let registry = SatelliteRegistry.shared
    await registry.update()
    check(await until(3) { AccessState.shared.blocked.contains(.fans) }, "доступа нет: центр показывает чек-лист")
    let checklist = await Stand.open(.dusk)
    Stand.save(checklist, "dusk-setup")
    SetupFlow.shared.postpone(.fans)
    let screen = await Stand.open(.dusk)
    check(differingPixels(checklist, screen) > 0, "«Позже»: вместо чек-листа экран модуля")
}

@MainActor func pixels() async {
    let model = RemoteFansModel.shared
    let registry = SatelliteRegistry.shared
    await model.read()
    check(model.responding, "утилита ответила")
    check(!model.cpuSensors.isEmpty, "утилита работает: датчики прочитаны")
    await showModuleScreen()
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        await registry.update()
        check(registry.isEnabled(.fans), "\(themeName): реестр видит утилиту включённой")
        // Датчики настоящие, такт утилиты меняет обороты и градусы, пока вкладка открыта. Контроллер закрепляется на том,
        // что вкладка показала в момент снимка; такт мог попасть между ними, поэтому до трёх попыток. Подделка красна в каждой.
        var different = Int.max, local: NSBitmapImageRep!, remote: NSBitmapImageRep!, shown = model.state
        for _ in 0..<3 {
            remote = await Stand.open(theme)
            shown = model.state
            pinLocal(to: shown)
            local = await openLocal(theme)
            different = differingPixels(local, remote)
            if different == 0 { break }
        }
        Stand.save(local, "\(themeName)-local")
        Stand.save(remote, "\(themeName)-remote")
        check(different == 0, "\(themeName): окно утилиты и вкладка совпали до пикселя, разных пикселей \(different)")
        // Сверка видит значения: контроллер с другими градусами на тот же снимок уже не похож.
        FanController.shared.testPin(fans: shown.fans, cpu: shown.cpuSensors.map { SensorReading(key: $0.key, value: $0.value + 10) }, gpu: shown.gpuSensors,
                                     conflict: nil, safetyTripped: shown.safetyTripped, lastError: shown.lastError)
        let changed = await openLocal(theme)
        let changedRows = differingRowBand(changed, remote)?.count ?? 0
        check(changedRows > 0, "\(themeName): другие градусы сверка замечает, разные строки \(changedRows)")
    }
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
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
                // Раньше действий: отвергнутое оставляет на вкладке текст ошибки, а на экране утилиты его нет.
                await pixels()
                await actions()
                await death(utility: utility)
            }
        }
    }
}
