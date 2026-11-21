import AppKit
import SwiftUI

// Какой адрес входа утилита согласна открыть в браузере. Страницы внутри экрана больше нет: экран родной, браузер запасной,
// и адрес с кодом открывает сама утилита (кто и когда — Tests/StudioRunnerCheck.swift). Запуск: Tests/run-studio-nav-check.sh

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func url(_ s: String) -> URL? { URL(string: s) }

check(StudioNavigation.loginURL("http://127.0.0.1:47870/#b=abcdefghijklmnop")?.port == 47870, "адрес входа: порт берётся из адреса")
for bad in ["file:///x", "http://example.com:47870/", "https://127.0.0.1:47870/", "http://127.0.0.1/", "http://u:p@127.0.0.1:47870/", "мусор", ""] {
    check(StudioNavigation.loginURL(bad) == nil, "адрес входа не годится: \(bad.isEmpty ? "пусто" : bad)")
}
check(StudioNavigation.loginURL(nil) == nil, "адреса входа нет")
check(StudioNavigation.isStudio(url("http://localhost:51234/")!, port: 51234), "localhost своего порта — Студия")
check(!StudioNavigation.isStudio(url("http://127.0.0.1:51235/")!, port: 51234), "чужой порт — не Студия")
check(!StudioNavigation.isStudio(url("http://localhost.evil.com:51234/")!, port: 51234), "чужой хост с похожим именем — не Студия")
check(!StudioNavigation.isStudio(url("http://127.0.0.1:80/")!, port: 80), "привилегированный порт — не Студия")

print(failures == 0 ? "ВСЁ ЗЕЛЁНОЕ" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
