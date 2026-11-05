import Foundation

// Запуск: scripts/test-fn-tap.sh
var failed = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "ok   " : "FAIL ", name)
    if !ok { failed += 1 }
}

/// Сколько раз детектор попросил переключить на этой последовательности.
func fires(_ trigger: FnTrigger, _ events: [FnEvent]) -> Int {
    var d = FnTapDetector(trigger: trigger)
    return events.filter { d.handle($0) }.count
}

let down = FnEvent.fn(down: true, others: false)
let up = FnEvent.fn(down: false, others: false)

check("чистый тап: переключает один раз", fires(.onRelease, [down, up]) == 1)
check("чистый тап: на нажатии ещё нет, только на отпускании", {
    var d = FnTapDetector(trigger: .onRelease)
    return d.handle(down) == false && d.handle(up) == true
}())
check("Fn+←: нет", fires(.onRelease, [down, .keyDown, up]) == 0)
check("Fn+Delete: нет", fires(.onRelease, [down, .keyDown, .keyDown, up]) == 0)
check("Fn+F11 через sysdefined: нет", fires(.onRelease, [down, .sysDefined, .sysDefined, up]) == 0)
check("Fn+Shift (Shift после Fn): нет", fires(.onRelease, [down, .modifier, .modifier, up]) == 0)
check("Shift зажат до Fn: нет", fires(.onRelease, [.modifier, .fn(down: true, others: true), .fn(down: false, others: true), .modifier]) == 0)
check("Fn+клик мыши: нет", fires(.onRelease, [down, .mouseDown, up]) == 0)
check("после грязного нажатия следующий чистый тап работает", fires(.onRelease, [down, .keyDown, up, down, up]) == 1)
check("два чистых тапа подряд: два переключения", fires(.onRelease, [down, up, down, up]) == 2)
check("отпускание без нажатия: нет", fires(.onRelease, [up]) == 0)
check("при нажатии: переключает на down, не на up", {
    var d = FnTapDetector(trigger: .onPress)
    return d.handle(down) == true && d.handle(up) == false
}())
check("при нажатии: Shift был зажат раньше — нет", fires(.onPress, [.fn(down: true, others: true), .fn(down: false, others: true)]) == 0)
check("при нажатии: один тап — одно переключение", fires(.onPress, [down, up]) == 1)

// Выбор раскладки
func picker(_ mode: LayoutMode, _ history: [String]) -> LayoutPicker {
    var p = LayoutPicker()
    p.mode = mode
    history.forEach { p.didChange(to: $0) }
    return p
}
let abc = ["en", "ru", "de"]
check("между двумя: без истории идёт по кругу", picker(.lastTwo, ["en"]).next(in: abc) == "ru")
check("между двумя: возвращается на предыдущую", picker(.lastTwo, ["en", "de"]).next(in: abc) == "en")
check("между двумя: туда-обратно", picker(.lastTwo, ["en", "de", "en"]).next(in: abc) == "de")
check("между двумя: предыдущую выключили — по кругу", picker(.lastTwo, ["en", "de"]).next(in: ["en", "ru"]) == "en")
check("по кругу: игнорирует историю", picker(.cycle, ["en", "de"]).next(in: abc) == "en")
check("по кругу: средняя -> следующая", picker(.cycle, ["en", "ru"]).next(in: abc) == "de")
check("одна раскладка: переключать некуда", picker(.cycle, ["en"]).next(in: ["en"]) == nil)
check("повтор того же id не затирает previous", picker(.lastTwo, ["en", "de", "de"]).next(in: abc) == "en")

// Устаревший current: систему переключили молча (авто-раскладка документа), синхронизируемся перед выбором.
check("устаревший current: без синхронизации выбор = уже стоящая", {
    let p = picker(.lastTwo, ["ru", "en"])  // думаем, что стоит en, до этого был ru
    return p.next(in: abc) == "ru"
}())
check("устаревший current: после синхронизации с реальной переключает", {
    var p = picker(.lastTwo, ["ru", "en"])
    p.didChange(to: "ru")  // реально стоит ru
    return p.next(in: abc) == "en"
}())
check("устаревший current, по кругу: после синхронизации идёт дальше реальной", {
    var p = picker(.cycle, ["en"])
    p.didChange(to: "ru")
    return p.next(in: abc) == "de"
}())

