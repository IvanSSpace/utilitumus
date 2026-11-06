import Foundation

// Модуль «Браузер»: правила и основной браузер из настроек молча открывают только браузер из списка
// или подписанное приложение из /Applications. Приложения стенда лежат в его папке, система о них не знает.

var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}

let chrome = "com.google.Chrome", safari = "com.apple.Safari", brave = "com.brave.Browser"
let evil = "com.evil.https", spoof = "com.apple.Safari.x", floorp = "one.ablaze.floorp"
let bank = URL(string: "https://bank.com/reset?token=1")!
func rule(_ value: String, _ id: String, isPrivate: Bool = false) -> BrowserRule {
    BrowserRule(kind: .domain, value: value, browserID: id, isPrivate: isPrivate)
}
/// Подпись и расположение проверены у `floorp`, и больше ни у кого.
let trust: (String) async -> Bool = { BrowserKnown.isBrowser($0) || $0 == floorp }
func route(_ rules: [BrowserRule], installed: Set<String> = [chrome, safari, evil, spoof, floorp], shown: [String] = [chrome, safari]) async -> BrowserRouting.Route {
    await BrowserRouting.route(rules: rules, url: bank, sourceBundleID: nil, installed: installed, shown: shown, isTrusted: trust)
}

// MARK: Точное сравнение

for id in [safari, "com.apple.SafariTechnologyPreview", chrome, "com.google.Chrome.canary", "org.mozilla.firefox", brave,
           "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
           "ru.yandex.desktop.yandex-browser", "app.zen-browser.zen", "com.kagi.kagimacOS", "ai.perplexity.comet"] {
    check("настоящий браузер: \(id)", BrowserKnown.isBrowser(id))
}
for id in [spoof, "com.google.Chrome.evil", "org.mozilla.evil", "company.thebrowser.evil", evil, ""] {
    check("не браузер: «\(id)»", !BrowserKnown.isBrowser(id))
}

// MARK: Правила

check("правило на настоящий браузер работает", await route([rule("bank.com", chrome)]) == .open(id: chrome, isPrivate: false))
check("приватность правила сохраняется", await route([rule("bank.com", brave, isPrivate: true)], installed: [brave, chrome]) == .open(id: brave, isPrivate: true))
check("браузер скрыт из панели, правило на него работает", await route([rule("bank.com", safari)], shown: [chrome]) == .open(id: safari, isPrivate: false))
check("правило на незнакомое приложение: панель", await route([rule("bank.com", evil)]) == .panel)
check("незнакомое приложение включено в панель: всё равно панель", await route([rule("bank.com", evil)], shown: [chrome, evil]) == .panel)
check("правило на обманный bundle id: панель", await route([rule("bank.com", spoof)]) == .panel)
check("одна иконка и правило на незнакомое: панель, а не браузер молча", await route([rule("bank.com", evil)], shown: [chrome]) == .panel)
check("правило на незнакомое, показывать нечего: основной", await route([rule("bank.com", evil)], shown: []) == .fallback)
check("незнакомое правило раньше настоящего не даёт молча открыть его", await route([rule("bank.com", evil), rule("bank.com", chrome)]) == .panel)
check("удалённый браузер в правиле не считается", await route([rule("bank.com", "org.mozilla.firefox")]) == .panel)
check("правило на другой домен не срабатывает", await route([rule("other.com", evil)]) == .panel)

// MARK: Браузер не из списка

check("правило на подписанное приложение работает", await route([rule("bank.com", floorp)]) == .open(id: floorp, isPrivate: false))
check("один показанный подписанный браузер: без панели", await route([], shown: [floorp]) == .open(id: floorp, isPrivate: false))
check("основной подписанный", await target(floorp, installed: [floorp, chrome], shown: [chrome]) == floorp)
check("не выбран, показан только подписанный: он", await target(nil, installed: [evil, floorp], shown: [floorp]) == floorp)
check("не выбран: браузер из списка раньше подписанного", await target(nil, installed: [floorp, chrome], shown: [floorp, chrome]) == chrome)
check("не выбран, подписанный скрыт: не открываем молча", await target(nil, installed: [floorp, evil], shown: [evil]) == nil)

// MARK: Без правил

check("несколько браузеров: панель", await route([]) == .panel)
check("один браузер: без панели", await route([], shown: [chrome]) == .open(id: chrome, isPrivate: false))
check("одно незнакомое приложение: панель", await route([], shown: [evil]) == .panel)
check("показывать нечего: основной", await route([], shown: []) == .fallback)

