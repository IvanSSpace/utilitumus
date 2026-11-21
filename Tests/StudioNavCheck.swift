import AppKit
import SwiftUI
import WebKit

// Что страница Студии может открыть, и когда ей нужен новый код входа. Запуск: Tests/run-studio-nav-check.sh

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func url(_ s: String) -> URL? { URL(string: s) }

let port = 51234

// Политика навигации.
let allowed = ["http://127.0.0.1:51234/", "http://127.0.0.1:51234/#b=abc", "http://localhost:51234/x?y=1", "HTTP://LOCALHOST:51234/"]
for a in allowed { check(StudioNavigation.decide(url(a), port: port) == .allow, "свой адрес идёт: \(a)") }
let toBrowser = ["http://127.0.0.1:51235/", "http://127.0.0.1/", "http://127.0.0.1:80/", "https://127.0.0.1:51234/", "http://example.com/", "https://example.com:51234/",
                 "http://localhost.evil.com:51234/", "http://127.0.0.1.evil.com:51234/", "http://evil.com/?h=127.0.0.1:51234",
                 "http://user@127.0.0.1:51234/", "http://127.0.0.1:51234@evil.com/", "http://[::1]:51234/", "http://0.0.0.0:51234/", "http://127.1:51234/"]
for a in toBrowser {
    let decision = StudioNavigation.decide(url(a), port: port)
    check(decision == .openInBrowser, "чужой адрес в браузер: \(a) (\(decision))")
}
let refusedSchemes = ["file:///etc/passwd", "file://localhost/Users/x", "javascript:alert(1)", "data:text/html,<b>x</b>", "blob:http://127.0.0.1:51234/abc",
                      "about:blank", "ftp://127.0.0.1:51234/", "x-apple.systempreferences:", "applescript://x", "ssh://127.0.0.1"]
for a in refusedSchemes { check(StudioNavigation.decide(url(a), port: port) == .refuse, "схема не открывается нигде: \(a)") }
check(StudioNavigation.decide(nil, port: port) == .refuse, "без адреса — отказ")
check(StudioNavigation.decide(url("http://127.0.0.1:0/"), port: 0) != .allow, "порт 0 не разрешён")
check(StudioNavigation.decide(url("http://127.0.0.1:80/"), port: 80) != .allow, "привилегированный порт не разрешён")

check(StudioNavigation.loginURL("http://127.0.0.1:47870/#b=abcdefghijklmnop")?.port == 47870, "адрес входа: порт берётся из адреса")
for bad in ["file:///x", "http://example.com:47870/", "https://127.0.0.1:47870/", "http://127.0.0.1/", "http://u:p@127.0.0.1:47870/", "мусор", ""] {
    check(StudioNavigation.loginURL(bad) == nil, "адрес входа не годится: \(bad.isEmpty ? "пусто" : bad)")
}
check(StudioNavigation.loginURL(nil) == nil, "адреса входа нет")

// Загрузчик страницы: те же правила в настоящем WKWebView, чужое уходит в браузер, ничего не создаётся.
MainActor.assumeIsolated {
    var opened: [URL] = []
    let holder = StudioWebHolder(openExternal: { opened.append($0) })
    check(holder.route(url("http://127.0.0.1:51234/")) == .cancel, "порт не задан: страница свой адрес не открывает (он уходит в браузер)")
    opened = []
    holder.port = port
    check(holder.route(url("http://127.0.0.1:51234/")) == .allow, "свой адрес открывается")
    check(holder.route(url("https://example.com/a")) == .cancel && opened == [url("https://example.com/a")], "чужой https: отмена и в браузер")
    check(holder.route(url("https://example.com/b"), mainFrame: false, linkClicked: true) == .cancel && opened.count == 1,
          "чужой адрес из вложенного фрейма: отмена, браузер не зовётся")
    check(holder.route(url("https://example.com/c"), mainFrame: true, linkClicked: false) == .cancel && opened.count == 1,
          "чужой адрес из скрипта без клика: отмена, браузер не зовётся")
    check(holder.route(url("http://127.0.0.1:51235/"), mainFrame: true, linkClicked: false) == .cancel && opened.count == 1,
          "другой порт этого хоста без клика: отмена, браузер не зовётся")
    check(holder.route(url("http://127.0.0.1:51234/page"), mainFrame: false, linkClicked: false) == .allow, "свой адрес во фрейме идёт")
    check(holder.route(url("file:///etc/hosts")) == .cancel && opened.count == 1, "file: отмена, браузер не зовётся")
    check(holder.route(url("javascript:alert(1)")) == .cancel && opened.count == 1, "javascript: отмена")
    check(holder.webView.configuration.websiteDataStore.isPersistent == false, "хранилище одноразовое")
    check(holder.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically == false, "страница не открывает окна сама")
}

