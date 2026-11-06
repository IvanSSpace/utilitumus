import SwiftUI
import AppKit

/// Установленный браузер в списке выбора.
struct InstalledBrowser: Identifiable, Equatable {
    /// Bundle id.
    let id: String
    let name: String
    let url: URL
    let icon: NSImage
    /// LaunchServices знает его как обработчик и http, и https.
    var handlesBothSchemes = false

    var supportsPrivate: Bool { BrowserPrivateMode.arguments(for: id) != nil }
}

/// UserDefaults + JSON. Нечитаемое не выбрасываем: следующая запись затёрла бы его навсегда,
/// поэтому откладываем под `<ключ>.unreadable`, как в стеше, и начинаем с пустого.
enum BrowserStorage {
    static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        defaults.set(data, forKey: key + ".unreadable")
        defaults.removeObject(forKey: key)
        return nil
    }

    static func save<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

/// Помощник «Utilitumus Links» — он и есть браузер по умолчанию. Отдельное приложение без окна
/// и значка в Dock: когда macOS отдаёт ссылку, она активирует получателя, и будь им сам Utilitumus,
/// вперёд выходило бы его главное окно. Код панели и правил общий, настройки — в домене Utilitumus.
enum BrowserHelper {
    static let bundleID = "local.utilitumus.links"
    static let defaultsDomain = "local.utilitumus"
    /// Кнопка «Проверить»: эту ссылку помощник показывает панелью всегда, без правил.
    static let testURL = URL(string: "https://example.com/#utilitumus-test")!

    static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == defaultsDomain ? .standard : (UserDefaults(suiteName: defaultsDomain) ?? .standard)
    }

    /// Включённость модуля пишет ModuleManager Utilitumus (`ModuleOn.browser`); нет ключа — выключен.
    static var moduleDisabled: Bool { !defaults.bool(forKey: "ModuleOn.browser") }

    /// Помощник внутри Utilitumus.app (из самого помощника — он сам).
    static var appURL: URL {
        if Bundle.main.bundleIdentifier == bundleID { return Bundle.main.bundleURL }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Utilitumus Links.app")
    }
}

/// Установленные браузеры, их порядок, скрытые, «основной» и правила.
/// Список пересчитывается при запуске модуля, при запуске любого приложения и при открытии экрана —
/// никаких таймеров.
@MainActor
final class BrowserCatalog: ObservableObject {
    static let shared = BrowserCatalog()

    static let rulesKey = "Browser.Rules"
    static let orderKey = "Browser.Order"
    static let hiddenKey = "Browser.Hidden"
    static let fallbackKey = "Browser.Fallback"
    static let keysKey = "Browser.Keys"

    /// Все найденные браузеры в порядке пользователя, включая скрытые.
    @Published private(set) var browsers: [InstalledBrowser] = []
    @Published private(set) var hidden: Set<String>
    /// Основной браузер: открываем в нём, когда модуль выключен, и предвыбираем в панели.
    @Published private(set) var fallbackID: String?
    @Published private(set) var rules: [BrowserRule]
    /// Свои клавиши выбора: bundle id → keyCode. У остальных клавиши раздаются автоматически.
    @Published private(set) var keys: [String: UInt16]
    /// Браузеры не из списка `BrowserKnown`, у которых проверена подпись.
    @Published private(set) var signedIDs: Set<String> = []

    private let defaults: UserDefaults
    private var storedOrder: [String]
    private var observers: [NSObjectProtocol] = []
    private var loaded = false
    /// Иконки не перечитываем при каждом пересчёте: ключ — bundle id + путь.
    private var iconCache: [String: NSImage] = [:]

    private let probe = URL(string: "https://example.com")!
    private let httpProbe = URL(string: "http://example.com")!

    init(defaults: UserDefaults = BrowserHelper.defaults) {
        self.defaults = defaults
        rules = []
        storedOrder = []
        hidden = []
        keys = [:]
        reloadStored()
    }

