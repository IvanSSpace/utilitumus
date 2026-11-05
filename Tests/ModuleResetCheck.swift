import Foundation

// Проверка одноразового сброса модулей на словаре настроек. Запуск: Tests/run-module-reset-check.sh
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let ids = ["sound", "fans", "keyboard", "browser"]
let flag = ModuleReset.flagKey

/// Как делает ModuleManager: плана нет — словарь не меняется.
func run(_ store: inout [String: Any]) -> ModuleReset.Plan? {
    let plan = ModuleReset.plan(snapshot: store, moduleIDs: ids)
    if let plan { for (key, value) in plan.writes { store[key] = value } }
    return plan
}

// Обновление: модули включены, часть скрыта, рядом настройки модулей и оформления.
var old: [String: Any] = [
    "ModulesV2": true, "ModulesV3": true,
    "ModuleOn.sound": true, "ModuleOn.fans": true, "ModuleOn.keyboard": true, "ModuleOn.browser": false,
    "ModuleHidden.fans": true,
    "ModuleOrder": ["fans", "sound"],
    "FanConfigs": "x", "MixerPresets": "y", "BrowserRules": "z", "Theme": "dark", "PageMode": 2,
]
let plan1 = run(&old)
check(plan1 != nil, "обновление: сброс выполнен")
check(ids.allSatisfy { old["ModuleOn.\($0)"] as? Bool == false }, "все ModuleOn.* выключены")
check(ids.allSatisfy { old["ModuleHidden.\($0)"] as? Bool == false }, "скрытие снято")
check(old[flag] as? Bool == true, "флаг поставлен")
check(old["ModuleOrder"] as? [String] == ["fans", "sound"], "порядок в панели цел")
check(old["FanConfigs"] as? String == "x" && old["MixerPresets"] as? String == "y"
      && old["BrowserRules"] as? String == "z", "настройки модулей целы")
check(old["Theme"] as? String == "dark" && old["PageMode"] as? Int == 2, "тема и режим страниц целы")
check(plan1?.restoresSystemFn == false, "Fn не трогаем, если его не отключали")

// Повтор: ничего не делает, даже если человек уже заново поставил модуль.
old["ModuleOn.sound"] = true
check(run(&old) == nil, "повтор: плана нет")
check(old["ModuleOn.sound"] as? Bool == true, "повтор: выбор человека в Сторе не сброшен")

// Новая установка: только флаг.
var fresh: [String: Any] = ["Theme": "light"]
let freshPlan = run(&fresh)
check(freshPlan?.writes == [flag: true], "новая установка: пишется только флаг")
check(fresh["ModuleOn.sound"] == nil, "новая установка: модули не тронуты")
check(run(&fresh) == nil, "новая установка: повтор ничего не делает")

// Самая старая версия: только ModuleState.*, без ModulesV2.
var ancient: [String: Any] = ["ModuleState.sound": "shown"]
check(run(&ancient) != nil && ancient["ModuleOn.sound"] as? Bool == false, "самая старая версия считается обновлением")

// «Клавиатура»: любое из намерений требует вернуть 🌐.
var keep: [String: Any] = ["ModuleOn.keyboard": true, "Keyboard.KeepSystemFnOff": true]
check(run(&keep)?.restoresSystemFn == true, "KeepSystemFnOff = true: вернуть Fn")
var saved0: [String: Any] = ["ModuleOn.keyboard": true, "Keyboard.SavedFnUsage": 0]
check(run(&saved0)?.restoresSystemFn == true, "SavedFnUsage = 0 (наличие, не Bool): вернуть Fn")
var savedNone: [String: Any] = ["ModuleOn.keyboard": true, "Keyboard.SavedFnUsage": -1]
check(run(&savedNone)?.restoresSystemFn == true, "SavedFnUsage = -1: вернуть Fn")
var dict: [String: Any] = ["ModuleOn.keyboard": true, "Keyboard.SavedDictationEnabled": true]
check(run(&dict)?.restoresSystemFn == true, "диктовка отключена нами: вернуть")
var keepFalse: [String: Any] = ["ModuleOn.keyboard": true, "Keyboard.KeepSystemFnOff": false]
check(run(&keepFalse)?.restoresSystemFn == false, "KeepSystemFnOff = false: Fn не трогаем")
var freshKeep: [String: Any] = ["Keyboard.KeepSystemFnOff": true]
check(run(&freshKeep)?.restoresSystemFn == false, "новая установка: Fn не трогаем")

print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
