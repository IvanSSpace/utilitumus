import Foundation

// Возврат системного действия 🌐 при выключении и удалении «Клавиатуры». Настоящий FnSystemAction.swift со швом:
// AppleFnUsageType и горячие клавиши живут в ключах Test.* тестового домена, activateSettings и TextInputSwitcher
// стенд не трогает (только пишет в Test.Apply*, что применение было). Запуск: Tests/run-fn-restore-check.sh
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let d = Kit.defaults
let saved = "Keyboard.SavedFnUsage", keepOff = "Keyboard.KeepSystemFnOff"

/// Чистое состояние: система держит `usage` (nil — ключа нет), больше ничего не запомнено.
func reset(usage: Int?) {
    for key in [saved, keepOff, "Keyboard.SavedDictationEnabled", "Test.HotKeys", "Test.ApplyCount", "Test.ApplyWaited", "Test.ApplyRestart"] {
        d.removeObject(forKey: key)
    }
    if let usage { d.set(usage, forKey: "Test.FnUsage") } else { d.removeObject(forKey: "Test.FnUsage") }
}
func applies() -> Int { d.integer(forKey: "Test.ApplyCount") }

// Обычный путь: пользователь отключил 🌐, потом выключил модуль.
for original in [1, 2, 3] {
    reset(usage: original)
    FnSystemAction.disable()
    check(FnSystemAction.usage == 0 && d.object(forKey: saved) as? Int == original, "disable: 0 в системе, прежнее \(original) запомнено")
    FnSystemAction.restore()
    check(FnSystemAction.usage == original, "restore: вернулось \(original)")
    check(d.object(forKey: saved) == nil && !d.bool(forKey: keepOff), "restore: запомненное и намерение сброшены")
    check(applies() == 2, "restore: система применила настройки (\(applies()))")
}

// Ключа не было: возвращаем «нет ключа», а не 0.
reset(usage: nil)
FnSystemAction.disable()
check(d.object(forKey: saved) as? Int == -1, "ключа не было: запомнено -1")
FnSystemAction.restore()
check(FnSystemAction.usage == nil, "ключа не было: ключа и нет после restore")

// Прежнее значение пользователя 0: disable ничего не пишет, restore его не трогает.
reset(usage: 0)
FnSystemAction.disable()
FnSystemAction.restore()
check(FnSystemAction.usage == 0, "у пользователя был 0: остался 0")

// То же через запуск модуля (обновление с версии без флага) и «всё сразу».
reset(usage: 0)
FnSystemAction.migrateKeepOff()
FnSystemAction.restore()
check(FnSystemAction.usage == 0, "запуск при чужом 0: restore его оставляет")
reset(usage: 0)
FnSystemAction.disableAll()
FnSystemAction.restore()
check(FnSystemAction.usage == 0, "«всё сразу» при чужом 0: restore его оставляет")

// Потерянное запомненное не превращается в 0 «пользователя» повторным запуском или нажатием.
reset(usage: 1)
FnSystemAction.disable()
d.removeObject(forKey: saved)
FnSystemAction.migrateKeepOff()
FnSystemAction.disable()
check(d.object(forKey: saved) == nil, "запомненное потеряно: повторные disable и запуск 0 за прежнее не выдают")
FnSystemAction.restore()
check(FnSystemAction.usage == nil, "запомненное потеряно: после них всё равно умолчание")

// Запомненное потеряно (процесс убили, домен стёрли), а 0 держали мы: умолчание macOS, не мёртвая 🌐.
reset(usage: 1)
FnSystemAction.disable()
d.removeObject(forKey: saved)
FnSystemAction.restore()
check(FnSystemAction.usage == nil, "запомненного нет, 0 держали мы: ключ убран (умолчание)")
check(!d.bool(forKey: keepOff), "запомненного нет: намерение сброшено")

// Мусор вместо запомненного.
for junk: Any in ["abc", 7, -5, 2.5 as Double] {
    reset(usage: 1)
    FnSystemAction.disable()
    d.set(junk, forKey: saved)
    FnSystemAction.restore()
    check(FnSystemAction.usage == nil, "запомнено «\(junk)»: умолчание вместо мусора")
}

// Мы 0 не держали и запомненного нет: значение пользователя не трогаем.
reset(usage: 2)
FnSystemAction.restore()
check(FnSystemAction.usage == 2 && applies() == 0, "ничего не меняли: restore не трогает 2 и систему")
reset(usage: 0)
FnSystemAction.restore()
check(FnSystemAction.usage == 0 && applies() == 0, "0 пользователя без нашего намерения: остаётся")

// Чистая логика выбора.
check(FnSystemAction.restoreStep(saved: 1, keptOff: true, usage: 0) == .write(1), "шаг: 1 вместо 0")
check(FnSystemAction.restoreStep(saved: -1, keptOff: true, usage: 0) == .write(nil), "шаг: -1 убирает ключ")
check(FnSystemAction.restoreStep(saved: 1, keptOff: true, usage: 1) == .leave, "шаг: уже на месте")
check(FnSystemAction.restoreStep(saved: 0, keptOff: true, usage: 0) == .leave, "шаг: прежний 0")
check(FnSystemAction.restoreStep(saved: nil, keptOff: false, usage: 0) == .leave, "шаг: не наш 0")
check(FnSystemAction.restoreStep(saved: nil, keptOff: true, usage: 0) == .write(nil), "шаг: наш 0 без запомненного")
check(FnSystemAction.restoreStep(saved: "x", keptOff: true, usage: 3) == .leave, "шаг: мусор, а в системе не 0")

// Диктовка: метка сбрасывается только после записи.
let hot: [String: Any] = ["164": ["enabled": true, "value": ["type": "modifier", "parameters": [0x800000, 0, 0]]]]
reset(usage: 1)
d.set(hot, forKey: "Test.HotKeys")
FnSystemAction.disableDictation()
check(!FnSystemAction.dictationOnDoubleFn && FnSystemAction.dictationOverridden, "диктовка снята, метка стоит")
FnSystemAction.restore()
check(FnSystemAction.dictationOnDoubleFn && !FnSystemAction.dictationOverridden, "диктовка возвращена, метка снята")

// Выход сразу после возврата (удаление): применение ждёт, а не уходит в фон.
reset(usage: 1)
FnSystemAction.disable()
d.removeObject(forKey: "Test.ApplyWaited")
FnSystemAction.restore(waitForSystem: true)
check(d.object(forKey: "Test.ApplyWaited") as? Bool == true && d.bool(forKey: "Test.ApplyRestart"),
      "удаление: применение и перезапуск переключателя выполнены до выхода")
reset(usage: 1)
FnSystemAction.disable()
FnSystemAction.restore()
check(d.object(forKey: "Test.ApplyWaited") as? Bool == false, "выключение: применение в фоне")

print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
