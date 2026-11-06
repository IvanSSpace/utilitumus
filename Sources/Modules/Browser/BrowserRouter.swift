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

    /// Пускаем только http/https и файлы .html: ссылка приходит от любого приложения,
    /// а схемы вроде `-flag://`, `javascript:`, `x-apple.systempreferences:` не должны
    /// ни попадать в аргументы браузера, ни открывать чужие обработчики.
    nonisolated static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return true
        case "file": return ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
        default: return false
        }
    }

    /// `forcePanel` — кнопка «Проверить»: показать панель в любом случае, без правил.
    func handle(_ url: URL, from source: NSRunningApplication?, forcePanel: Bool = false) {
        guard Self.isAllowed(url) else { return }
        let catalog = BrowserCatalog.shared
        // Настройки меняются в Utilitumus, а ссылки ведёт помощник: перечитываем на каждую ссылку.
        catalog.refresh()
        let forcePanel = forcePanel || url == BrowserHelper.testURL
        // Подпись браузера не из списка проверяется вне главного потока, поэтому решение асинхронное.
        Task { await decide(url, from: source, forcePanel: forcePanel) }
    }

    private func decide(_ url: URL, from source: NSRunningApplication?, forcePanel: Bool) async {
        let catalog = BrowserCatalog.shared
        if !forcePanel {
            guard !BrowserHelper.moduleDisabled else {
                await openInFallback(url, from: source)
                return
            }
            switch await BrowserRouting.route(rules: catalog.rules, url: url, sourceBundleID: source?.bundleIdentifier,
                                              installed: Set(catalog.browsers.map(\.id)), shown: catalog.pickerBrowsers.map(\.id),
                                              isTrusted: { await catalog.isTrusted($0) }) {
            case .open(let id, let isPrivate):
                if let browser = catalog.browser(id: id) { open(url, in: browser, private: isPrivate) }
                return
            case .fallback:
                await openInFallback(url, from: source)
                return
            case .panel:
                break
            }
        }
        guard !catalog.pickerBrowsers.isEmpty else { return }
        await showPanel(url, from: source, browsers: catalog.pickerBrowsers)
    }

    private func showPanel(_ url: URL, from source: NSRunningApplication?, browsers: [InstalledBrowser]) async {
        let catalog = BrowserCatalog.shared
        // Чтобы основной браузер не из списка был предвыбран уже при первой панели.
        if let main = catalog.fallbackID { _ = await catalog.isTrusted(main) }
        BrowserPicker.shared.show(url: url, source: source, browsers: browsers, keys: catalog.effectiveKeys,
                                  preselected: catalog.fallback?.id) { [weak self] browser, isPrivate, remember in
            if remember { self?.remember(url, browser: browser, isPrivate: isPrivate) }
            self?.open(url, in: browser, private: isPrivate)
        }
    }

    /// Правило из выбора в панели: «домен → этот браузер». У файла и ссылки без хоста правила нет.
    /// На приложение, которому нельзя верить, правило не сработало бы (см. `BrowserRouting`), поэтому его не пишем.
    private func remember(_ url: URL, browser: InstalledBrowser, isPrivate: Bool) {
        guard let host = BrowserRuleMatcher.host(of: url),
              let domain = BrowserRuleMatcher.normalizeDomain(host) else { return }
        Task {
            guard await BrowserCatalog.shared.isTrusted(browser.id) else { return }
            BrowserCatalog.shared.addRule(BrowserRule(kind: .domain, value: domain, browserID: browser.id,
                                                      isPrivate: isPrivate && browser.supportsPrivate))
        }
    }

    /// Основной браузер, а если не выбран — первый, которому можно верить (Utilitumus в списке нет).
    /// Основному верить нельзя или выбирать не из чего — панель: потерять ссылку нельзя, открыть молча тоже.
    func openInFallback(_ url: URL, from source: NSRunningApplication?) async {
        let catalog = BrowserCatalog.shared
        if let browser = await catalog.openTarget() {
            open(url, in: browser, private: false)
            return
        }
        let choices = catalog.pickerBrowsers.isEmpty ? catalog.browsers : catalog.pickerBrowsers
        guard !choices.isEmpty else {
            NSSound.beep()
            return
        }
        await showPanel(url, from: source, browsers: choices)
    }

    func open(_ url: URL, in browser: InstalledBrowser, private isPrivate: Bool) {
        // Стенд не открывает ссылки в настоящих браузерах автора.
        #if KIT_TEST_DEFAULTS
        if Kit.standRefuses("открыть ссылку в \(browser.name)") { return }
        #endif
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
        // Всегда полный URL со схемой (в том числе file:///…): аргумент не может
        // начаться с «-» и превратиться в флаг браузера. isAllowed уже проверен в handle.
        let target = url.absoluteString
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
              let url = URL(string: text),
              // Из Apple Event «открыть URL» — только веб-ссылки; file: приходит через application(_:open:).
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        return (url, pid)
    }
}