// Открыть в браузере: только адрес, пришедший после просьбы.
MainActor.assumeIsolated {
    func running(_ login: Int, _ code: String) -> StudioState {
        StudioState(folder: "/f", phase: .running, message: nil, ownsServer: true, page: "http://127.0.0.1:51234/#b=\(code)", login: login)
    }
    var opened: [URL] = []
    let handoff = StudioBrowserHandoff(open: { opened.append($0) })
    handoff.observe(running(4, "oldoldoldoldoldold"))
    check(opened.isEmpty, "без просьбы ничего не открывается")
    handoff.request(after: 4)
    handoff.observe(running(4, "oldoldoldoldoldold"))
    check(opened.isEmpty, "прежний (уже потраченный) код не открывается")
    check(handoff.claimed == 0, "до открытия код никто не занял")
    handoff.observe(running(5, "newnewnewnewnewnew"))
    check(opened == [url("http://127.0.0.1:51234/#b=newnewnewnewnewnew")], "новый код открыт")
    check(handoff.claimed == 5, "код 5 занят браузером")
    handoff.observe(running(6, "againagainagainagain"))
    check(opened.count == 1, "одна просьба — одно открытие")
    handoff.request(after: 6)
    var stopped = running(7, "x")
    stopped.phase = .stopped
    handoff.observe(stopped)
    check(opened.count == 1, "остановленная Студия: не открывается")
    var foreign = running(8, "x")
    foreign.page = "http://example.com/#b=x"
    handoff.observe(foreign)
    check(opened.count == 1, "чужой адрес из состояния не открывается")
}

// Когда страница просит новый код.
var gate = StudioLoginGate()
func st(_ phase: StudioPhase, login: Int, page: String? = "http://127.0.0.1:51234/#b=abcdefghijklmnop") -> StudioState {
    StudioState(folder: "/f", phase: phase, message: nil, ownsServer: true, page: page, login: login)
}
check(gate.step(st(.stopped, login: 0, page: nil)) == .wait, "остановлена: ждём")
check(gate.step(st(.running, login: 5)) == .requestNew, "новая страница при работающей Студии: сначала новый код (прежний мог быть потрачен)")
check(gate.step(st(.running, login: 5)) == .wait, "пока новый код не пришёл — ждём, второй раз не просим")
if case .load(let u, let l) = gate.step(st(.running, login: 6)) { check(l == 6 && u.port == 51234, "пришёл новый код: загружаем") } else { check(false, "пришёл новый код: загружаем") }
check(gate.step(st(.running, login: 6)) == .wait, "тот же код второй раз не грузим")
if case .load = gate.step(st(.running, login: 7)) { check(true, "«обновить»: новый код грузится") } else { check(false, "«обновить»: новый код грузится") }
check(gate.step(st(.running, login: 8, page: "http://evil.example/#b=x")) == .wait, "чужой адрес из состояния не грузится")
gate.reset()
check(gate.step(st(.running, login: 9)) == .requestNew, "после остановки всё заново")

// Код, ушедший в браузер, окну не нужен: одноразовый код второй раз не войдёт.
var claimedGate = StudioLoginGate()
_ = claimedGate.step(st(.running, login: 1))
if case .load = claimedGate.step(st(.running, login: 2)) { check(true, "окно: загрузило свой код") } else { check(false, "окно: загрузило свой код") }
check(claimedGate.step(st(.running, login: 3), skipping: 3) == .wait, "код 3 занят браузером: окно его не грузит")
check(claimedGate.step(st(.running, login: 3), skipping: 3) == .wait, "и повторно не грузит")
if case .load(_, let l) = claimedGate.step(st(.running, login: 4), skipping: 3) { check(l == 4, "следующий код окно берёт") } else { check(false, "следующий код окно берёт") }
var freshGate = StudioLoginGate()
check(freshGate.step(st(.running, login: 5), skipping: 0) == .requestNew, "новая страница просит код")
check(freshGate.step(st(.running, login: 6), skipping: 6) == .requestNew, "первый код новой страницы занят браузером: просит следующий")
if case .load(_, let l) = freshGate.step(st(.running, login: 7), skipping: 6) { check(l == 7, "и берёт следующий") } else { check(false, "и берёт следующий") }

print(failures == 0 ? "ВСЁ ЗЕЛЁНОЕ" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
