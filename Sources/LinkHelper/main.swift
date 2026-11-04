import AppKit

/// «Utilitumus Links» — браузер по умолчанию для macOS: принимает ссылки и показывает панель выбора.
/// Без окна и значка в Dock (LSUIElement), поэтому, когда macOS активирует его ради ссылки,
/// на экране появляется только панель. Настройки — общие с Utilitumus (`BrowserHelper.defaults`).
final class LinksDelegate: NSObject, NSApplicationDelegate {
    /// «will»: ссылка, которой помощник запустили с нуля, приходит сразу после запуска.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        MainActor.assumeIsolated {
            // Отмена и выбор — прячемся: фокус возвращается туда, где кликнули по ссылке.
            BrowserPicker.shared.onDismiss = { NSApp.hide(nil) }
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            guard let link = BrowserLinkEvent.parse(event) else { return }
            let router = BrowserRouter.shared
            router.handle(link.url, from: router.sourceApplication(pid: link.senderPID))
        }
    }

    /// Файлы .html из Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.isFileURL || url.scheme == "http" || url.scheme == "https" {
                BrowserRouter.shared.handle(url, from: nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = LinksDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