    /// Настройки пишут два процесса: экран модуля в Utilitumus и «Запомнить» в панели помощника.
    /// Поэтому перед каждым пересчётом читаем их заново, а не держим копию с запуска.
    private func reloadStored() {
        let newRules = BrowserStorage.load([BrowserRule].self, key: Self.rulesKey, defaults: defaults) ?? []
        let newHidden = Set(BrowserStorage.load([String].self, key: Self.hiddenKey, defaults: defaults) ?? [])
        let newFallback = defaults.string(forKey: Self.fallbackKey)
        let newKeys = BrowserStorage.load([String: UInt16].self, key: Self.keysKey, defaults: defaults) ?? [:]
        storedOrder = BrowserStorage.load([String].self, key: Self.orderKey, defaults: defaults) ?? []
        if newRules != rules { rules = newRules }
        if newHidden != hidden { hidden = newHidden }
        if newFallback != fallbackID { fallbackID = newFallback }
        if newKeys != keys { keys = newKeys }
    }

    /// Показываются в панели выбора, по порядку: номер в списке = цифра-хоткей.
    var pickerBrowsers: [InstalledBrowser] { browsers.filter { !hidden.contains($0.id) } }

    /// Клавиши показанных браузеров: своя, а у остальных цифры по порядку, пропуская занятые.
    var effectiveKeys: [String: UInt16] {
        BrowserKeys.resolve(shown: pickerBrowsers.map(\.id), explicit: keys)
    }

    /// Назначить клавишу (nil — снять, вернуться к автоматической). У кого она была — у того снимается.
    func setKey(_ keyCode: UInt16?, for id: String) {
        if let keyCode {
            keys = BrowserKeys.assign(keyCode, to: id, in: keys)
        } else {
            keys[id] = nil
        }
        BrowserStorage.save(keys, key: Self.keysKey, defaults: defaults)
    }

    /// Основной браузер, если он ещё установлен и ему можно верить (см. `BrowserRouting`).
    var fallback: InstalledBrowser? { browsers.first { $0.id == fallbackID && canTarget($0.id) } }

    /// Куда открывать, когда панель не нужна. nil — решать пользователю на панели.
    func openTarget() async -> InstalledBrowser? {
        await BrowserRouting.fallbackTarget(fallbackID: fallbackID, installed: browsers.map(\.id), shown: pickerBrowsers.map(\.id),
                                            isTrusted: { await self.isTrusted($0) })
            .flatMap(browser(id:))
    }

    /// Для экрана: то, что уже известно, без ожидания подписи.
    func canTarget(_ id: String) -> Bool { BrowserKnown.isBrowser(id) || signedIDs.contains(id) }

    /// Можно ли открывать в приложении без панели. Для решения о ссылке — всегда этот путь, он сверяет бандл заново.
    func isTrusted(_ id: String) async -> Bool {
        if BrowserKnown.isBrowser(id) { return true }
        guard let app = browser(id: id), isCandidate(app) else {
            signedIDs.remove(id)
            return false
        }
        let ok = await BrowserSignatures.shared.isValid(app.url)
        if ok { signedIDs.insert(id) } else { signedIDs.remove(id) }
        return ok
    }

    private func isCandidate(_ app: InstalledBrowser) -> Bool { app.handlesBothSchemes && BrowserTrust.isInside(app.url) }

    // MARK: - Запуск

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    /// Ссылка могла прийти раньше запуска модулей (холодный старт) или при выключенном модуле.
    func ensureLoaded() {
        if !loaded { refresh() }
    }

    func refresh() {
        loaded = true
        reloadStored()
        var found: [String: URL] = [:]
        for url in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            guard let id = Bundle(url: url)?.bundleIdentifier, !BrowserKnown.isRouter(id) else { continue }
            if let current = found[id], !Self.prefers(url, over: current) { continue }
            found[id] = url
        }