// MARK: Основной браузер

func target(_ id: String?, installed: [String] = [evil, chrome, safari], shown: [String] = [evil, chrome]) async -> String? {
    await BrowserRouting.fallbackTarget(fallbackID: id, installed: installed, shown: shown, isTrusted: trust)
}
check("основной настоящий", await target(safari) == safari)
check("основной незнаком: панель", await target(evil) == nil)
check("основной с обманным id: панель", await target(spoof, installed: [spoof, chrome]) == nil)
check("не выбран: первый настоящий из показанных", await target(nil) == chrome)
check("не выбран, показанных настоящих нет: первый настоящий из установленных", await target(nil, shown: [evil]) == chrome)
check("основной удалён: первый настоящий", await target("org.mozilla.firefox") == chrome)
check("настоящих нет: панель", await target(nil, installed: [evil], shown: [evil]) == nil)

// MARK: Старые настройки читаются

let stored = #"[{"id":"7A1C1A5E-0000-4000-8000-000000000001","kind":"domain","value":"bank.com","browserID":"com.google.Chrome","isPrivate":false}]"#
let decoded = try! JSONDecoder().decode([BrowserRule].self, from: Data(stored.utf8))
check("сохранённое правило работает как раньше", await route(decoded) == .open(id: chrome, isPrivate: false))

// MARK: Подпись и расположение на настоящих бандлах

let fm = FileManager.default
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let root = fixtures.appendingPathComponent("Applications/").path + "/"
func app(_ path: String) -> URL { fixtures.appendingPathComponent(path) }
func eligible(_ path: String) -> Bool { BrowserTrust.isInside(app(path), root: root) && BrowserTrust.hasValidSignature(app(path)) }

check("подписанное приложение в папке приложений проходит", eligible("Applications/Signed.app"))
check("и во вложенной папке", eligible("Applications/Sub/Signed.app"))
check("после снятия подписи не проходит", !eligible("Applications/Stripped.app"))
check("подпись компоновщика (никем не подписано) не проходит", !eligible("Applications/Linker.app"))
check("ad-hoc не проходит", !eligible("Applications/AdHoc.app"))
check("изменённое после подписи не проходит", !eligible("Applications/Tampered.app"))
check("подписанное вне папки приложений не проходит", !eligible("Elsewhere/Signed.app"))
check("ссылка из папки приложений наружу не проходит", !eligible("Applications/Link.app"))
check("папка-ссылка наружу не проходит", !eligible("Applications/LinkDir/Signed.app"))
check("папка с похожим именем не проходит", !eligible("Applications2/Signed.app"))
check("настоящий каталог приложений по умолчанию", !BrowserTrust.isInside(app("Applications/Signed.app")))
check("нет бандла: не проходит", !eligible("Applications/Нет.app"))

// MARK: Кэш

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var mainThread = false
    func hit() { lock.lock(); count += 1; if Thread.isMainThread { mainThread = true }; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    var onMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
}
let counter = Counter()
let signatures = BrowserSignatures { url in
    counter.hit()
    Thread.sleep(forTimeInterval: 0.05)
    return BrowserTrust.hasValidSignature(url)
}
let cached = app("Applications/Cached.app")
let first = await signatures.isValid(cached)
let second = await signatures.isValid(cached)
check("проверка вне главного потока", !counter.onMain)
check("результат верный и проверка одна на бандл", first && second && counter.value == 1, "\(first) \(second) \(counter.value)")
let other = app("Applications/Sub/Signed.app")
async let a = signatures.isValid(other)
async let b = signatures.isValid(other)
let both = await (a, b)
check("одновременные запросы ждут одну проверку", both.0 && both.1 && counter.value == 2, "\(counter.value)")
let executable = cached.appendingPathComponent("Contents/MacOS/Fixture")
var content = try! Data(contentsOf: executable)
content[100] ^= 1 // внутри подписанных страниц
try! content.write(to: executable)
let afterChange = await signatures.isValid(cached)
check("файл программы изменился: проверяем заново и отказываем", !afterChange && counter.value == 3, "\(afterChange) \(counter.value)")
check("настоящая проверка кэша по умолчанию", await BrowserSignatures.shared.isValid(app("Applications/Sub/Signed.app")))
check("бандла нет: отказ без проверки", !(await signatures.isValid(app("Applications/Нет.app"))) && counter.value == 3)

exit(failed ? 1 : 0)
