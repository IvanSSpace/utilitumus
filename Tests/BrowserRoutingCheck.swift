import Foundation

// Модуль «Браузер»: правила и основной браузер из настроек молча открывают только настоящий браузер.

var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}

let chrome = "com.google.Chrome", safari = "com.apple.Safari", brave = "com.brave.Browser"
let evil = "com.evil.https", spoof = "com.apple.Safari.x"
let bank = URL(string: "https://bank.com/reset?token=1")!
func rule(_ value: String, _ id: String, isPrivate: Bool = false) -> BrowserRule {
    BrowserRule(kind: .domain, value: value, browserID: id, isPrivate: isPrivate)
}
func route(_ rules: [BrowserRule], installed: Set<String> = [chrome, safari, evil, spoof], shown: [String] = [chrome, safari]) -> BrowserRouting.Route {
    BrowserRouting.route(rules: rules, url: bank, sourceBundleID: nil, installed: installed, shown: shown)
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

check("правило на настоящий браузер работает", route([rule("bank.com", chrome)]) == .open(id: chrome, isPrivate: false))
check("приватность правила сохраняется", route([rule("bank.com", brave, isPrivate: true)], installed: [brave, chrome]) == .open(id: brave, isPrivate: true))
check("браузер скрыт из панели, правило на него работает", route([rule("bank.com", safari)], shown: [chrome]) == .open(id: safari, isPrivate: false))
check("правило на незнакомое приложение: панель", route([rule("bank.com", evil)]) == .panel)
check("незнакомое приложение включено в панель: всё равно панель", route([rule("bank.com", evil)], shown: [chrome, evil]) == .panel)
check("правило на обманный bundle id: панель", route([rule("bank.com", spoof)]) == .panel)
check("одна иконка и правило на незнакомое: панель, а не браузер молча", route([rule("bank.com", evil)], shown: [chrome]) == .panel)
check("правило на незнакомое, показывать нечего: основной", route([rule("bank.com", evil)], shown: []) == .fallback)
check("незнакомое правило раньше настоящего не даёт молча открыть его", route([rule("bank.com", evil), rule("bank.com", chrome)]) == .panel)
check("удалённый браузер в правиле не считается", route([rule("bank.com", "org.mozilla.firefox")]) == .panel)
check("правило на другой домен не срабатывает", route([rule("other.com", evil)]) == .panel)

// MARK: Без правил

check("несколько браузеров: панель", route([]) == .panel)
check("один браузер: без панели", route([], shown: [chrome]) == .open(id: chrome, isPrivate: false))
check("одно незнакомое приложение: панель", route([], shown: [evil]) == .panel)
check("показывать нечего: основной", route([], shown: []) == .fallback)

// MARK: Основной браузер

func target(_ id: String?, installed: [String] = [evil, chrome, safari], shown: [String] = [evil, chrome]) -> String? {
    BrowserRouting.fallbackTarget(fallbackID: id, installed: installed, shown: shown)
}
check("основной настоящий", target(safari) == safari)
check("основной незнаком: панель", target(evil) == nil)
check("основной с обманным id: панель", target(spoof, installed: [spoof, chrome]) == nil)
check("не выбран: первый настоящий из показанных", target(nil) == chrome)
check("не выбран, показанных настоящих нет: первый настоящий из установленных", target(nil, shown: [evil]) == chrome)
check("основной удалён: первый настоящий", target("org.mozilla.firefox") == chrome)
check("настоящих нет: панель", target(nil, installed: [evil], shown: [evil]) == nil)

// MARK: Старые настройки читаются

let stored = #"[{"id":"7A1C1A5E-0000-4000-8000-000000000001","kind":"domain","value":"bank.com","browserID":"com.google.Chrome","isPrivate":false}]"#
let decoded = try! JSONDecoder().decode([BrowserRule].self, from: Data(stored.utf8))
check("сохранённое правило работает как раньше", route(decoded) == .open(id: chrome, isPrivate: false))

exit(failed ? 1 : 0)
