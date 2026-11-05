import AppKit

// Точка входа утилиты «Не спать». Работает только копия, запущенная launchd:
// запуск из Finder просит её показать окно и выходит.

final class AwakeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AwakeSatellite.shared.run() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AwakeController.shared.stop() }
    }
}

let awakeDelegate = AwakeAppDelegate()

MainActor.assumeIsolated {
    if AwakeSatellite.currentMode() == .forwardAndExit { forwardOpenWindowAndExit() }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = awakeDelegate
    app.run()
}
