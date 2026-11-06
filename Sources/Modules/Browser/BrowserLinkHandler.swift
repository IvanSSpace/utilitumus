import AppKit

// Кто открывает http и https. Ошибка здесь ломает ссылки на всём Mac, поэтому всё, что говорит с LaunchServices,
// лежит за `LinkLaunchServices`: проверки подставляют свою и никогда не регистрируют, не снимают и не назначают
// настоящий `local.utilitumus.links`, http и https. Сборка со швом `KIT_TEST_DEFAULTS` получает `.live`, который
// не делает ничего.
//
// Что известно о LaunchServices (docs/superpowers/specs/2026-11-06-link-handler-probe-result.md):
// • обработчик хранится как id, без пути; копий с этим id может быть несколько, ссылку получает одна;
// • порядок: запущенная копия, потом уже запускавшаяся через LaunchServices, потом больший CFBundleVersion, потом путь;
// • удалили выбранную копию при другой живой — ссылка сразу идёт другой, диалога нет;
// • удалили все копии — ссылка не открывается, запись обработчика остаётся, по API её не отличить от «не назначен».
//
// Откат (понижение версии), чтобы не потерять ссылки:
// • центр: помощник возвращается в центре, ссылки не теряются;
// • утилита при центре без помощника: копия одна, замена на месте;
// • если рядом осталась более новая копия, которую уже запускали, ссылки останутся у неё и после отката другой
//   (больший CFBundleVersion выигрывает). Откат обязан убрать или заменить такую копию, а не только поставить старую;
// • запущенный старый помощник получает ссылки раньше выбранного: перед заменой его останавливают (`stopHelpers`).

/// Всё, что обработчику ссылок нужно от системы.
struct LinkLaunchServices {
    /// `LSRegisterURL`. Назначения обработчика не меняет.
    var register: @Sendable (URL) -> Void
    /// Bundle id обработчика схемы или nil: не назначен либо копии нет (по API не различить).
    var defaultHandlerID: @Sendable (String) -> String?
    /// Все копии с этим bundle id, которые знает LaunchServices.
    var copies: @Sendable (String) -> [URL]
    /// Установленное приложение по bundle id.
    var appURL: @Sendable (String) -> URL?
    /// `setDefaultApplication`: macOS спрашивает подтверждение, отказ — ошибка (или тихо ничего не меняется).
    var setDefault: @Sendable (URL, String) async throws -> Void
    /// Остановить запущенные копии помощника внутри папки (старая копия получает ссылки раньше выбранной).
    var stopHelpers: @Sendable (URL) -> Void

    #if KIT_TEST_DEFAULTS
    /// Тестовая сборка: ничего настоящего не трогает.
    static let live = LinkLaunchServices(
        register: { _ in }, defaultHandlerID: { _ in nil }, copies: { _ in [] }, appURL: { _ in nil },
        setDefault: { _, _ in }, stopHelpers: { _ in })
    #else
    static let live = LinkLaunchServices(
        register: { LSRegisterURL($0 as CFURL, true) },
        defaultHandlerID: { scheme in
            guard let probe = URL(string: scheme + "://example.com"),
                  let url = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
            return Bundle(url: url)?.bundleIdentifier
        },
        copies: { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) },
        appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        setDefault: { url, scheme in try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: scheme) },
        stopHelpers: { folder in
            let prefix = folder.standardizedFileURL.path + "/"
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: BrowserHelper.bundleID) {
                if let path = app.bundleURL?.standardizedFileURL.path, path.hasPrefix(prefix) { app.terminate() }
            }
        })
    #endif
}

enum BrowserLinkError: LocalizedError, Equatable {
    case noBrowserToReturn
    case declined(String)

    var errorDescription: String? {
        switch self {
        case .noBrowserToReturn:
            return "Обычный браузер не найден, ссылки некому передать. Модуль не удалён: сначала поставь браузер или отметь основной на экране модуля"
        case .declined(let name):
            return "Ссылки по-прежнему открывает Utilitumus: «\(name)» не стал браузером по умолчанию. Модуль не удалён"
        }
    }
}

struct BrowserLinkHandler {
    static let schemes = ["http", "https"]
    /// Метка в общих настройках: последний раз, когда мы смотрели, ссылки открывал наш помощник. Нужна, когда
    /// модуль убрали мимо центра (Корзина, `rm`): по API «назначен, но копии нет» не отличить от «не назначен».
    static let markerKey = "Browser.WeAreHandler"
    static let safariID = "com.apple.Safari"

    var services: LinkLaunchServices
    var defaults: UserDefaults
    /// Система меняет обработчик не мгновенно: сколько раз и как часто перечитывать после `setDefault`.
    var settleAttempts = 5
    var settleDelay: Duration = .milliseconds(200)
    /// Копии в этих папках обработчиками не считаются: всё под /private/tmp получает флаг in-temp-dir (-10814 при открытии).
    var ignoredPrefixes = ["/private/tmp/", "/tmp/"]

