import Foundation

// Проверка: заголовки окон в стеше хранятся хэшем, записи старых версий по-прежнему сопоставляются.
// Запуск: Tests/run-stash-title-check.sh. Настройки и окна не трогаются.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let subject = "Письмо"
let stored = StashedWindow.storedTitle(subject)
check(stored == "8b51c6b02530d6fe5713a0bc0e533f9d833fe89d0721fdd34f7ad3d85ddc7d4d", "хэш заголовка стабилен между версиями")
check(StashedWindow.storedTitle("") == "" && StashedWindow.storedTitle(nil) == "", "пустой заголовок остаётся пустым")

let window = StashedWindow(title: stored, x: 1, y: 2, width: 3, height: 4)
check(window.matches(title: subject), "окно находится по своему заголовку")
check(!window.matches(title: "Другое"), "чужой заголовок не подходит")
check(!window.matches(title: nil) && !window.matches(title: ""), "окно без заголовка не подходит")
check(!StashedWindow(title: "", x: 0, y: 0, width: 0, height: 0).matches(title: ""), "пустое с пустым не сопоставляется")

let record = StashedApp(bundleID: "com.example.app", path: "/Applications/Example.app", name: "Example", windows: [window])
let encoded = String(decoding: try! JSONEncoder().encode([record]), as: UTF8.self)
check(!encoded.contains(subject), "в сохранённой записи нет заголовка открытым текстом")
check(encoded.contains("\"title\":\"\(stored)\""), "имя поля прежнее")

// Запись, сделанная прошлой версией: открытый заголовок читается и сопоставляется.
let old = #"[{"bundleID":"com.example.app","path":"/Applications/Example.app","name":"Example","windows":[{"title":"Письмо","x":10,"y":20,"width":300,"height":400}]}]"#
let decoded = try? JSONDecoder().decode([StashedApp].self, from: Data(old.utf8))
check(decoded?.first?.windows.first?.title == subject, "старый формат читается без миграции")
check(decoded?.first?.windows.first?.matches(title: subject) == true, "старая запись находит окно по открытому заголовку")
check(decoded?.first?.windows.first?.matches(title: "Другое") == false, "старая запись не берёт чужое окно")

print(failures == 0 ? "ВСЕ ПРОВЕРКИ ПРОШЛИ" : "ПРОВАЛЕНО: \(failures)")
exit(failures == 0 ? 0 : 1)
