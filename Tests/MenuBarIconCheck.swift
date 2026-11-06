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
    UserDefaults.standard.set(theme.rawValue, forKey: DSTheme.storageKey)
    let host0 = NSHostingView(rootView: view.environment(\.dsTint, theme.accent(.sound)).dsThemed().frame(width: width))
    let height = max(host0.fittingSize.height, 100)
    let root = ZStack { DSBackground(module: .sound, neutral: true); VStack { view.padding(DS.pagePadding); Spacer(minLength: 0) } }
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

    check(MenuBarIcon.utilityShows(setting: nil, hubRunning: false, active: true), "утилита по умолчанию: центра нет — значок есть")
    check(!MenuBarIcon.utilityShows(setting: nil, hubRunning: true, active: true), "утилита по умолчанию: центр запущен — значка нет")
    check(!MenuBarIcon.utilityShows(setting: nil, hubRunning: true, active: false), "утилита по умолчанию: пассивная при центре — нет")
    check(MenuBarIcon.utilityShows(setting: true, hubRunning: true, active: true), "«да»: значок есть и при центре")
    check(!MenuBarIcon.utilityShows(setting: true, hubRunning: true, active: false), "«да», но модуль встроенный: утилита не рисует")
    check(!MenuBarIcon.utilityShows(setting: false, hubRunning: false, active: true), "«нет»: значка нет и без центра")
    check(MenuBarIcon.utilityShows(setting: true, hubRunning: false, active: true), "«да» без центра: есть")
    check(MenuBarIcon.utilityUsesMenu(hubRunning: true) && !MenuBarIcon.utilityUsesMenu(hubRunning: false), "меню при центре, окно без него")

    check(MenuBarIcon.hubShows(setting: true, external: false, moduleOn: true), "встроенный: «да» — рисует центр")
    check(!MenuBarIcon.hubShows(setting: nil, external: false, moduleOn: true), "встроенный: по умолчанию значка нет")
    check(!MenuBarIcon.hubShows(setting: false, external: false, moduleOn: true), "встроенный: «нет» — нет")
    check(!MenuBarIcon.hubShows(setting: true, external: true, moduleOn: true), "ведёт утилита: центр не рисует")
    check(!MenuBarIcon.hubShows(setting: true, external: false, moduleOn: false), "модуль выключен: значка нет")
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

    print("== центр: кто рисует и что говорит утилите")
    let modules = ModuleManager.shared
    var told: [String] = []
    let icons = ModuleMenuIcons(modules: modules, satellites: .shared, defaults: defaults)
    icons.makeItem = { _ in nil }
    icons.tellUtility = { m, on in told.append("\(m.rawValue) \(on)") }
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
    icons.set(.fans, false); defaults.removeObject(forKey: MenuBarIcon.key(.fans))
    told = []
    modules.setOn(.fans, true); modules.setOn(.awake, true); modules.setOn(.load, true)
    modules.setExternal(.load, true)
    icons.set(.fans, true); icons.set(.load, true)
    check(icons.isOn(.fans) && icons.isOn(.load) && !icons.isOn(.awake), "переключатели читают сохранённое")
    check(icons.wanted == [.fans], "центр рисует значок только встроенного модуля с «да»")
    check(told == ["load true"], "утилите сказано про её модуль, встроенному не нужно (\(told))")
    icons.set(.load, false)
    check(told == ["load true", "load false"], "выключение тоже уходит утилите")
    modules.setOn(.fans, false)
    check(icons.wanted.isEmpty, "модуль выключили — значка нет")
    modules.setOn(.fans, true)
    modules.setExternal(.fans, true)
    check(icons.wanted.isEmpty, "модуль передан утилите — центр не рисует")
    modules.setExternal(.fans, false); modules.setExternal(.load, false)
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
    icons.set(.fans, false); defaults.removeObject(forKey: MenuBarIcon.key(.fans))

    print("== снимки раздела")
    var shots: [NSBitmapImageRep] = []
    for (name, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
        icons.set(.fans, false); defaults.removeObject(forKey: MenuBarIcon.key(.fans))
        let off = await snapshot("section-\(name)-off", MenuIconsSection(), theme: theme, width: 380)
        check(off.pixelsWide > 0, "раздел снят (\(name), все выключены)")
        icons.set(.fans, true); icons.set(.awake, true); icons.set(.stash, true)
        let on = await snapshot("section-\(name)-on", MenuIconsSection(), theme: theme, width: 380)
        check(on.pixelsHigh == off.pixelsHigh && on.pixelsWide == off.pixelsWide, "раздел \(name): включение не сдвигает раскладку")
        check(differing(on, off) > 0, "раздел \(name): переключатели видны")
        shots.append(off)
        let ctrlOff = await snapshot("header-\(name)-off", DSModuleControls(module: .fans), theme: theme, width: 380)
        icons.set(.fans, false)
        let ctrlOff2 = await snapshot("header-\(name)-off2", DSModuleControls(module: .fans), theme: theme, width: 380)
        check(differing(ctrlOff, ctrlOff2) >= 0 && ctrlOff.pixelsWide == ctrlOff2.pixelsWide, "шапка \(name): размер один")
        icons.set(.fans, true)
        let ctrlOn = await snapshot("header-\(name)-on", DSModuleControls(module: .fans), theme: theme, width: 380)
        check(ctrlOn.pixelsHigh == ctrlOff2.pixelsHigh && ctrlOn.pixelsWide == ctrlOff2.pixelsWide, "шапка \(name): включение не сдвигает раскладку")
    }
    check(differing(shots[0], shots[1]) > 0, "темы различаются")
    for m in Module.allCases { defaults.removeObject(forKey: MenuBarIcon.key(m)) }
}

await run()
print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
