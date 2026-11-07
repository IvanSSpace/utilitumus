import AppKit
import SwiftUI

// Вкладка «Браузер» в лаунчере: экран рисует центр из общего домена настроек, от утилиты только статус. Запуск: Tests/run-browser-remote-check.sh
// Каркас — SatelliteCheckKit.swift и SatelliteStandKit.swift. Настройки только в тестовом домене, браузер по умолчанию не меняется.
// Настоящей утилиты нет: вкладке нужен только её статус, его отдаёт стенд в том виде, как `BrowserModule`.

let probeURL = URL(string: "https://example.com")!
let ruleDomain = "example.com"
/// Есть на любом Mac: правило и основной браузер ссылаются на настоящую установленную программу.
let safari = "com.apple.Safari"

/// Что утилита ответила бы на опрос; nil — не отвечает. Опрос идёт не на главном потоке, но стенд меняет значение только между опросами.
nonisolated(unsafe) var utilityEnabled: Bool? = true

func utilityStatus() throws -> LinkStatus {
    guard let enabled = utilityEnabled else { throw LinkError.timeout }
    return LinkStatus(enabled: enabled, line: "Не браузер по умолчанию", needsSetup: 0,
                      setupSteps: [LinkSetupStep(id: "browser.default", title: "Браузер по умолчанию",
                                                 why: "Чтобы ссылки шли через выбор браузера; macOS попросит подтвердить",
                                                 icon: "globe", kind: .permission, buttonTitle: "Сделать основным", done: false)])
}

/// Каталог утилиты: отдельный объект на том же домене, как в её процессе. `BrowserCatalog.shared` у стенда читает вкладка центра.
@MainActor let utilityCatalog = BrowserCatalog(defaults: BrowserHelper.defaults)

/// Настоящий экран утилиты (`BrowserModule.windowRoot`) на её каталоге.
@MainActor func utilityScreen() -> BrowserView {
    var view = BrowserView()
    view.catalog = utilityCatalog
    return view
}

/// Вид утилиты в той же рамке, что страница центра: с ним сверяется вкладка.
/// Не `Stand.open`: страница модуля без утилиты опрашивает реестр, он видит бандл и передачу, и снимок выходил снимком самой вкладки.
@MainActor func openLocal(_ theme: DSTheme, @ViewBuilder _ content: @escaping () -> some View) async -> NSBitmapImageRep {
    let container = Stand.container()
    container.show(.module(.browser), animated: false) { _, active in
        AnyView(content()
            .environment(\.pageActive, active)
            .environment(\.dsTint, theme.accent(.browser))
            .environment(\.moduleControls, DSModuleControls.forEnvironment)
            .background(ZStack { DSBackground(module: .browser, neutral: false); theme.card })
            .dsThemed()
            .ignoresSafeArea())
    }
    await pause(0.5)
    return Stand.snapshot(container)
}

/// Сценарии задаёт утилита: пишет в общий домен, вкладка центра узнаёт оттуда, связи для этого нет.
@MainActor func apply(_ scene: String) {
    utilityCatalog.refresh()
    for rule in utilityCatalog.rules { utilityCatalog.removeRule(rule.id) }
    utilityCatalog.setFallback(nil)
    switch scene {
    case "rule": utilityCatalog.addRule(BrowserRule(kind: .domain, value: ruleDomain, browserID: safari))
    case "fallback": utilityCatalog.setFallback(safari)
    default: break
    }
}

