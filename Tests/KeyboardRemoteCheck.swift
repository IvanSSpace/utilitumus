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

func wirePure() {
    for (name, payload) in notOneAction {
        check((try? JSONDecoder().decode(KeyboardAction.self, from: Data(payload.utf8))) == nil, "\(name) не разбирается: \(payload)")
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

/// Встроенный контроллер, запущенный в стенде без фишек, и утилита с теми же настройками показывают одно и то же.
@MainActor func pixels() async {
    let model = RemoteKeyboardModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    let controller = KeyboardController.shared
    modules.setExternal(.keyboard, false)
    controller.start()
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        modules.setExternal(.keyboard, false)
        let local = await Stand.open(theme)
        Stand.save(local, "\(themeName)-local")
        modules.setExternal(.keyboard, true)
        await registry.update()
        let remote = await Stand.open(theme)
        Stand.save(remote, "\(themeName)-remote")
        await model.read()
        let diff = differingPixels(local, remote)
        check(diff == 0, "\(themeName): встроенный экран и экран утилиты, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
        check(model.state.logCount == controller.logCount, "\(themeName): счётчик журнала \(model.state.logCount) и \(controller.logCount)")
    }
    // Состояние отличается — снимок тоже: он не пустой.
    await model.perform(.setNewAppLayout(nil))
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

/// Утилита умерла: вкладка «не отвечает», без падения.
@MainActor func died(utility: Int32) async {
    let model = RemoteKeyboardModel.shared
    kill(utility, SIGKILL)
    check(await until(6) { !model.responding } || { model.refresh(); return false }(), "утилита убита: модель это увидела")
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
                await hung(utility: utility)
                await died(utility: utility)
            }
        }
    }
}
