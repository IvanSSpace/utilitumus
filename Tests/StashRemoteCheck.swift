import AppKit
import SwiftUI

// Вкладка «Стеш программ» в центре, работа в утилите. Запуск: Tests/run-stash-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Программ на стенде нет: и у центра, и у утилиты список
// запущенных пуст, закрыть или запустить настоящую нельзя. Записи и сценарии кладёт скрипт в общий тестовый домен.

let moduleID = "test.stash"
let seededScenario = "Работа"
let seededProgram = "Калькулятор"
/// Не одно известное действие: разбор отказывает, сколько бы известного в этом ни было.
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"restore":{},"x":1}"#),
    ("чужой ключ внутри restore", #"{"restore":{"x":1}}"#),
    ("два действия", #"{"restore":{},"selectOnlyHeavy":{}}"#),
    ("pid вместо id", #"{"forceTerminate":{"pid":1}}"#),
    ("путь вместо списка", #"{"stash":{"bundleIDs":"/Applications/Safari.app"}}"#),
    ("лишнее поле у stash", #"{"stash":{"bundleIDs":["a"],"force":true}}"#),
    ("действие без значения", #"{"stash":{}}"#),
    ("повтор ключа", #"{"setClosing":{"bundleID":"a","closing":true,"closing":false}}"#),
]

func wirePure() {
    for (name, payload) in notOneAction {
        // Как у утилиты: повтор ключа разбор не видит, его ловит сверка с каноническим кодированием.
        check(LinkWire.decodeAction(StashAction.self, from: Data(payload.utf8), limit: 64 * 1024) == nil, "\(name) не разбирается: \(payload)")
    }
    let actions: [StashAction] = [.restore, .stash(bundleIDs: ["a"]), .setClosing(bundleID: "a", closing: false), .refreshUsage]
    for action in actions {
        check((try? JSONDecoder().decode(StashAction.self, from: JSONEncoder().encode(action))) == action, "\(action) переживает кодирование")
    }
}

@MainActor func garbage() async {
    await checkBadActions(StashState.self, id: moduleID, extra: notOneAction.map { ($0.0, Data($0.1.utf8)) })
}

/// Центр и утилита читают одну запись; чужие и свои программы закрыть нельзя.
@MainActor func tab() async {
    let model = RemoteStashModel.shared
    await model.read()
    check(model.responding, "утилита отвечает")
    check(model.stashedPrograms.map(\.name) == [seededProgram], "утилита видит запись из общего домена: \(model.stashedPrograms.map(\.name))")
    check(model.scenarios.map(\.name) == [seededScenario], "и сценарий")
    check(model.runningPrograms.isEmpty, "на стенде нет программ в списке")

    for (name, action) in [("лаунчер", StashAction.stash(bundleIDs: [Kit.hubBundleID])),
                           ("сама утилита", .stash(bundleIDs: [KitLink.bundleID("stash")])),
                           ("Finder", .stash(bundleIDs: ["com.apple.finder"])),
                           ("pid", .stash(bundleIDs: ["1"])),
                           ("принудительно чужую", .forceTerminate(bundleIDs: [Kit.hubBundleID])),
                           ("ничего не отмечено", .addScenario(name: "Имя")),
                           ("чужой сценарий", .deleteScenario(id: UUID()))] {
        await model.perform(action)
        check(model.actionError != nil, "\(name): отказ с текстом («\(model.actionError ?? "нет")»)")
    }
    await model.perform(.selectOnlyHeavy)
    check(model.actionError == nil, "верное действие убирает текст ошибки")
    check(model.stashedPrograms.map(\.name) == [seededProgram], "после отказов запись на месте")
}

/// Остановленная утилита записи не касается и ничего не принимает, включённая читает её заново.
@MainActor func passive() async {
    let model = RemoteStashModel.shared
    let other = LinkClient(id: moduleID)
    let before = Kit.defaults.data(forKey: "StashedApps")
    check(before != nil, "запись в общем домене есть")
    try? await other.setEnabled(false)
    check(await until(3) { model.stashedPrograms.isEmpty }, "утилита выключена: записи она не показывает")
    await model.perform(.restore)
    check(model.actionError != nil, "утилита выключена: действие отвергнуто с текстом")
    Kit.defaults.synchronize()
    check(Kit.defaults.data(forKey: "StashedApps") == before, "утилита выключена: запись не тронута")
    try? await other.setEnabled(true)
    check(await until(3) { model.stashedPrograms.map(\.name) == [seededProgram] }, "утилита снова включена: запись прочитана заново")
}

/// Вид на сторе утилиты в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.stash), animated: false) { _, active in
        AnyView(ModuleScreen(module: .stash) { StashView(store: StashStore.shared) }
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.stash))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .stash, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

@MainActor func pixels() async {
    let registry = SatelliteRegistry.shared
    let model = RemoteStashModel.shared
    let store = StashStore.shared
    var shots: [NSBitmapImageRep] = []
    await registry.update()
    await model.read()
    // Доступа на стенде нет ни у кого: шаги настройки отложены, и сравнивается сам экран Стеша, а не чек-лист.
    SetupFlow.shared.postpone(.stash)
    check(store.wireState.stashed == model.state.stashed && store.wireState.scenarios == model.state.scenarios, "стор стенда в том же состоянии, что утилита: \(store.wireState.stashed.map(\.name))")
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        let local = await openLocal(theme)
        Stand.save(local, "\(themeName)-local")
        let remote = await Stand.open(theme)
        Stand.save(remote, "\(themeName)-remote")
        let diff = differingPixels(local, remote)
        check(diff == 0, "\(themeName): экраны совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
        shots.append(remote)
    }
    check(differingPixels(shots[0], shots[1]) > 0, "темы различаются, снимки не пустые")
    // Выключенная утилита: тот самый экран «модуль выключен».
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    let other = LinkClient(id: moduleID)
    let container = Stand.container()
    container.show(.module(.stash), animated: false) { _, active in
        AnyView(ModuleOffView(module: .stash) {} more: {}
            .environment(\.pageActive, active)
            .environment(\.dsTint, DSTheme.dusk.accent(.stash))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .stash, neutral: false); DSTheme.dusk.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    let localOff = Stand.snapshot(container)
    Stand.save(localOff, "dusk-off-local")
    try? await other.setEnabled(false)
    await registry.update()
    let remoteOff = await Stand.open(.dusk)
    Stand.save(remoteOff, "dusk-off-remote")
    let diff = differingPixels(localOff, remoteOff)
    check(diff == 0, "выключенный модуль: снимки совпали, разных пикселей \(diff)")
    try? await other.setEnabled(true)
    await registry.update()
    check(await until(3) { model.stashedPrograms.map(\.name) == [seededProgram] }, "утилита снова включена: запись на месте")
}

/// Возврат отвечает сразу, ход виден в `busy`. Запуск у утилиты стенда всегда неудачный: ни одна программа не откроется.
@MainActor func restore() async {
    let model = RemoteStashModel.shared
    let started = Date()
    await model.perform(.restore)
    check(Date().timeIntervalSince(started) < 1.5, "restore ответил сразу, не после возврата")
    check(await until(10) { model.busy == nil && model.report != nil }, "возврат закончился, отчёт пришёл")
    check(model.report?.failed == [seededProgram] && model.report?.restored == 0, "отчёт: \(String(describing: model.report))")
    check(model.stashedPrograms.isEmpty, "запись после возврата убрана")
    await model.perform(.restore)
    check(model.actionError != nil, "повторный возврат: нечего возвращать")
}

@MainActor func hung(utility: Int32) async {
    let model = RemoteStashModel.shared
    let registry = SatelliteRegistry.shared
    kill(utility, SIGSTOP)
    await registry.update()
    check(await until(6) { !model.responding }, "зависла: модель это узнала")
    check(model.screen(registry) == .notResponding, "зависла: экран «не отвечает»")
    kill(utility, SIGCONT)
    await registry.update()
    check(await until(4) { model.responding }, "ожила: модель ответила")
}

/// Утилита убита насовсем: центр это замечает и не падает.
@MainActor func death(utility: Int32) async {
    let model = RemoteStashModel.shared
    let registry = SatelliteRegistry.shared
    killUtilityForGood(utility)
    await registry.update()
    check(await until(8) { !model.responding }, "утилита умерла: модель говорит «не отвечает»")
    check(model.screen(registry) == .notResponding, "утилита умерла: экран «не отвечает»")
    await model.perform(.restore)
    check(model.actionError != nil, "утилита умерла: действие отвергнуто с текстом")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.stash, foreignAction: LinkWire.encoded(StashAction.selectOnlyHeavy)) { utility in
                // Центр стенда не видит настоящих программ: ни закрыть, ни запустить.
                StashStore.shared.system = StashSystem(runningApps: { [] }, open: { _, _ in throw CocoaError(.fileNoSuchFile) })
                StashStore.shared.refresh()
                wirePure()
                await garbage()
                await tab()
                await passive()
                await pixels()
                await restore()
                await hung(utility: utility)
                await death(utility: utility)
            }
        }
    }
}