        let httpHandlers = Set(NSWorkspace.shared.urlsForApplications(toOpen: httpProbe).map(\.standardizedFileURL.path))
        let items = found.map { id, url in
            InstalledBrowser(id: id, name: Self.displayName(url), url: url, icon: icon(id: id, url: url),
                             handlesBothSchemes: httpHandlers.contains(url.standardizedFileURL.path))
        }
        // Новым: сначала настоящие браузеры, внутри — по алфавиту.
        let sorted = items.sorted {
            let a = BrowserKnown.isBrowser($0.id), b = BrowserKnown.isBrowser($1.id)
            return a != b ? a : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let known = Set(storedOrder)
        // Незнакомые приложения (терминал, Parallels, ...) умеют открывать ссылки, но браузерами не
        // являются: в панель они по умолчанию не попадают, включить их можно на экране модуля.
        var newHidden = hidden
        for item in sorted where !known.contains(item.id) && !BrowserKnown.isBrowser(item.id) { newHidden.insert(item.id) }

        let ids = BrowserOrdering.merge(stored: storedOrder, available: sorted.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        if ordered != browsers { browsers = ordered }
        if newHidden != hidden {
            hidden = newHidden
            saveHidden()
        }
        // Порядок сохраняем с хвостом того, что сейчас не установлено: вернулось — встанет на место.
        let order = ids + storedOrder.filter { !ids.contains($0) }
        if order != storedOrder {
            storedOrder = order
            BrowserStorage.save(order, key: Self.orderKey, defaults: defaults)
        }
        adoptCurrentDefaultAsFallback()
        // Экрану нужно знать заранее, что можно выбрать. Помощнику ссылок — нет: он проверит только нужную цель.
        if Bundle.main.bundleIdentifier != BrowserHelper.bundleID {
            let candidates = browsers.filter { !BrowserKnown.isBrowser($0.id) && isCandidate($0) }.map(\.id)
            Task(priority: .utility) { for id in candidates { _ = await isTrusted(id) } }
        }
    }

    /// Основной браузер не выбран, а по умолчанию стоит чужой: он и есть тот, куда вести ссылки.
    private func adoptCurrentDefaultAsFallback() {
        guard fallbackID.flatMap(browser(id:)) == nil, let url = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let id = Bundle(url: url)?.bundleIdentifier,
              let candidate = browsers.first(where: { $0.id == id }),
              BrowserKnown.isBrowser(id) || isCandidate(candidate) else { return }
        setFallback(candidate.id)
    }

    // MARK: - Изменения

    func setHidden(_ id: String, _ isHidden: Bool) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
        saveHidden()
    }

    func setFallback(_ id: String?) {
        fallbackID = id
        if let id { defaults.set(id, forKey: Self.fallbackKey) } else { defaults.removeObject(forKey: Self.fallbackKey) }
    }

    func move(from source: IndexSet, to destination: Int) {
        var new = browsers
        new.move(fromOffsets: source, toOffset: destination)
        guard new != browsers else { return }
        browsers = new
        let ids = new.map(\.id)
        storedOrder = ids + storedOrder.filter { !ids.contains($0) }
        BrowserStorage.save(storedOrder, key: Self.orderKey, defaults: defaults)
    }

    /// Одинаковое условие заменяет прежнее правило на его месте, а не плодит дубль.
    func addRule(_ rule: BrowserRule) {
        if let index = rules.firstIndex(where: { $0.kind == rule.kind && $0.value.lowercased() == rule.value.lowercased() }) {
            var replaced = rule
            replaced.id = rules[index].id
            rules[index] = replaced
        } else {
            rules.append(rule)
        }
        saveRules()
    }

    func removeRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    private func saveRules() { BrowserStorage.save(rules, key: Self.rulesKey, defaults: defaults) }
    private func saveHidden() { BrowserStorage.save(hidden.sorted(), key: Self.hiddenKey, defaults: defaults) }

    // MARK: - Вспомогательное

    func browser(id: String) -> InstalledBrowser? { browsers.first { $0.id == id } }

    /// Значок программы по bundle id (для правил «из программы»). Один запрос к
    /// NSWorkspace на id, дальше — из кэша; body читает только его.
    private var appIconCache: [String: NSImage] = [:]
    private var appIconMisses: Set<String> = []

    func appIcon(bundleID: String) -> NSImage? {
        if let cached = appIconCache[bundleID] { return cached }
        guard !appIconMisses.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            appIconMisses.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        appIconCache[bundleID] = image
        return image
    }

    private func icon(id: String, url: URL) -> NSImage {
        let key = id + "|" + url.path
        if let cached = iconCache[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[key] = image
        return image
    }

    private static func displayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Один путь на bundle id: из /Applications, иначе тот, что короче.
    private static func prefers(_ new: URL, over old: URL) -> Bool {
        let newTop = new.path.hasPrefix("/Applications/"), oldTop = old.path.hasPrefix("/Applications/")
        if newTop != oldTop { return newTop }
        return new.path.count < old.path.count
    }
}