@MainActor func pixels() async {
    let registry = SatelliteRegistry.shared
    let flow = SetupFlow.shared
    for (themeName, theme) in [("dusk", DSTheme.dusk), ("calm", DSTheme.calm)] {
        Kit.defaults.set(themeName, forKey: DSTheme.storageKey)
        await registry.update()
        check(registry.isEnabled(.browser), "\(themeName): реестр видит утилиту включённой")
        AccessState.shared.refresh()
        var shots: [NSBitmapImageRep] = []
        for scene in ["default", "rule", "fallback"] {
            apply(scene)
            // Шаг «браузер по умолчанию» приходит от утилиты: если он держит модуль, сперва сверяется он.
            if AccessState.shared.blocked.contains(.browser) {
                let local = await openLocal(theme) { ModuleScreen(module: .browser) { utilityScreen() } }
                Stand.save(local, "\(themeName)-\(scene)-steps-local")
                let remote = await Stand.open(theme)
                Stand.save(remote, "\(themeName)-\(scene)-steps-remote")
                let diff = differingPixels(local, remote)
                check(diff == 0, "\(themeName) \(scene), шаги настройки: снимки совпали, разных пикселей \(diff)")
            }
            flow.postpone(.browser)
            let local = await openLocal(theme) { ModuleScreen(module: .browser) { utilityScreen() } }
            Stand.save(local, "\(themeName)-\(scene)-local")
            let remote = await Stand.open(theme)
            Stand.save(remote, "\(themeName)-\(scene)-remote")
            let diff = differingPixels(local, remote)
            check(diff == 0, "\(themeName) \(scene): снимки совпали, разных пикселей \(diff) из \(local.pixelsWide * local.pixelsHigh)")
            check(BrowserCatalog.shared.rules == utilityCatalog.rules && BrowserCatalog.shared.fallbackID == utilityCatalog.fallbackID, "\(themeName) \(scene): вкладка и утилита читают одно и то же")
            shots.append(remote)
            // `show` снимает отложенность, `finish` закрывает принудительный показ: как было до сценария.
            flow.show(.browser)
            flow.finish(.browser)
        }
        check(differingPixels(shots[0], shots[1]) > 0 && differingPixels(shots[0], shots[2]) > 0, "\(themeName): сценарии выглядят по-разному, снимки не пустые")
    }
    apply("default")
    Kit.defaults.set("dusk", forKey: DSTheme.storageKey)
}

/// Два других экрана вкладки выбирает статус утилиты: выключена и не отвечает.
@MainActor func otherScreens() async {
    let registry = SatelliteRegistry.shared
    SetupFlow.shared.postpone(.browser)
    let screen = await Stand.open(.dusk)

    let localOff = await openLocal(.dusk) { ModuleOffView(module: .browser) {} more: {} }
    Stand.save(localOff, "dusk-off-local")
    utilityEnabled = false
    await registry.update()
    check(registry.entries[.browser]?.status?.enabled == false, "реестр знает, что утилита выключена")
    let remoteOff = await Stand.open(.dusk)
    Stand.save(remoteOff, "dusk-off-remote")
    var diff = differingPixels(localOff, remoteOff)
    check(diff == 0, "выключенный модуль: снимки совпали, разных пикселей \(diff)")
    check(differingPixels(screen, remoteOff) > 0, "выключенный модуль: это другой экран")
    // Кнопка «Включить» на этом экране.
    registry.setEnabled(.browser, true)
    check(await until(3) { registry.entries[.browser]?.status?.enabled == true }, "«Включить» дошло до утилиты")

    utilityEnabled = nil
    await registry.update()
    check(await until(5) { registry.entries[.browser]?.status == nil }, "не отвечает: реестр не слышит")
    let localHung = await openLocal(.dusk) { SatellitePage(module: .browser) }
    Stand.save(localHung, "dusk-not-responding-local")
    let remoteHung = await Stand.open(.dusk)
    Stand.save(remoteHung, "dusk-not-responding-remote")
    diff = differingPixels(localHung, remoteHung)
    check(diff == 0, "не отвечает: запасной экран, разных пикселей \(diff)")
    check(differingPixels(screen, remoteHung) > 0, "не отвечает: это другой экран")
    utilityEnabled = true
    await registry.update()
    check(await until(4) { registry.entries[.browser]?.status != nil }, "ожила: реестр слышит")
    let back = await Stand.open(.dusk)
    diff = differingPixels(screen, back)
    check(diff == 0, "ожила: экран как был, разных пикселей \(diff)")
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            ModuleCheck.main(.browser, foreignAction: Data()) { _ in
                // До первого обращения к реестру: он берёт окружение один раз.
                SatelliteRegistry.standEnvironment?.commands.status = { _ in try utilityStatus() }
                SatelliteRegistry.standEnvironment?.commands.setEnabled = { _, on in utilityEnabled = on }
                let defaultBefore = NSWorkspace.shared.urlForApplication(toOpen: probeURL)
                await pixels()
                await otherScreens()
                check(NSWorkspace.shared.urlForApplication(toOpen: probeURL) == defaultBefore, "браузер по умолчанию не менялся: \(defaultBefore?.lastPathComponent ?? "нет")")
            }
        }
    }
}
