import AppKit

/// Принимает ссылки (Apple Event «открыть URL» и файлы .html) и решает, куда их вести:
/// по правилу сразу в браузер, иначе панель выбора у курсора. Модуль выключен или нечего
/// выбирать — ссылка уходит в основной браузер, потерять её нельзя.
@MainActor
final class BrowserRouter {
    static let shared = BrowserRouter()

    /// Приложение-источник по PID отправителя Apple Event. Себя (и Utilitumus) и пустой PID отбрасываем.
    func sourceApplication(pid: pid_t?) -> NSRunningApplication? {
        guard let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid),
              !BrowserKnown.isRouter(app.bundleIdentifier ?? "") else { return nil }
        return app
    }

    /// `forcePanel` — кнопка «Проверить»: показать панель в любом случае, без правил.
    func handle(_ url: URL, from source: NSRunningApplication?, forcePanel: Bool = false) {
        let catalog = BrowserCatalog.shared
        // Настройки меняются в Utilitumus, а ссылки ведёт помощник: перечитываем на каждую ссылку.
        catalog.refresh()
        let forcePanel = forcePanel || url == BrowserHelper.testURL

        if !forcePanel {
            guard !BrowserHelper.moduleDisabled else {
                openInFallback(url)
                return
            }
            let available = Set(catalog.browsers.map(\.id))
            let usable = catalog.rules.filter { available.contains($0.browserID) }
            if let rule = BrowserRuleMatcher.firstMatch(rules: usable, host: BrowserRuleMatcher.host(of: url),
                                                         sourceBundleID: source?.bundleIdentifier),
               let browser = catalog.browser(id: rule.browserID) {
                open(url, in: browser, private: rule.isPrivate)
                return
            }
        }

        let choices = catalog.pickerBrowsers
        // Выбирать не из чего: панель с одной иконкой — лишний клик.
        if !forcePanel && choices.count < 2 {
            if let only = choices.first { open(url, in: only, private: false) } else { openInFallback(url) }
            return
        }
        guard !choices.isEmpty else { return }
        BrowserPicker.shared.show(url: url, source: source, browsers: choices, keys: catalog.effectiveKeys,
                                  preselected: catalog.fallbackID) { [weak self] browser, isPrivate, remember in
            if remember { self?.remember(url, browser: browser, isPrivate: isPrivate) }
            self?.open(url, in: browser, private: isPrivate)
        }
    }

    /// Правило из выбора в панели: «домен → этот браузер». У файла и ссылки без хоста правила нет.
    private func remember(_ url: URL, browser: InstalledBrowser, isPrivate: Bool) {
        guard let host = BrowserRuleMatcher.host(of: url),
              let domain = BrowserRuleMatcher.normalizeDomain(host) else { return }
        BrowserCatalog.shared.addRule(BrowserRule(kind: .domain, value: domain, browserID: browser.id,
                                                  isPrivate: isPrivate && browser.supportsPrivate))
    }

    /// Основной браузер, а если не выбран — первый найденный (Utilitumus в списке нет).
    func openInFallback(_ url: URL) {
        guard let browser = BrowserCatalog.shared.openTarget else {
            NSSound.beep()
            return
        }
        open(url, in: browser, private: false)
    }

    func open(_ url: URL, in browser: InstalledBrowser, private isPrivate: Bool) {
        if isPrivate, let flags = BrowserPrivateMode.arguments(for: browser.id) {
            openPrivately(url, in: browser, flags: flags)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: configuration) { _, error in
            if let error { NSLog("Utilitumus: не открылось в %@: %@", browser.name, error.localizedDescription) }
        }
    }

    /// Запущенному браузеру аргументы через NSWorkspace не передать (он их игнорирует),
    /// поэтому `open -na`: новый экземпляр сам передаёт команду уже работающему.
    /// Не запущенный стартует с аргументами напрямую.
    private func openPrivately(_ url: URL, in browser: InstalledBrowser, flags: [String]) {
        let target = url.isFileURL ? url.path : url.absoluteString
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).isEmpty
        if running {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", browser.url.path, "--args"] + flags + [target]
            do { try process.run() } catch { NSLog("Utilitumus: open не запустился: %@", error.localizedDescription) }
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.arguments = flags + [target]
            NSWorkspace.shared.openApplication(at: browser.url, configuration: configuration) { _, error in
                if let error { NSLog("Utilitumus: не запустился %@: %@", browser.name, error.localizedDescription) }
            }
        }
    }
}

/// Разбор Apple Event `GURL`.
enum BrowserLinkEvent {
    static func parse(_ event: NSAppleEventDescriptor) -> (url: URL, senderPID: pid_t?)? {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return nil }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        return (url, pid)
    }
}
