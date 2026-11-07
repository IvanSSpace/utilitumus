import AppKit
import SwiftUI
import ObjectiveC

// Значки модулей в строке меню: маршрутизация и настройка (чисто), закрытость связи для чужих.
// Запуск: Tests/run-menu-icons-check.sh. Аргумент: рабочая папка.

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func hasSelector(_ proto: Protocol, _ name: String) -> Bool {
    protocol_getMethodDescription(proto, NSSelectorFromString(name), true, true).name != nil
}

@MainActor func run() async {
    let defaults = Kit.defaults
    let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
    let appsDir = workRoot.appendingPathComponent("Apps")
    try? FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
    let paths = SatellitePaths(appsDir: appsDir, agentsDir: workRoot.appendingPathComponent("Agents"))
    SatelliteRegistry.standEnvironment = SatelliteEnvironment(
        paths: paths, defaults: Kit.defaults,
        installer: SatelliteInstaller(paths: paths, launchctl: { _ in }, download: { $0 }, verify: { _, _ in }),
        commands: SatelliteCommands(status: { _ in throw LinkError.timeout }, setEnabled: { _, _ in }, openWindow: { _ in }),
        loadCatalog: { Data(#"{"schema":1,"apps":[]}"#.utf8) },
        hubVersion: "0.6.0", modules: .shared)
    let quick = LinkQuickAction(title: "Обновить", icon: "arrow.clockwise", action: Data("{}".utf8))
    let many = (1...6).map { LinkQuickAction(title: "A\($0)", action: Data()) }

    print("== настройка и маршрутизация")
    check(MenuBarIcon.key(.fans) == "MenuBarIcon.fans", "ключ MenuBarIcon.<id>")
    defaults.removeObject(forKey: MenuBarIcon.key(.fans))
    check(MenuBarIcon.setting(.fans) == nil, "ключа нет: настройка не задана")
    MenuBarIcon.set(true, .fans)
    check(MenuBarIcon.setting(.fans) == true, "включено сохраняется")
    MenuBarIcon.set(false, .fans)
    check(MenuBarIcon.setting(.fans) == false, "выключено сохраняется явным false")
    defaults.removeObject(forKey: MenuBarIcon.key(.fans))

    check(!MenuBarIcon.utilityShows(setting: nil, hubRunning: false, active: true), "утилита не закреплена, центр закрыт: значка нет, в строке меню только закреплённые")
    check(!MenuBarIcon.utilityShows(setting: nil, hubRunning: true, active: true), "утилита по умолчанию: центр запущен — значка нет")
    check(!MenuBarIcon.utilityShows(setting: nil, hubRunning: true, active: false), "утилита по умолчанию: пассивная при центре — нет")
    check(MenuBarIcon.utilityShows(setting: true, hubRunning: true, active: true), "«да»: значок есть и при центре")
    check(!MenuBarIcon.utilityShows(setting: true, hubRunning: true, active: false), "«да», но модуль ей не передан: утилита не рисует")
    check(!MenuBarIcon.utilityShows(setting: false, hubRunning: false, active: true), "«нет»: значка нет и без центра")
    check(MenuBarIcon.utilityShows(setting: true, hubRunning: false, active: true), "«да» без центра: есть")
    check(MenuBarIcon.utilityUsesMenu(hubRunning: true) && !MenuBarIcon.utilityUsesMenu(hubRunning: false), "меню при центре, окно без него")

    check(!MenuBarIcon.switchOn(nil) && !MenuBarIcon.switchOn(false) && MenuBarIcon.switchOn(true), "переключатель включён только явным «да»")

    print("== состав меню")
    check(MenuBarIcon.entries(status: "", actions: []) == [.open, .hide], "пусто: только «Открыть» и «Скрыть»")
    check(MenuBarIcon.entries(status: "память 8 ГБ", actions: [quick])
          == [.status("память 8 ГБ"), .separator, .action(quick), .separator, .open, .hide], "статус, действие, открыть, скрыть")
    check(MenuBarIcon.entries(status: "  ", actions: [quick]) == [.action(quick), .separator, .open, .hide], "пустая строка статуса не рисуется")
    check(MenuBarIcon.entries(status: "x", actions: many).filter { if case .action = $0 { true } else { false } }.count == 4, "не больше четырёх действий")

    print("== просьба открыть модуль")
    defaults.removeObject(forKey: MenuBarIcon.openKey)
    check(MenuBarIcon.takeOpenRequest() == nil, "просьбы нет")
    MenuBarIcon.requestOpen(.load, hub: nil)
    check(MenuBarIcon.takeOpenRequest() == .load, "просьба читается")
    check(MenuBarIcon.takeOpenRequest() == nil, "и снимается")
    defaults.set("rm -rf", forKey: MenuBarIcon.openKey)
    check(MenuBarIcon.takeOpenRequest() == nil && defaults.string(forKey: MenuBarIcon.openKey) == nil, "неизвестный id отброшен и снят")

    print("== связь: чужой не переключит")
    check(hasSelector(LinkXPC.self, "setMenuIcon:reply:"), "служба центра принимает setMenuIcon")
    check(!hasSelector(LinkSelfXPC.self, "setMenuIcon:reply:"), "служба копии из Finder не принимает")
    check(!hasSelector(LinkPingXPC.self, "setMenuIcon:reply:"), "обратный канал не принимает")
    let specs = LinkServer.specs(id: "x", hubIdentifier: Kit.hubBundleID)
    let hubSpec = specs.first { $0.role == .hub }!, selfSpec = specs.first { $0.role == .selfCopy }!
    check(hubSpec.requirement == KitLink.requirement(identifier: Kit.hubBundleID), "служба центра: только подпись центра")
    check(!hubSpec.requirement.contains("local.utilitumus.app.x\"") && selfSpec.service != hubSpec.service, "копия утилиты слушает другую службу")
    let lookalike = KitLink.requirement(identifier: "local.utilitumus.fake")
    check(hubSpec.requirement != lookalike, "требование не пускает подделку с другим identifier")

    print("== центр: значки рисует утилита, центр только говорит ей")
    let modules = ModuleManager.shared
    var told: [String] = []
    let icons = ModuleMenuIcons(modules: modules, satellites: .shared, defaults: defaults)
    icons.tellUtility = { m, on in told.append("\(m.rawValue) \(on)") }
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
    modules.setOn(.fans, true); modules.setOn(.awake, true); modules.setOn(.load, true)
    modules.setExternal(.load, true)
    check(modules.wantsUtility(.fans) && modules.isExternal(.load), "до проверки: у «Вентиляторов» утилиты нет, «Нагрузку» ведёт она")
    icons.set(.fans, true); icons.set(.load, true)
    check(icons.isOn(.fans) && icons.isOn(.load) && !icons.isOn(.awake), "переключатели читают сохранённое")
    check(MenuBarIcon.setting(.fans) == true, "модуль без утилиты: настройка записана, утилита прочитает её при запуске")
    check(told == ["load true"], "сказано только утилите, модулю без неё говорить некому (\(told))")
    icons.set(.load, false)
    check(told == ["load true", "load false"], "выключение тоже уходит утилите")
    icons.clear(.fans)
    check(told == ["load true", "load false"] && MenuBarIcon.setting(.fans) == nil, "снятие у модуля без утилиты: только ключ")

    print("== меню: переключатели только у модулей с утилитой")
    check(AppMenuBarScene.switchable(modules) == modules.order.filter { $0 == .load }, "включён без утилиты и не установлен: переключателя нет, только «Нагрузка»")
    modules.setExternal(.fans, true)
    check(Set(AppMenuBarScene.switchable(modules)) == [.load, .fans], "утилита появилась: переключатель появился")
    modules.setExternal(.fans, false); modules.setExternal(.load, false)
    check(AppMenuBarScene.switchable(modules).isEmpty, "утилит нет: переключателей нет")
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
    defaults.removeObject(forKey: DSTheme.storageKey)
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
