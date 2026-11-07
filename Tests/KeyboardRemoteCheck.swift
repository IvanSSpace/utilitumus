import AppKit
import SwiftUI

// Вкладка «Клавиатура» в лаунчере, работа в утилите. Запуск: Tests/run-keyboard-remote-check.sh
// Фишки выключены в домене стенда: tap не создаётся, система не трогается. Ни одно действие здесь фишку не включает
// и не пишет в буфер обмена (copyLog).

let moduleID = "test.keyboard"
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"repair":{},"x":1}"#),
    ("два действия", #"{"repair":{},"refreshAccess":{}}"#),
    ("чужой ключ внутри repair", #"{"repair":{"x":1}}"#),
    ("чужой ключ внутри действия", #"{"setTrigger":{"_0":"onPress","x":1}}"#),
    ("значение не того типа", #"{"setMode":{"_0":1}}"#),
    ("раскладка null", #"{"setNewAppLayout":{"_0":null}}"#),
    ("фишка, которой нет", #"{"setFeature":{"feature":"ghost","on":true}}"#),
    ("повтор ключа", #"{"setMode":{"_0":"cycle"},"setMode":{"_0":"lastTwo"}}"#),
]

// MARK: - Сценарии

/// Через ту же сверку, что и в утилите (`LinkWire.decodeAction`): повтор ключа обычный разбор пропускает,
/// сверка с каноническим кодированием его отвергает. Предел тот же, что в `KeyboardController.handle`.
func wirePure() {
    for (name, payload) in notOneAction {
        check(LinkWire.decodeAction(KeyboardAction.self, from: Data(payload.utf8), limit: 512) == nil, "\(name) не пройдёт связь: \(payload)")
    }
}

@MainActor func garbage() async {
    await checkBadActions(KeyboardState.self, id: moduleID, extra: notOneAction.map { ($0.0, Data($0.1.utf8)) } + [
        ("идентификатор не приложения", LinkWire.encoded(KeyboardAction.addExcluded("/Applications/Calculator.app"))),
        ("раскладки нет среди включённых", LinkWire.encoded(KeyboardAction.setNewAppLayout("com.apple.keylayout.Ghost"))),
        ("фишка «Скоро»", LinkWire.encoded(KeyboardAction.setFeature(feature: .capsLock, on: true))),
        ("запрос доступа без «Языка по Fn»", LinkWire.encoded(KeyboardAction.requestAccess)),
        ("отключить 🌐 без «Языка по Fn»", LinkWire.encoded(KeyboardAction.disableSystemAction)),
        ("диктовка без «Языка по Fn»", LinkWire.encoded(KeyboardAction.disableDictationDoubleFn)),
        ("всё сразу без «Языка по Fn»", LinkWire.encoded(KeyboardAction.disableAllSystemActions)),
    ])
}

@MainActor func actions() async {
    let model = RemoteKeyboardModel.shared
    await model.read()
    check(model.responding && !model.tapActive && !KeyboardFeature.allCases.contains(where: model.isOn), "утилита отвечает, фишки выключены, tap нет")
    await model.perform(.setTrigger(.onPress))
    check(model.actionError == nil && model.trigger == .onPress, "setTrigger дошёл до утилиты")
    let other = LinkClient(id: moduleID)
    var fresh = try? await JSONDecoder().decode(KeyboardState.self, from: other.moduleState())
    check(fresh?.trigger == .onPress, "и утилита сама так отвечает")
    await model.perform(.setMode(.cycle))
    check(model.mode == .cycle, "setMode")
    await model.perform(.addExcluded("com.example.app"))
    check(model.excludedApps == ["com.example.app"], "addExcluded")
    await model.perform(.addExcluded("не приложение"))
    check(model.actionError != nil && model.excludedApps == ["com.example.app"], "плохой идентификатор: текст ошибки, список прежний")
    await model.perform(.setFeature(feature: .capsLock, on: true))
    check(model.actionError != nil && !model.isOn(.capsLock), "фишка «Скоро»: отказ")
    await model.perform(.removeExcluded("com.example.app"))
    check(model.actionError == nil && model.excludedApps.isEmpty, "removeExcluded, ошибка снята")
    await model.perform(.setTrigger(.onRelease))
    await model.perform(.setMode(.lastTwo))
    fresh = try? await JSONDecoder().decode(KeyboardState.self, from: other.moduleState())
    check(fresh == model.state, "после возврата настроек модель и утилита показывают одно")
    await model.perform(.refreshSystem)
    await model.perform(.refreshAccess)
    check(model.actionError == nil && model.responding, "refreshSystem и refreshAccess: чтение без записи")
    check(fresh?.logCount == model.logCount, "журнал под открытым экраном совпадает")
}

/// Вид на контроллере утилиты в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.keyboard), animated: false) { _, active in
        AnyView(ModuleScreen(module: .keyboard) { KeyboardView(model: KeyboardController.shared) }
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.keyboard))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .keyboard, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

/// Контроллер утилиты, запущенный в стенде без фишек, и утилита с теми же настройками показывают одно и то же.
/// Фишки выключены: их настройки на экран не выходят, от состояния на нём зависит только счётчик журнала.
@MainActor func pixels() async {
    let model = RemoteKeyboardModel.shared
    let registry = SatelliteRegistry.shared
    let controller = KeyboardController.shared
    controller.start()
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for variant in ["first", "restarted"] {
            if variant == "restarted" {
                // Запуск заново добавляет строку в журнал: утилите через передачу, контроллеру напрямую. Системное здесь не трогается.
                await passive()
                controller.quit()
                controller.start()
            }
            let local = await openLocal(theme)
            Stand.save(local, "\(themeName)-\(variant)-local")
            await registry.update()
            check(registry.isEnabled(.keyboard), "\(themeName) \(variant): реестр видит утилиту включённой")
            _ = await Stand.open(theme)
            check(await until(2) { model.state.logCount == controller.logCount }, "\(themeName) \(variant): счётчик журнала \(model.state.logCount) и \(controller.logCount)")
            await pause(0.2)
            let remote = Stand.snapshot(Stand.window.contentView!)
            Stand.save(remote, "\(themeName)-\(variant)-remote")
            let diff = differingPixels(local, remote)
            check(diff == 0, "\(themeName) \(variant): экран контроллера утилиты и вкладка, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            shots.append(remote)
        }
        check(differingPixels(shots[0], shots[1]) > 0, "\(themeName): строка журнала меняет снимок, он не пустой")
    }
    controller.quit()
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
}

@MainActor func hung(utility: Int32) async {
    let model = RemoteKeyboardModel.shared
    await model.read()
    let before = model.state
    kill(utility, SIGSTOP)
    let ticks = TickWatch()
    let started = ProcessInfo.processInfo.systemUptime
    await model.perform(.setMode(before.mode == .cycle ? .lastTwo : .cycle))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 2.5, String(format: "зависшая утилита: действие сдалось за %.2f с, не больше 2,5", elapsed))
    check(ticks.maxGap <= 0.3, String(format: "зависшая утилита: простой главного потока %.3f с, не больше 0,3", ticks.maxGap))
    check(model.state == before && model.actionError != nil, "зависшая утилита: прежнее состояние и короткий текст")
    kill(utility, SIGCONT)
    await pause(0.5)
    let fresh = try? await JSONDecoder().decode(KeyboardState.self, from: LinkClient(id: moduleID).moduleState())
    check(await until(2) { fresh != nil && model.state == fresh }, "после разморозки центр показывает то же, что утилита")
    await model.perform(.setMode(.lastTwo))
    await model.read()
    check(model.actionError == nil && model.responding && model.mode == .lastTwo, "после разморозки ошибок нет, режим возвращён")
}

/// Пассивная значит остановленная: центр запущен и модуль ещё его, утилита ничего не ведёт и говорит почему.
/// Фишки в стенде выключены, поэтому здесь нельзя включить tap, даже если бы пассивность не работала.
@MainActor func passive() async {
    let defaults = Kit.defaults
    let client = LinkClient(id: moduleID)
    let model = RemoteKeyboardModel.shared
    await model.read()
    let line = try? await client.status().line
    check(line != "Ждём передачу от центра", "до пассивности утилита работает («\(line ?? "нет")»)")
    defaults.set(true, forKey: "Test.HubRunning")
    defaults.set("0.6.0", forKey: "Test.HubVersion")
    defaults.set(true, forKey: SatelliteRole.hubModuleOnKey(moduleID))
    defaults.set(false, forKey: SatelliteRole.handedOverKey(moduleID))
    defaults.synchronize()
    try? await client.setEnabled(true)
    await model.read()
    let passiveLine = try? await client.status().line
    check(passiveLine == "Ждём передачу от центра", "пассивная: статус говорит почему («\(passiveLine ?? "нет")»)")
    check(model.responding && !model.tapActive && !KeyboardFeature.allCases.contains(where: model.isOn), "пассивная: отвечает, фишки выключены, tap нет")

    defaults.set(true, forKey: SatelliteRole.handedOverKey(moduleID))
    defaults.synchronize()
    try? await client.setEnabled(true)
    var back = false
    for _ in 0..<50 where !back {
        back = (try? await client.status().line) != "Ждём передачу от центра"
        if !back { await pause(0.1) }
    }
    check(back, "передача: утилита снова ведёт модуль, статус другой")
    await model.read()
    check(model.responding && !model.tapActive && !KeyboardFeature.allCases.contains(where: model.isOn), "после передачи: фишки выключены, tap нет")
    defaults.set(false, forKey: "Test.HubRunning")
    defaults.synchronize()
    try? await client.setEnabled(true)
}

/// Утилита умерла насовсем (без `killUtilityForGood` метка launchd подняла бы её заново): вкладка «не отвечает», без падения.
@MainActor func died(utility: Int32) async {
    let model = RemoteKeyboardModel.shared
    let registry = SatelliteRegistry.shared
    killUtilityForGood(utility)
    await registry.update()
    check(await until(6) { !model.responding }, "утилита убита: модель это увидела")
    await pause(0.2)
    await model.read()
    await model.read()
    check(!model.responding, "утилита убита: ответа нет, центр жив")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.keyboard, foreignAction: LinkWire.encoded(KeyboardAction.setTrigger(.onPress))) { utility in
                wirePure()
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