// Когда отключать системное действие 🌐 заново
check("запуск: хотели отключить, система держит 1 — применяем", FnSystemAction.needsReapply(overridden: true, usage: 1))
check("запуск: хотели отключить, ключа нет — применяем", FnSystemAction.needsReapply(overridden: true, usage: nil))
check("запуск: хотели отключить, уже 0 — не трогаем", !FnSystemAction.needsReapply(overridden: true, usage: 0))
check("запуск: не просили отключать — не трогаем", !FnSystemAction.needsReapply(overridden: false, usage: 1))

// Проверка переключения (7)
check("после select: раскладка сменилась — готово", SwitchCheck.after(target: "ru", actual: "ru", retried: false) == .done)
check("после select: не сменилась — повтор", SwitchCheck.after(target: "ru", actual: "en", retried: false) == .retry)
check("после повтора: не сменилась — в журнал", SwitchCheck.after(target: "ru", actual: "en", retried: true) == .failed)
check("после повтора: сменилась — готово", SwitchCheck.after(target: "ru", actual: "ru", retried: true) == .done)
check("раскладку не прочитать — повтор", SwitchCheck.after(target: "ru", actual: nil, retried: false) == .retry)

// Здоровье tap (6)
check("tap жив: ничего не делаем", TapHealth.check(valid: true, enabled: true) == .ok)
check("tap выключен: включить снова", TapHealth.check(valid: true, enabled: false) == .reenable)
check("порт недействителен: пересоздать", TapHealth.check(valid: false, enabled: false) == .rebuild)

// Причина сброса тапа для журнала
check("журнал: Fn+клавиша называет клавишу", {
    var d = FnTapDetector(trigger: .onRelease)
    _ = d.handle(down)
    _ = d.handle(.keyDown)
    return d.cancelledBy == .keyDown
}())
check("журнал: чистый тап ничего не сбрасывает", {
    var d = FnTapDetector(trigger: .onRelease)
    _ = d.handle(down)
    _ = d.handle(up)
    return d.cancelledBy == nil
}())
check("журнал: набор без Fn не сбрасывает", {
    var d = FnTapDetector(trigger: .onRelease)
    _ = d.handle(.keyDown)
    return d.cancelledBy == nil
}())
check("журнал: вторая клавиша под Fn уже не повод писать", {
    var d = FnTapDetector(trigger: .onRelease)
    _ = d.handle(down)
    _ = d.handle(.keyDown)
    _ = d.handle(.keyDown)
    return d.cancelledBy == nil
}())

// Диктовка на двойном Fn (11)
let dictOn: [String: Any] = ["164": ["enabled": 1, "value": ["type": "modifier", "parameters": [0x800000, 0, 0]]]]
check("диктовка: на двойном Fn распознана", FnSystemAction.isDictationOnDoubleFn(dictOn))
check("диктовка: выключение меняет только enabled", {
    guard let off = FnSystemAction.settingEnabled(dictOn, id: "164", to: false),
          let item = off["164"] as? [String: Any] else { return false }
    return (item["enabled"] as? NSNumber)?.boolValue == false && (item["value"] as? [String: Any])?["type"] as? String == "modifier"
        && !FnSystemAction.isDictationOnDoubleFn(off)
}())
check("диктовка: возврат восстанавливает", {
    let off = FnSystemAction.settingEnabled(dictOn, id: "164", to: false)
    return FnSystemAction.isDictationOnDoubleFn(FnSystemAction.settingEnabled(off, id: "164", to: true))
}())
check("диктовка: нет ключа 164 — nil", FnSystemAction.settingEnabled([:], id: "164", to: false) == nil)

// Журнал: память, файл, права, ротация
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kblog-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("keyboard.log")
    let log = KeyboardLog(fileURL: url)
    for i in 0..<3000 { log.add("запись \(i) " + String(repeating: "x", count: 80)) }
    log.flush()
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? Int) ?? -1
    check("журнал: в памяти последние 50", log.count == 50 && log.recent().last?.text.hasPrefix("запись 2999") == true)
    check("журнал: права файла 0600", (attrs?[.posixPermissions] as? Int) == 0o600)
    check("журнал: файл не больше ~200 КБ", size > 0 && size <= KeyboardLog.maxFileBytes + 200)
    let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    check("журнал: ротация оставила свежее и целые строки", content.hasSuffix("x\n") && content.contains("запись 2999")
          && content.split(separator: "\n").first?.contains("запись") == true)
    check("журнал: copy-текст — 50 строк", log.text().split(separator: "\n").count == 50)
    try? FileManager.default.removeItem(at: dir)
}

print(failed == 0 ? "ВСЕ ТЕСТЫ ПРОШЛИ" : "ПРОВАЛЕНО: \(failed)")
exit(failed == 0 ? 0 : 1)
