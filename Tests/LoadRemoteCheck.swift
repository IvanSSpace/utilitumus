import AppKit
import SwiftUI

// Вкладка «Нагрузка» в лаунчере, работа в утилите. Запуск: Tests/run-load-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Утилита пишет историю в свою временную папку,
// настоящий load-history.json не трогает; ничего не останавливает и не запускает: стенд шлёт только отказные действия.

let moduleID = "test.load"
let unknownPlan = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
let notOneAction: [(String, String)] = [
    ("confirmStop с неизвестным id плана", #"{"confirmStop":{"planID":"\#(unknownPlan)"}}"#),
    ("confirmBackground с неизвестным id плана", #"{"confirmBackground":{"planID":"\#(unknownPlan)"}}"#),
    ("confirmStop с pid вместо плана", #"{"confirmStop":{"pids":[1,2],"planID":"\#(unknownPlan)"}}"#),
    ("confirmStop без id", #"{"confirmStop":{}}"#),
    ("остановка pid без uniqueID", #"{"requestStop":{"_0":{"process":{"_0":{"pid":1}}}}}"#),
    ("остановка pid 1", #"{"requestStop":{"_0":{"process":{"_0":{"pid":1,"uniqueID":1}}}}}"#),
    ("остановка группы, которой нет", #"{"requestStop":{"_0":{"group":{"_0":"project:нет"}}}}"#),
    ("argv рядом с целью", #"{"requestStop":{"_0":{"group":{"_0":"x","argv":["/bin/rm"]}}}}"#),
    ("агент, которого нет", #"{"requestAgent":{"label":"com.nobody.nothing","verb":"stop"}}"#),
    ("бот, которого нет", #"{"requestBot":{"id":"nobody","verb":"restart"}}"#),
    ("команда в просьбе", #"{"runCommand":{"argv":["/bin/rm"]}}"#),
    ("чужой ключ рядом", #"{"refreshNow":{},"x":1}"#),
    ("два действия", #"{"refreshNow":{},"cancelStop":{}}"#),
]

func wirePure() {
    let actions: [LoadAction] = [.refreshNow, .cancelStop, .confirmStop(planID: UUID()), .requestStop(.group("app:Chrome")),
                                 .requestAgent(label: "a.b", verb: .stop), .setBackgroundTabOpen(true)]
    for action in actions {
        check((try? JSONDecoder().decode(LoadAction.self, from: LinkWire.encoded(action))) == action, "LoadAction \(action) переживает кодирование")
    }
    // Эти разбираются: на проводе они целые, отказывает им модуль (garbage() проверяет ответ и состояние).
    let wellFormed: Set<String> = ["остановка pid 1"]
    for (name, payload) in notOneAction where !payload.contains("nobody") && !payload.contains("com.nobody") && !payload.contains("project:") && !payload.contains(unknownPlan + "\"}}") && !wellFormed.contains(name) {
        check((try? JSONDecoder().decode(LoadAction.self, from: Data(payload.utf8))) == nil, "\(name) не разбирается")
    }
}

@MainActor func garbage() async {
    await checkBadActions(LoadState.self, id: moduleID, extra: notOneAction.map { ($0.0, Data($0.1.utf8)) })
}

/// Экран открыт: утилита мерит. Экран закрыт или утилита выключена: состояние стоит.
@MainActor func lease() async {
    let other = LinkClient(id: moduleID)
    other.setWatch(.screen)
    let first = try? await other.moduleState()
    await pause(4.5)
    let second = try? await other.moduleState()
    check(first != nil && second != nil && first != second, "экран открыт: утилита мерит, состояние меняется")
    other.setWatch(.none)
    await pause(1)
    let third = try? await other.moduleState()
    await pause(7)
    let fourth = try? await other.moduleState()
    check(third != nil && third == fourth, "экран закрыт: утилита не мерит")
}

@MainActor func passive() async {
    let other = LinkClient(id: moduleID)
    other.setWatch(.screen)
    let running = try? await other.moduleState()
    await pause(4.5)
    let later = try? await other.moduleState()
    check(running != nil && running != later, "до выключения утилита мерит")
    try? await other.setEnabled(false)
    await pause(1)
    let stopped = try? await other.moduleState()
    await pause(7)
    let after = try? await other.moduleState()
    check(stopped != nil && stopped == after, "выключена (пассивна): замеры остановлены, состояние стоит")
    other.setWatch(.none)
    try? await other.setEnabled(true)
    await pause(1)
}

@MainActor func pixels() async {
    let model = RemoteLoadModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        modules.setExternal(.load, true)
        await registry.update()
        _ = await Stand.open(theme)
        check(await until(6) { model.state.measure != nil }, "\(themeName): экран утилиты получил замер")
        await pause(1.5)
        // Утилиту замораживаем: состояние и снимок берутся из одного и того же момента.
        let utility = Int32(CommandLine.arguments[3])!
        kill(utility, SIGSTOP)
        let remote = Stand.snapshot(Stand.window.contentView!)
        let state = model.state
        let palette = model.palette
        Stand.save(remote, "\(themeName)-remote")

        modules.setExternal(.load, false)
        LoadStore.shared.visibleGate = { false }
        LoadStore.shared.testPin(state, palette: palette)
        _ = await Stand.open(theme)
        LoadStore.shared.testPin(state, palette: palette)
        await pause(0.3)
        let local = Stand.snapshot(Stand.window.contentView!)
        Stand.save(local, "\(themeName)-local")
        kill(utility, SIGCONT)

        let diff = differingPixels(local, remote)
        check(diff == 0, "\(themeName): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
        check(state.measure != nil && (state.measure?.groups.isEmpty == false), "\(themeName): на экране настоящие данные, не пустой")
        await pause(0.5)
    }
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    modules.setExternal(.load, true)
    await registry.update()
}

/// Утилита убита: вкладка говорит «не отвечает», центр не падает и не пытается её остановить сам.
@MainActor func death(utility: Int32) async {
    let model = RemoteLoadModel.shared
    let registry = SatelliteRegistry.shared
    await model.read()
    check(model.responding, "до смерти утилита отвечает")
    killUtilityForGood(utility)
    await registry.update()
    check(await until(8) { !model.responding }, "утилита убита: модель это увидела")
    check(model.screen(of: .load, registry) == .notResponding, "утилита убита: вкладка показывает «не отвечает»")
    model.requestStop(.group("app:Chrome"))
    await pause(2.5)
    check(model.actionError != nil, "утилита убита: действие даёт короткий текст, а не зависание")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.load, foreignAction: LinkWire.encoded(LoadAction.dismissNotice)) { utility in
                wirePure()
                await garbage()
                await lease()
                await pixels()
                await passive()
                await death(utility: utility)
            }
        }
    }
}
