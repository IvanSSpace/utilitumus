import Foundation

// Чистая логика модуля «Браузер»: без AppKit, чтобы её можно было проверить отдельно.

/// Правило «куда открывать»: домен (или поддомен) либо приложение-источник → браузер.
/// Хранится в UserDefaults. Формат менять только совместимо: новые поля опциональные.
struct BrowserRule: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// `value` — домен: ловит сам домен и его поддомены. Может быть с началом пути:
        /// «github.com/apple» ловит только ссылки на github.com/apple/…
        case domain
        /// `value` — bundle id приложения, из которого пришла ссылка.
        case app
    }

    var id = UUID()
    var kind: Kind
    var value: String
    /// Bundle id браузера, в котором открыть.
    var browserID: String
    /// Открывать в приватном окне (если браузер это умеет).
    var isPrivate = false
    /// Имя приложения для показа в списке (для `.app`), чтобы подпись жила и без самого приложения.
    var title: String?
}

enum BrowserRuleMatcher {
    /// Хост ссылки в нижнем регистре без точки на конце. У файла и ссылки без хоста — nil.
    static func host(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// Домен из того, что вписал пользователь: «https://www.Google.com/search?q=1» → «google.com».
    /// Пустая строка и ввод без точки (кроме localhost) — nil.
    static func normalizeDomain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        while text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        guard text.contains(".") || text == "localhost" else { return nil }
        return text
    }

    /// `google.com` ловит `google.com` и `meet.google.com`, но не `notgoogle.com`.
    static func hostMatches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Домен с началом пути из того, что вписал пользователь:
    /// «https://github.com/Apple/swift/pull/1» оставляет путь как есть → «github.com/apple/swift/pull/1»,
    /// «github.com/apple/» → «github.com/apple». Без пути — как `normalizeDomain`.
    static func normalizePattern(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let end = text.firstIndex(where: { "?#".contains($0) }) { text = String(text[..<end]) }
        guard let slash = text.firstIndex(of: "/") else { return normalizeDomain(text) }
        guard let domain = normalizeDomain(String(text[..<slash])) else { return nil }
        let path = text[slash...].split(separator: "/").joined(separator: "/")
        return path.isEmpty ? domain : domain + "/" + path
    }

    /// Правило-домен → домен и начало пути (без крайних «/», в нижнем регистре; пустое — без пути).
    static func split(pattern: String) -> (domain: String, path: String) {
        let text = pattern.lowercased()
        guard let slash = text.firstIndex(of: "/") else { return (text, "") }
        return (String(text[..<slash]), text[slash...].split(separator: "/").joined(separator: "/"))
    }

    /// Путь ссылки начинается с `prefix` целыми кусками: «apple» ловит «/apple/swift»,
    /// но не «/apple-old». Регистр не важен: у GitHub и большинства сайтов имена без регистра.
    static func pathMatches(urlPath: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        let path = urlPath.lowercased().split(separator: "/").joined(separator: "/")
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    /// Какое правило сработает. Правило с путём точнее правила на весь сайт, поэтому сначала —
    /// подошедшие правила с путём (самый длинный путь), потом остальные по порядку списка:
    /// домен сравнивается с хостом ссылки, приложение — с bundle id отправителя.
    static func firstMatch(rules: [BrowserRule], url: URL?, sourceBundleID: String?) -> BrowserRule? {
        let host = url.flatMap(host(of:))
        let urlPath = url?.path ?? ""
        func matches(_ rule: BrowserRule) -> Bool {
            switch rule.kind {
            case .domain:
                guard let host else { return false }
                let (domain, path) = split(pattern: rule.value)
                return hostMatches(host: host, domain: domain) && pathMatches(urlPath: urlPath, prefix: path)
            case .app:
                guard let sourceBundleID else { return false }
                return rule.value == sourceBundleID
            }
        }
        let withPath = rules.filter { $0.kind == .domain && !split(pattern: $0.value).path.isEmpty && matches($0) }
        if let best = withPath.max(by: { split(pattern: $0.value).path.count < split(pattern: $1.value).path.count }) {
            return best
        }
        return rules.first(where: matches)
    }
}

enum BrowserOrdering {
    /// Сохранённый порядок плюс новые браузеры в конец. Чего нет на диске — отбрасывается,
    /// повторы схлопываются. `available` приходит уже в нужном порядке для новых.
    static func merge(stored: [String], available: [String]) -> [String] {
        let present = Set(available)
        var result: [String] = []
        var seen = Set<String>()
        for id in stored where present.contains(id) && seen.insert(id).inserted { result.append(id) }
        for id in available where seen.insert(id).inserted { result.append(id) }
        return result
    }
}

/// Как открыть ссылку в приватном окне: у каждой семьи браузеров свой ключ.
enum BrowserPrivateMode {
    private static let chromiumPrefixes = [
        "com.google.Chrome", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "ru.yandex.desktop.yandex-browser", "org.chromium.Chromium",
    ]
    private static let firefoxPrefixes = [
        "org.mozilla.firefox", "org.mozilla.nightly", "app.zen-browser.zen",
        "io.gitlab.librewolf-community", "net.waterfox.waterfox",
    ]

