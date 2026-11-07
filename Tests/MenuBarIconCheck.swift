import AppKit
import SwiftUI
import ObjectiveC

// Значки модулей в строке меню: маршрутизация и настройка (чисто), закрытость связи для чужих, снимок раздела
// в двух темах на узкой ширине. Запуск: Tests/run-menu-icons-check.sh. Аргументы: рабочая папка, папка PNG.

let pngDir = URL(fileURLWithPath: CommandLine.arguments[2])
nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

@MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

@MainActor func snapshot(_ name: String, _ view: some View, theme: DSTheme, width: CGFloat) async -> NSBitmapImageRep {
    Kit.defaults.set(theme.rawValue, forKey: DSTheme.storageKey)
    let host0 = NSHostingView(rootView: view.environment(\.dsTint, theme.accent(.sound)).dsThemed().frame(width: width))
    let height = max(host0.fittingSize.height, 100)
    let root = ZStack { DSBackground(module: .sound); VStack { view.padding(DS.pagePadding); Spacer(minLength: 0) } }
        .environment(\.pageActive, true)
        .environment(\.dsTint, theme.accent(.sound))
        .dsThemed()
        .frame(width: width, height: height + DS.pagePadding * 2)
    let host = NSHostingView(rootView: root)
    let size = NSSize(width: width, height: height + DS.pagePadding * 2)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    await pause(0.5)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: pngDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    window.contentView = nil
    return rep
}

func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let x = a.bitmapData, let y = b.bitmapData else { return Int.max }
    var count = 0
    for i in 0..<(a.pixelsWide * a.pixelsHigh) where memcmp(x + i * 4, y + i * 4, 4) != 0 { count += 1 }
    return count
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

    print("== снимки раздела")
    let shared = ModuleMenuIcons.shared
    shared.tellUtility = { _, _ in }
    var shots: [NSBitmapImageRep] = []
    // Раздел настроек: модули без утилиты в нём не показаны, значок им рисовать некому.
    for m in Module.allCases { modules.setExternal(m, false) }
    let none = await snapshot("section-no-utility", MenuIconsSection(), theme: .dusk, width: 380)
    modules.setExternal(.fans, true)
    let one = await snapshot("section-one-utility", MenuIconsSection(), theme: .dusk, width: 380)
    // По высоте не сравнить: снимок не ниже 100 pt, и в них помещается одна строка.
    check(differing(one, none) > 0, "раздел: появилась утилита, появилась строка")
    modules.setOn(.fans, true); modules.setOn(.awake, true); modules.setOn(.stash, true)
    modules.setExternal(.awake, true); modules.setExternal(.stash, true)
    let three = await snapshot("section-three-utilities", MenuIconsSection(), theme: .dusk, width: 380)
    check(three.pixelsHigh > one.pixelsHigh, "раздел: три утилиты выше одной")
    for (name, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
        shared.set(.fans, false); defaults.removeObject(forKey: MenuBarIcon.key(.fans))
        let off = await snapshot("section-\(name)-off", MenuIconsSection(), theme: theme, width: 380)
        check(off.pixelsWide > 0, "раздел снят (\(name), все выключены)")
        shared.set(.fans, true); shared.set(.awake, true); shared.set(.stash, true)
        let on = await snapshot("section-\(name)-on", MenuIconsSection(), theme: theme, width: 380)
        check(on.pixelsHigh == off.pixelsHigh && on.pixelsWide == off.pixelsWide, "раздел \(name): включение не сдвигает раскладку")
        check(differing(on, off) > 0, "раздел \(name): переключатели видны")
        shots.append(on)
        shared.set(.fans, false)
        let ctrlOff = await snapshot("header-\(name)-off", DSModuleControls(module: .fans), theme: theme, width: 380)
        let ctrlOff2 = await snapshot("header-\(name)-off2", DSModuleControls(module: .fans), theme: theme, width: 380)
        check(differing(ctrlOff, ctrlOff2) == 0, "шапка \(name): выключенное состояние повторяется один в один")
        shared.set(.fans, true)
        let ctrlOn = await snapshot("header-\(name)-on", DSModuleControls(module: .fans), theme: theme, width: 380)
        check(ctrlOn.pixelsHigh == ctrlOff2.pixelsHigh && ctrlOn.pixelsWide == ctrlOff2.pixelsWide, "шапка \(name): включение не сдвигает раскладку")
    }
    check(differing(shots[0], shots[1]) > 0, "темы различаются")
    for m in [Module.fans, .awake, .stash] { modules.setExternal(m, false) }
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
    defaults.removeObject(forKey: DSTheme.storageKey)
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
