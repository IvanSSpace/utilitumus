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

print(failed == 0 ? "ВСЕ ТЕСТЫ ПРОШЛИ" : "ПРОВАЛЕНО: \(failed)")
exit(failed == 0 ? 0 : 1)
