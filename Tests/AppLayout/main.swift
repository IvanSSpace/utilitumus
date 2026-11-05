import Foundation

// Запуск: scripts/test-app-layout.sh
var failed = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "ok   " : "FAIL ", name)
    if !ok { failed += 1 }
}

let abc = "com.apple.keylayout.ABC"
let ru = "com.apple.keylayout.RussianWin"
let de = "com.apple.keylayout.German"
let enabled = [abc, ru]

check("запомнили в Safari русскую, вернули её при входе", {
    var m = AppLayoutMemory()
    m.remember(layout: ru, in: "com.apple.Safari")
    m.remember(layout: abc, in: "com.apple.Terminal")
    return m.layout(for: "com.apple.Safari", enabled: enabled) == ru
        && m.layout(for: "com.apple.Terminal", enabled: enabled) == abc
}())
check("последняя смена в приложении перезаписывает прежнюю", {
    var m = AppLayoutMemory()
    m.remember(layout: ru, in: "a")
    m.remember(layout: abc, in: "a")
    return m.layout(for: "a", enabled: enabled) == abc
}())
check("remember сообщает, изменилась ли запись", {
    var m = AppLayoutMemory()
    let first = m.remember(layout: ru, in: "a")
    let same = m.remember(layout: ru, in: "a")
    return first && !same
}())
check("новое приложение, «как было»: ничего не меняем",
      AppLayoutMemory().layout(for: "new", enabled: enabled) == nil)
check("новое приложение с выбранной раскладкой: берём её",
      AppLayoutMemory(newAppLayout: abc).layout(for: "new", enabled: enabled) == abc)
check("выбранная для новых раскладка выключена в системе: ничего не меняем",
      AppLayoutMemory(newAppLayout: de).layout(for: "new", enabled: enabled) == nil)
check("сохранённая раскладка выключена в системе: правило для новых", {
    var m = AppLayoutMemory(newAppLayout: abc)
    m.remember(layout: de, in: "a")
    return m.layout(for: "a", enabled: enabled) == abc
}())
check("исключённое приложение: не запоминаем и не возвращаем", {
    var m = AppLayoutMemory(excluded: ["x"], newAppLayout: abc)
    let changed = m.remember(layout: ru, in: "x")
    return !changed && m.layout(for: "x", enabled: enabled) == nil && m.saved["x"] == nil
}())
check("приложение добавили в исключения после запоминания: не возвращаем", {
    var m = AppLayoutMemory()
    m.remember(layout: ru, in: "a")
    m.excluded.insert("a")
    return m.layout(for: "a", enabled: enabled) == nil
}())

if failed > 0 { print("\(failed) тестов упало"); exit(1) }
print("все тесты прошли")
