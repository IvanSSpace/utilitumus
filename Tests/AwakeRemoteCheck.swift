import AppKit
import SwiftUI

// Вкладка «Не спать» в лаунчере, работа в утилите. Запуск: Tests/run-awake-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift, здесь только то, что знает про «Не спать».

let moduleID = "test.awake"
let assertionName = "Utilitumus: Keep Awake"
let badDuration = #"{"setDuration":{"_0":12345}}"#
/// Не одно известное действие: разбор отказывает, сколько бы известного в этом ни было.
let notOneAction: [(String, String)] = [
    ("чужой ключ рядом", #"{"toggle":{},"x":1}"#),
    ("чужой ключ рядом со значением", #"{"setDuration":{"_0":3600},"x":1}"#),
    ("два действия", #"{"toggle":{},"setKeepDisplay":{"_0":true}}"#),
    ("чужой ключ внутри toggle", #"{"toggle":{"x":1}}"#),
    ("чужой ключ внутри действия", #"{"setKeepDisplay":{"_0":true,"x":1}}"#),
    ("действие без значения", #"{"setDuration":{}}"#),
    ("значение не того типа", #"{"setKeepDisplay":{"_0":1}}"#),
    ("toggle не объект", #"{"toggle":1}"#),
    ("пустой объект", "{}"),
    ("массив", #"[{"toggle":{}}]"#),
]
let repeatedKey = #"{"setDuration":{"_0":3600},"setDuration":{"_0":0}}"#

/// Не на главном потоке: стенд измеряет его простой.
func holdsAssertion(pid: Int32) async -> Bool {
    await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .contains { $0.contains(assertionName) && $0.contains("pid \(pid)(") }
    }.value
}

// MARK: - Состояния

struct Pinned {
    let name: String
    let active: Bool
    let duration: AwakeDuration
    let keepDisplay: Bool
}

let pinnedStates = [
    Pinned(name: "sleeps", active: false, duration: .forever, keepDisplay: false),
    Pinned(name: "awake-forever", active: true, duration: .forever, keepDisplay: false),
    Pinned(name: "awake-1h", active: true, duration: .hour1, keepDisplay: true),
]

/// Настоящая утилита приходит в состояние через модель центра.
@MainActor func drive(_ pinned: Pinned) async {
    let model = RemoteAwakeModel.shared
    if model.isActive { await model.perform(.toggle) }
    await model.perform(.setDuration(pinned.duration.rawValue))
    await model.perform(.setKeepDisplay(pinned.keepDisplay))
    if pinned.active { await model.perform(.toggle) }
}

/// Встроенный контроллер в том же состоянии, тот же срок до секунды. Assertion у стенда при этом не появляется.
@MainActor func pinLocal(to state: AwakeState) {
    let controller = AwakeController.shared
    controller.testPin(isActive: false, endDate: nil)
    controller.keepDisplay = state.keepDisplay
    controller.duration = state.duration
    controller.canStart = state.canStart
    controller.testPin(isActive: state.isActive, endDate: state.endDate)
}

// MARK: - Сценарии

func wirePure() {
    let state = AwakeState(isActive: true, endDate: Date(timeIntervalSinceReferenceDate: 800_000_000.25), keepDisplay: true,
                           duration: .hour2, canStart: false)
    check((try? JSONDecoder().decode(AwakeState.self, from: JSONEncoder().encode(state))) == state, "AwakeState переживает кодирование, срок до доли секунды")
    let actions: [AwakeAction] = [.toggle, .setKeepDisplay(true), .setDuration(3600)]
    for action in actions {
        check((try? JSONDecoder().decode(AwakeAction.self, from: JSONEncoder().encode(action))) == action, "AwakeAction \(action) переживает кодирование")
    }
    let foreign = #"{"isActive":false,"keepDisplay":false,"duration":12345,"canStart":true}"#
    check((try? JSONDecoder().decode(AwakeState.self, from: Data(foreign.utf8))) == nil, "состояние с чужой длительностью центр не принимает")
    check((try? JSONDecoder().decode(AwakeAction.self, from: Data(#"{"explode":{}}"#.utf8))) == nil, "неизвестное действие не разбирается")
    for (name, payload) in notOneAction {
        check((try? JSONDecoder().decode(AwakeAction.self, from: Data(payload.utf8))) == nil, "\(name) не разбирается: \(payload)")
    }
}

@MainActor func garbage() async {
    await checkBadActions(AwakeState.self, id: moduleID, extra: [
        ("длительность 12345", Data(badDuration.utf8)),
        ("повтор ключа", Data(repeatedKey.utf8)),
    ] + notOneAction.map { ($0.0, Data($0.1.utf8)) })
}

@MainActor func button(stand: Int32, utility: Int32) async {
    let model = RemoteAwakeModel.shared
    await model.read()
    check(model.responding && !model.isActive, "до нажатия блокировки нет")
    check(!(await holdsAssertion(pid: utility)), "до нажатия assertion нет")
    model.toggle()
    check(await until(2) { model.isActive }, "нажатие: модель показала ответ утилиты")
    check(await holdsAssertion(pid: utility), "нажатие: assertion у процесса утилиты")
    check(!(await holdsAssertion(pid: stand)), "нажатие: у центра assertion нет")
    check(!AwakeController.shared.isActive, "нажатие: встроенный контроллер не трогали")

    // Статус меняет сама утилита: команда сигналом, чтения от стенда нет.
    kill(utility, SIGUSR1)
    check(await until(2) { !model.isActive }, "statusChanged: центр перечитал и увидел выключение")
    check(!(await holdsAssertion(pid: utility)), "повторное нажатие снимает assertion")

    await model.perform(.setDuration(12345))
    check(model.actionError != nil && model.duration == .forever, "длительность 12345 через модель: текст ошибки, длительность прежняя")
    await model.perform(.setDuration(7200))
    check(model.actionError == nil && model.duration == .hour2, "успешное действие убирает текст ошибки")
    let other = LinkClient(id: moduleID)
    _ = try? await other.moduleAction(LinkWire.encoded(AwakeAction.setDuration(0)))
    check(await until(2) { model.duration == .forever }, "настройку поменяли снаружи: центр увидел по statusChanged")
    _ = try? await other.moduleAction(LinkWire.encoded(AwakeAction.setKeepDisplay(true)))
    check(await until(2) { model.keepDisplay }, "и «экран не гаснет» тоже")
    await model.perform(.setKeepDisplay(false))

    // Выключенная утилита не включает блокировку, что бы ни прислали.
    try? await other.setEnabled(false)
    check(await until(2) { !model.canStart }, "утилита выключена: canStart снят")
    await model.perform(.toggle)
    check(model.actionError != nil && !model.isActive, "утилита выключена: действие отвергнуто с текстом")
    check(!(await holdsAssertion(pid: utility)), "утилита выключена: assertion нет")
    try? await other.setEnabled(true)
    check(await until(2) { model.canStart }, "утилита снова включена")
}

@MainActor func pixels() async {
    let model = RemoteAwakeModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for pinned in pinnedStates {
            await drive(pinned)
            await model.read()
            check(model.responding && model.isActive == pinned.active && model.duration == pinned.duration, "\(themeName) \(pinned.name): утилита в нужном состоянии")
            check((model.endDate != nil) == (pinned.duration != .forever && pinned.active), "\(themeName) \(pinned.name): срок \(model.endDate.map(String.init(describing:)) ?? "нет")")

            modules.setExternal(.awake, false)
            pinLocal(to: model.state)
            let local = await Stand.open(theme)
            Stand.save(local, "\(themeName)-\(pinned.name)-local")

            modules.setExternal(.awake, true)
            await registry.update()
            check(registry.isEnabled(.awake), "\(themeName) \(pinned.name): реестр видит утилиту включённой")
            let remote = await Stand.open(theme)
            Stand.save(remote, "\(themeName)-\(pinned.name)-remote")

            let diff = differingPixels(local, remote)
            check(diff == 0, "\(themeName) \(pinned.name): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            shots.append(remote)
        }
        check(differingPixels(shots[0], shots[1]) > 0 && differingPixels(shots[1], shots[2]) > 0, "\(themeName): три состояния выглядят по-разному, снимки не пустые")
        await drive(pinnedStates[0])
    }
    // Эта тема выбрана и выключенный модуль выглядит как встроенный выключенный.
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    let other = LinkClient(id: moduleID)
    modules.setOn(.awake, false)
    modules.setExternal(.awake, false)
    let local = await Stand.open(.dusk)
    Stand.save(local, "dusk-off-local")
    modules.setOn(.awake, true)
    modules.setExternal(.awake, true)
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

// MARK: - Карточка дашборда и меню-бар

/// Что показывает карточка дашборда в этом состоянии у встроенного модуля.
func expectedCard(_ pinned: Pinned) -> DashState {
    guard pinned.active else { return DashState(text: "можно спать", actionTitle: "Не спать", actionIcon: "cup.and.saucer") }
    let tail = pinned.duration == .forever ? "" : " · ещё 1 ч 0 мин"
    return DashState(text: "не спит\(tail)", actionTitle: "Можно спать", actionIcon: "moon.zzz")
}

/// Встроенный модуль и утилита в одном состоянии: дашборд и пункт меню совпадают до пикселя.
@MainActor func cardPixels() async {
    let model = RemoteAwakeModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    let slot = DashboardLive.slot(.awake)
    var menuShots: [NSBitmapImageRep] = []
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        var shots: [NSBitmapImageRep] = []
        for pinned in pinnedStates {
            await drive(pinned)
            await model.read()
            await registry.update()
            let expected = expectedCard(pinned)
            let name = "\(themeName) \(pinned.name)"

            modules.setExternal(.awake, false)
            pinLocal(to: model.state)
            _ = await Stand.open(theme, .dashboard)
            check(await until(2.5) { slot.state == expected }, "\(name): карточка встроенного «\(slot.state.text)»")
            await pause(0.2)
            let localShot = Stand.snapshot(Stand.window.contentView!)
            Stand.save(localShot, "dash-\(themeName)-\(pinned.name)-local")
            let localMenu = await Stand.menuItem(AwakeMenuItem())

            // Контроллер в обратном состоянии: экран, читающий его вместо утилиты, снимок не пройдёт.
            AwakeController.shared.testPin(isActive: !pinned.active, endDate: nil)
            modules.setExternal(.awake, true)
            _ = await Stand.open(theme, .dashboard)
            check(await until(2.5) { slot.state == expected }, "\(name): карточка утилиты «\(slot.state.text)»")
            await pause(0.2)
            let remoteShot = Stand.snapshot(Stand.window.contentView!)
            Stand.save(remoteShot, "dash-\(themeName)-\(pinned.name)-remote")
            let remoteMenu = await Stand.menuItem(AwakeMenuItem())

            let diff = differingPixels(localShot, remoteShot)
            check(diff == 0, "\(name): дашборд совпал, разных пикселей \(diff) из \(localShot.pixelsWide * localShot.pixelsHigh)")
            let menuDiff = differingPixels(localMenu, remoteMenu)
            check(menuDiff == 0, "\(name): пункт меню совпал, разных пикселей \(menuDiff)")
            shots.append(remoteShot)
            if themeName == "dusk" { menuShots.append(remoteMenu) }
        }
        check(differingPixels(shots[0], shots[1]) > 0 && differingPixels(shots[1], shots[2]) > 0, "\(themeName): три состояния дашборда различаются, снимки не пустые")
        await drive(pinnedStates[0])
    }
    check(differingPixels(menuShots[0], menuShots[1]) > 0, "пункт меню: включён и выключен различаются, снимок не пустой")
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
    await model.read()
    AwakeController.shared.testPin(isActive: false, endDate: nil)
}

/// Кнопка карточки и пункт меню идут в утилиту, встроенный контроллер не трогают.
@MainActor func cardActions(stand: Int32, utility: Int32) async {
    let model = RemoteAwakeModel.shared
    let modules = ModuleManager.shared
    let registry = SatelliteRegistry.shared
    let slot = DashboardLive.slot(.awake)
    let other = LinkClient(id: moduleID)
    await drive(pinnedStates[0])
    await model.read()
    await registry.update()
    _ = await Stand.open(.dusk, .dashboard)

    DashboardLive.perform(.awake, askStash: {})
    check(await until(2) { model.isActive }, "кнопка карточки: утилита включилась")
    check(await holdsAssertion(pid: utility), "кнопка карточки: assertion у процесса утилиты")
    check(!(await holdsAssertion(pid: stand)) && !AwakeController.shared.isActive, "кнопка карточки: у центра assertion нет, контроллер не тронут")
    check(await until(2.5) { slot.state.actionTitle == "Можно спать" }, "кнопка карточки: карточка показала ответ утилиты")
    DashboardLive.perform(.awake, askStash: {})
    check(await until(2) { !model.isActive }, "кнопка карточки: повторное нажатие выключает")

    let menu = AwakeMenuToggle(model: model)
    menu.isOn.wrappedValue = false
    check(!model.isActive && model.actionError == nil, "пункт меню: то же значение ничего не меняет")
    menu.isOn.wrappedValue = true
    check(await until(2) { model.isActive }, "пункт меню: утилита включилась")
    check(await holdsAssertion(pid: utility), "пункт меню: assertion у процесса утилиты")
    check(!(await holdsAssertion(pid: stand)) && !AwakeController.shared.isActive, "пункт меню: у центра assertion нет, контроллер не тронут")
    menu.isOn.wrappedValue = false
    check(await until(2) { !model.isActive }, "пункт меню: выключает")

    // Статус меняет сама утилита: карточка узнаёт без чтения от стенда. Дожидаемся каждого шага: два сигнала подряд сливаются в один.
    check(await until(2.5) { slot.state.actionTitle == "Не спать" }, "карточка показала выключение")
    kill(utility, SIGUSR1)
    check(await until(2.5) { slot.state.actionTitle == "Можно спать" }, "statusChanged: карточка увидела включение")
    kill(utility, SIGUSR1)
    check(await until(2.5) { slot.state.actionTitle == "Не спать" }, "statusChanged: и выключение")

    // Встроенный при этом ни при чём: `canStart` у него проверяет кнопка, как на экране модуля.
    modules.setExternal(.awake, false)
    AwakeController.shared.canStart = false
    check(await until(2.5) { slot.state == DashState(text: "можно спать") }, "включить нельзя: у карточки нет действия")
    AwakeController.shared.canStart = true
    modules.setExternal(.awake, true)
    check(await until(2.5) { slot.state == expectedCard(pinnedStates[0]) }, "после возврата утилите снова её состояние")

    // Выключенная утилита: тумблер карточки идёт в реестр, настройка встроенного остаётся.
    let keyBefore = UserDefaults.standard.bool(forKey: ModuleManager.onKey(.awake))
    DashboardLive.setOn(.awake, false)
    check(await until(2.5) { registry.entries[.awake]?.status?.enabled == false }, "«Выключить модуль» на карточке выключает утилиту")
    let offStatus = try? await other.status()
    check(offStatus?.enabled == false, "утилита сама говорит, что выключена")
    check(await until(2.5) { slot.state == DashState(on: false, text: "выключен") }, "карточка выключенной утилиты «\(slot.state.text)»")
    check(UserDefaults.standard.bool(forKey: ModuleManager.onKey(.awake)) == keyBefore && modules.enabled.contains(.awake), "настройка встроенного не тронута")
    Stand.save(await Stand.open(.dusk, .dashboard), "dash-dusk-off-remote")
    let menuOff = await Stand.menuItem(AwakeMenuItem())
    modules.setExternal(.awake, false)
    modules.setOn(.awake, false)
    let menuBuiltInOff = await Stand.menuItem(AwakeMenuItem())
    check(differingPixels(menuOff, menuBuiltInOff) == 0, "выключенный модуль: в меню пункта нет, как у встроенного")
    modules.setOn(.awake, true)
    modules.setExternal(.awake, true)
    DashboardLive.setOn(.awake, true)
    check(await until(2.5) { registry.entries[.awake]?.status?.enabled == true }, "«Включить» на карточке включает утилиту")
    check(await until(2.5) { slot.state == expectedCard(pinnedStates[0]) }, "карточка снова как у встроенного")
}

/// Зависшая утилита: как вкладка, карточка и меню говорят «не отвечает». Узнают сами, без открытой вкладки.
@MainActor func cardHung(utility: Int32) async {
    let model = RemoteAwakeModel.shared
    let registry = SatelliteRegistry.shared
    let slot = DashboardLive.slot(.awake)
    await drive(pinnedStates[0])
    await model.read()
    await registry.update()
    let make = Stand.page(.dusk)
    let container = Stand.container()
    container.show(.dashboard, animated: false, make: make)
    await pause(0.3)
    let known = Stand.snapshot(container)
    let knownMenu = await Stand.menuItem(AwakeMenuItem())
    let notResponding = DashState(text: "не отвечает", attention: true)

    // Реестр услышал: статус пропал, модель перечитала сама, хотя вкладка не открыта.
    kill(utility, SIGSTOP)
    await registry.update()
    // Первый сбой чтения терпится, второе чтение идёт сразу: два срока по 2 с.
    check(await until(5) { !model.responding }, "зависла: реестр не слышит, модель перечитала без вкладки")
    check(model.screen(registry) == .notResponding, "зависла: вердикт тот же, что у вкладки")
    let hungMenu = await Stand.menuItem(AwakeMenuItem())
    check(differingPixels(knownMenu, hungMenu) > 0, "зависла: пункт меню другой")
    Stand.save(hungMenu, "menu-not-responding")
    let page = Stand.container()
    page.show(.dashboard, animated: false, make: make)
    check(await until(2.5) { slot.state == notResponding }, "зависла: карточка «\(slot.state.text)»")
    await pause(0.2)
    let hungShot = Stand.snapshot(page)
    Stand.save(hungShot, "dash-dusk-not-responding")
    check(differingPixels(known, hungShot) > 0, "зависла: на дашборде это видно")
    kill(utility, SIGCONT)
    await registry.update()
    check(await until(3) { model.responding }, "ожила: реестр слышит, модель перечитала без вкладки")
    check(await until(2.5) { slot.state == expectedCard(pinnedStates[0]) }, "ожила: карточка как была")
    await pause(0.2)
    check(differingPixels(known, Stand.snapshot(page)) == 0, "ожила: дашборд совпал с прежним снимком")

    // Зависла, пока дашборд закрыт: при открытии перечитывается, как вкладка.
    page.show(.about, animated: false, make: make)
    await pause(0.2)
    kill(utility, SIGSTOP)
    page.show(.dashboard, animated: false, make: make)
    check(await until(5) { slot.state == notResponding }, "зависла при закрытом дашборде: при открытии карточка «не отвечает»")
    kill(utility, SIGCONT)
    await pause(0.3)
    await model.read()
    check(await until(2.5) { slot.state == expectedCard(pinnedStates[0]) }, "ожила после открытия")
}

@MainActor func hung(utility: Int32) async {
    let model = RemoteAwakeModel.shared
    await model.read()
    let before = model.state
    kill(utility, SIGSTOP)
    let ticks = TickWatch()
    let started = ProcessInfo.processInfo.systemUptime
    await model.perform(.setKeepDisplay(!before.keepDisplay))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 2.5, String(format: "зависшая утилита: действие сдалось за %.2f с, не больше 2,5", elapsed))
    check(ticks.maxGap <= 0.3, String(format: "зависшая утилита: простой главного потока %.3f с, не больше 0,3", ticks.maxGap))
    check(model.state == before, "зависшая утилита: прежнее состояние")
    check(model.actionError != nil, "зависшая утилита: короткий текст «\(model.actionError ?? "нет")»")
    let hungOpen = await Stand.open(.dusk)
    Stand.save(hungOpen, "dusk-action-failed")
    kill(utility, SIGCONT)
    // Сообщение могло дойти после разморозки: тогда утилита объявит об изменении, и центр покажет правду.
    await pause(0.5)
    let truth = LinkClient(id: moduleID)
    let fresh = try? await JSONDecoder().decode(AwakeState.self, from: truth.moduleState())
    check(await until(2) { fresh != nil && model.state == fresh }, "после разморозки центр показывает то же, что утилита")
    await model.perform(.setKeepDisplay(false))
    await model.read()
    check(model.actionError == nil && model.responding, "после разморозки ошибок нет")
}

/// Вкладка открывается мгновенно: ответа утилиты страница не ждёт, ни на кэшированном, ни на новом хосте.
@MainActor func tabs(utility: Int32) async {
    let model = RemoteAwakeModel.shared
    let registry = SatelliteRegistry.shared
    await drive(pinnedStates[1])
    await model.read()
    await registry.update()
    let make = Stand.page(.dusk)
    let warm = Stand.container()
    warm.show(.module(.awake), animated: false, make: make)
    await pause(0.5)
    let known = Stand.snapshot(warm)
    warm.show(.about, animated: false, make: make)
    await pause(0.3)

    kill(utility, SIGSTOP)
    let ticks = TickWatch()
    var started = ProcessInfo.processInfo.systemUptime
    warm.show(.module(.awake), animated: false, make: make)
    var shot = Stand.snapshot(warm)
    var elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 0.3, String(format: "кэш страниц: вкладка показана за %.3f с при зависшей утилите", elapsed))
    check(differingPixels(known, shot) == 0, "кэш страниц: последнее известное состояние, снимок совпал (\(differingPixels(known, shot)))")

    let cold = Stand.container()
    started = ProcessInfo.processInfo.systemUptime
    cold.show(.module(.awake), animated: false, make: make)
    await pause(0.25)
    shot = Stand.snapshot(cold)
    elapsed = ProcessInfo.processInfo.systemUptime - started
    check(elapsed <= 1, String(format: "новая страница: показана за %.3f с при зависшей утилите", elapsed))
    check(differingPixels(known, shot) == 0, "новая страница: последнее известное состояние, снимок совпал (\(differingPixels(known, shot)))")
    check(model.responding, "пока срок не вышел, запасной экран не показан")
    print(String(format: "     сборка новой страницы и снимок заняли главный поток на %.3f с: debug-сборка, связь тут ни при чём", ticks.maxGap))

    // Сборка страницы и снимки стенда позади: теперь главный поток только ждёт ответа.
    let waiting = TickWatch()
    // Срок двух чтений и опрос реестра выходят: только теперь запасной экран.
    check(await until(5) { !model.responding }, "утилита не отвечает: модель это увидела, один сбой чтения стерпев")
    check(await until(2.5) { registry.entries[.awake]?.status == nil }, "и реестр тоже")
    await pause(0.3)
    check(waiting.maxGap <= 0.3, String(format: "ожидание зависшей утилиты и смена экрана: простой главного потока %.3f с, не больше 0,3", waiting.maxGap))
    shot = Stand.snapshot(cold)
    Stand.save(shot, "dusk-not-responding")
    check(differingPixels(known, shot) > 0, "не отвечает: запасной экран виден")

    kill(utility, SIGCONT)
    // Ушли со вкладки и вернулись: страница перечитала и снова показывает экран модуля.
    cold.show(.about, animated: false, make: make)
    await pause(0.1)
    cold.show(.module(.awake), animated: false, make: make)
    check(await until(3) { model.responding }, "утилита ожила: при открытии вкладки экран модуля вернулся")
    await registry.update()
    await pause(0.5)
    check(differingPixels(known, Stand.snapshot(cold)) == 0, "экран модуля снова как был")
    await drive(pinnedStates[0])
}

// MARK: - Вход

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.awake, foreignAction: LinkWire.encoded(AwakeAction.toggle)) { utility in
                let stand = getpid()
                wirePure()
                await garbage()
                await button(stand: stand, utility: utility)
                await pixels()
                await hung(utility: utility)
                await tabs(utility: utility)
                await cardPixels()
                await cardActions(stand: stand, utility: utility)
                await cardHung(utility: utility)
                check(!(await holdsAssertion(pid: stand)), "за весь прогон у центра assertion не появился")
            }
        }
    }
}