    #if KIT_TEST_DEFAULTS
    static var live: BrowserLinkHandler { BrowserLinkHandler(services: .live, defaults: Kit.defaults) }
    #else
    static var live: BrowserLinkHandler { BrowserLinkHandler(services: .live, defaults: BrowserHelper.defaults) }
    #endif

    private var linksID: String { BrowserHelper.bundleID }

    // MARK: - Состояние

    /// Ссылки открывает наш помощник. По https: схемы назначаются вместе, экран модуля смотрит на неё же.
    var isDefault: Bool { services.defaultHandlerID("https") == linksID }

    /// Запомнить, чей сейчас обработчик. Назначен другой — метка снимается; назначен наш — ставится; не назначен — метка
    /// остаётся, если копий нет совсем (удалили мимо центра), и снимается, если копии есть.
    func noteDefault() {
        let current = services.defaultHandlerID("https")
        if current == linksID {
            defaults.set(true, forKey: Self.markerKey)
        } else if current != nil || !services.copies(linksID).isEmpty {
            defaults.removeObject(forKey: Self.markerKey)
        }
    }

    /// Зарегистрировать копию помощника. Только регистрация: обработчиком её делает человек.
    func register(_ helper: URL) {
        services.register(helper)
    }

    // MARK: - Другие копии

    /// Копии, которые примут ссылку после удаления `bundle`. Копия в Корзине и во временной папке обработчиком не считается.
    func otherCopies(excluding bundle: URL) -> [URL] {
        let removed = bundle.standardizedFileURL.path + "/"
        // standardizedFileURL убирает «/private» у /tmp и /var, префиксы приводятся так же.
        let ignored = ignoredPrefixes.map { URL(fileURLWithPath: $0).standardizedFileURL.path + "/" }
        return services.copies(linksID).filter { url in
            let path = url.standardizedFileURL.path
            return !path.hasPrefix(removed) && !path.contains("/.Trash") && !ignored.contains(where: path.hasPrefix)
                && FileManager.default.fileExists(atPath: path)
        }
    }

    // MARK: - Возврат браузера

    /// Кому отдать ссылки: основной браузер из настроек, если это известный браузер и он стоит, иначе Safari.
    /// Чужое приложение, пришедшее из общих настроек, обработчиком не становится.
    func returnTarget() -> (id: String, url: URL)? {
        if let id = defaults.string(forKey: BrowserHelper.fallbackKey), id != linksID, BrowserKnown.isBrowser(id),
           let url = services.appURL(id) {
            return (id, url)
        }
        return services.appURL(Self.safariID).map { (Self.safariID, $0) }
    }

    /// Перед удалением утилиты. Наш обработчик и других копий нет — вернуть браузер и убедиться, что обработчик правда
    /// сменился; нет — выбросить ошибку, тогда удалять нельзя. Иначе ничего не делает.
    func release(removing bundle: URL) async throws {
        guard Self.schemes.contains(where: { services.defaultHandlerID($0) == linksID }) else { return }
        guard otherCopies(excluding: bundle).isEmpty else { return }
        try await handBack()
    }

    /// Утилиту убрали мимо центра: метка стоит, копий нет совсем, обработчик не читается. Предложение вернуть браузер
    /// или nil, если предлагать нечего.
    func orphanOffer() -> (id: String, url: URL)? {
        guard defaults.bool(forKey: Self.markerKey), services.copies(linksID).isEmpty,
              Self.schemes.allSatisfy({ services.defaultHandlerID($0) == nil }) else { return nil }
        return returnTarget()
    }

    func restoreOrphaned() async throws {
        guard orphanOffer() != nil else { return }
        try await handBack(onlyOurs: false)
    }

    private func handBack(onlyOurs: Bool = true) async throws {
        guard let target = returnTarget() else { throw BrowserLinkError.noBrowserToReturn }
        let name = FileManager.default.displayName(atPath: target.url.path).replacingOccurrences(of: ".app", with: "")
        for scheme in Self.schemes where !onlyOurs || services.defaultHandlerID(scheme) == linksID {
            do {
                try await services.setDefault(target.url, scheme)
            } catch {
                throw BrowserLinkError.declined(name)
            }
        }
        // Ответа «сделано» мало: отказ в диалоге может вернуть успех, не меняя ничего.
        var attempts = settleAttempts
        while !Self.schemes.allSatisfy({ let after = services.defaultHandlerID($0); return after != nil && after != linksID }) {
            attempts -= 1
            guard attempts > 0 else { throw BrowserLinkError.declined(name) }
            try? await Task.sleep(for: settleDelay)
        }
        defaults.removeObject(forKey: Self.markerKey)
    }
}