    /// Аргументы запуска или nil, если браузер приватного режима из командной строки не умеет
    /// (Safari, Dia и неизвестные): тогда открывается обычное окно.
    static func arguments(for bundleID: String) -> [String]? {
        if bundleID.hasPrefix("com.microsoft.edgemac") { return ["--inprivate"] }
        // Arc — единственный из company.thebrowser.*, кто понимает --incognito; Dia не трогаем.
        if bundleID == "company.thebrowser.Browser" { return ["--incognito"] }
        if chromiumPrefixes.contains(where: bundleID.hasPrefix) { return ["--incognito"] }
        if firefoxPrefixes.contains(where: bundleID.hasPrefix) { return ["-private-window"] }
        return nil
    }
}

/// Какие приложения считаем браузерами, а какие просто умеют открывать http-ссылки.
enum BrowserKnown {
    private static let browserPrefixes = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "ru.yandex.desktop.yandex-browser",
        "org.chromium.Chromium", "app.zen-browser.zen", "com.kagi.kagimacOS", "com.sigmaos.sigmaos.macos",
        "org.torproject.torbrowser", "io.gitlab.librewolf-community", "net.waterfox.waterfox",
        "com.duckduckgo.macos.browser", "com.pushplaylabs.sidekick", "ai.perplexity.comet",
    ]
    /// Другие «выбиралки браузера»: в панели им не место.
    private static let routerPrefixes = [
        "com.browserosaurus", "fi.johnnyjumper.finicky", "com.choosyosx", "com.sindresorhus.Velja",
        "app.velja", "local.shar.dia-router", "software.openinapp",
        // Сам Utilitumus и его помощник ссылок.
        "local.utilitumus",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        browserPrefixes.contains(where: bundleID.hasPrefix)
    }

    static func isRouter(_ bundleID: String) -> Bool {
        routerPrefixes.contains(where: bundleID.hasPrefix)
    }
}

/// Клавиши выбора браузера на панели. Хранятся по физической клавише (`NSEvent.keyCode`), а не по
/// символу: с русской раскладкой «C» должна срабатывать, даже если система печатает «с».
enum BrowserKeys {
    /// Допустимые клавиши (цифры 0-9 и латинские A-Z) и их подпись: фиксированная таблица ANSI.
    static let labels: [UInt16: String] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
        37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
        9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
    ]

    /// Цифры 1-9 по порядку: на них раздаются автоматические клавиши.
    static let autoCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Цифры цифрового блока приравниваем к цифрам верхнего ряда.
    private static let keypad: [UInt16: UInt16] = [
        82: 29, 83: 18, 84: 19, 85: 20, 86: 21, 87: 23, 88: 22, 89: 26, 91: 28, 92: 25,
    ]

    static func normalized(_ keyCode: UInt16) -> UInt16 { keypad[keyCode] ?? keyCode }

    static func label(for keyCode: UInt16) -> String? { labels[normalized(keyCode)] }

    static func isAssignable(_ keyCode: UInt16) -> Bool { labels[normalized(keyCode)] != nil }

    /// Назначить клавишу браузеру: если она уже у другого, у того она снимается.
    static func assign(_ keyCode: UInt16, to id: String, in keys: [String: UInt16]) -> [String: UInt16] {
        let code = normalized(keyCode)
        var result = keys.filter { $0.value != code }
        result[id] = code
        return result
    }

    /// Клавиши показанных браузеров (по порядку панели): у кого есть своя — она; у остальных цифры 1-9
    /// по порядку, пропуская занятые чужими назначениями. Кончились цифры — клавиши нет.
    static func resolve(shown: [String], explicit: [String: UInt16]) -> [String: UInt16] {
        var result: [String: UInt16] = [:]
        var taken = Set<UInt16>()
        for id in shown {
            if let code = explicit[id], isAssignable(code), taken.insert(normalized(code)).inserted {
                result[id] = normalized(code)
            }
        }
        var free = autoCodes.filter { !taken.contains($0) }[...]
        for id in shown where result[id] == nil {
            guard let code = free.popFirst() else { break }
            result[id] = code
        }
        return result
    }
}
