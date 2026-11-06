import AppKit
import SwiftUI

// Экран модуля на стенде: настоящий `ModuleDetail` через настоящий `PageContainer`, окно за экраном и прозрачное,
// снимки через cacheDisplay. Собирается только с исходниками центра (`build_module_hub`).

@MainActor enum Stand {
    static var out = ""
    /// Модуль стенда: его фон у дашборда.
    static var module = Module.sound

    static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 738, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    /// Корень страницы как в `MainView`: окружение задаётся на странице, через границу хостинга оно не проходит.
    static func page(_ theme: DSTheme) -> (PageKey, Bool) -> AnyView {
        { key, active in
            if key == .dashboard {
                return AnyView(DashboardPage(open: { _ in }).equatable()
                    .environment(\.pageActive, active)
                    .background(ZStack { DSBackground(module: Stand.module, neutral: false); theme.card })
                    .dsThemed()
                    .ignoresSafeArea())
            }
            guard case .module(let module) = key else { return AnyView(Color.black) }
            return AnyView(ModuleDetail(module: module)
                .environment(\.pageActive, active)
                .environment(\.dsTint, theme.accent(module))
                .environment(\.moduleControls, DSModuleControls.forEnvironment)
                // Подложка как в окне: фон модуля и карточка страницы, иначе снимок полупрозрачный.
                .background(ZStack { DSBackground(module: module, neutral: false); theme.card })
                .dsThemed()
                .ignoresSafeArea())
        }
    }

    static func container() -> PageContainer {
        let container = PageContainer(frame: NSRect(x: 0, y: 0, width: 738, height: 660))
        window.contentView = container
        return container
    }

    /// Новая страница: как первое открытие вкладки.
    static func open(_ theme: DSTheme, _ key: PageKey? = nil) async -> NSBitmapImageRep {
        let container = container()
        container.show(key ?? .module(module), animated: false, make: page(theme))
        await pause(0.5)
        return snapshot(container)
    }

    /// Своё окно: вид с хостингом подогнал бы под себя размер окна страницы.
    static let menuWindow: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 700, width: 240, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return window
    }()

    /// Настоящий пункт меню-бара в обычном окне: само меню рисует система, за экраном его не снять.
    static func menuItem(_ item: some View) async -> NSBitmapImageRep {
        let host = NSHostingView(rootView: item.frame(width: 240, height: 40).dsThemed())
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        menuWindow.contentView = host
        await pause(0.3)
        return snapshot(host)
    }

    static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, _ name: String) {
        let path = out + "/png/" + name + ".png"
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Реестр центра смотрит на утилиту стенда, модуль передан ей. Настройки — suite стенда.
    static func connect(_ module: Module, id: String, out: String) {
        Stand.module = module
        Stand.out = out
        let link = { @MainActor @Sendable () in LinkClient(id: id) }
        SatelliteRegistry.standEnvironment = SatelliteEnvironment(
            paths: SatellitePaths(appsDir: URL(fileURLWithPath: out), agentsDir: URL(fileURLWithPath: out + "/agents")),
            defaults: Kit.defaults,
            installer: SatelliteInstaller(paths: SatellitePaths(appsDir: URL(fileURLWithPath: out), agentsDir: URL(fileURLWithPath: out + "/agents")),
                                          launchctl: { _ in }, download: { $0 }, verify: { _, _ in }),
            commands: SatelliteCommands(
                status: { _ in try await link().status() },
                setEnabled: { _, on in try await link().setEnabled(on) },
                openWindow: { _ in }),
            loadCatalog: { Data(#"{"schema":1,"apps":[]}"#.utf8) },
            hubVersion: "0.6.0",
            modules: .shared)
        Kit.defaults.set(true, forKey: ModuleHandover.handedOverKey(module.rawValue))
        ModuleManager.shared.setExternal(module, true)
    }

    /// Простой для замера: экран открыт, ничего не происходит.
    static func idle(_ module: Module, id: String, out: String, key: PageKey) async {
        connect(module, id: id, out: out)
        await SatelliteRegistry.shared.update()
        _ = await open(.dusk, key)
        print("готов")
        fflush(stdout)
    }
}

/// Сколько пикселей отличается; размер не совпал — все.
func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          a.bitsPerPixel == b.bitsPerPixel, let pa = a.bitmapData, let pb = b.bitmapData else {
        return max(a.pixelsWide * a.pixelsHigh, b.pixelsWide * b.pixelsHigh)
    }
    let pixelBytes = a.bitsPerPixel / 8
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            let offset = y * a.bytesPerRow + x * pixelBytes
            if memcmp(pa + offset, pb + offset, pixelBytes) != 0 { count += 1 }
        }
    }
    return count
}

/// Вход проверки модуля: настройки стенда, общие роли, затем `run <папка> <pid утилиты>` и `idle`/`idle-dashboard <папка>`.
@MainActor enum ModuleCheck {
    static func main(_ module: Module, foreignAction: Data, run: @escaping @MainActor (_ utility: Int32) async -> Void) {
        let args = CommandLine.arguments
        let id = LinkIdentity.id(module.rawValue)
        // Иначе ModuleManager принял бы пустой домен за обновление и выключил модули.
        UserDefaults.standard.set(true, forKey: ModuleReset.flagKey)
        UserDefaults.standard.set(true, forKey: ModuleManager.onKey(module))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            if await runCommonRole(args[1], id: id, foreignAction: foreignAction) { return }
            switch args[1] {
            case "run":
                Stand.connect(module, id: id, out: args[2])
                await run(Int32(args[3])!)
                finish()
            case "idle":
                await Stand.idle(module, id: id, out: args[2], key: .module(module))
            case "idle-dashboard":
                await Stand.idle(module, id: id, out: args[2], key: .dashboard)
            default:
                fatalError("неизвестная роль")
            }
        }
        app.run()
    }
}
