import Foundation

// Проверка гистерезиса и сглаживания вентиляторов. Запуск: Tests/run-fan-gate-check.sh
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func send(_ d: Double, last: Double?, ago: TimeInterval?, urgent: Bool = false) -> Bool {
    FanGate.shouldSend(desired: d, lastSent: last, lastSentAt: ago.map { t0.addingTimeInterval(-$0) }, now: t0, urgent: urgent)
}

check(send(3000, last: nil, ago: nil), "нет истории — шлём")
check(!send(3100, last: 3000, ago: 2), "сдвиг 100 за 2 с — молчим")
check(send(3150, last: 3000, ago: 2), "сдвиг 150 — шлём сразу")
check(send(2800, last: 3000, ago: 1), "сдвиг вниз на 200 — шлём")
check(!send(3030, last: 3000, ago: 9.9), "сдвиг 30 за 9.9 с — молчим")
check(send(3030, last: 3000, ago: 10), "сдвиг 30 за 10 с — шлём")
check(!send(3000, last: 3000, ago: 60), "нет отличия — не шлём даже через минуту")
check(send(3010, last: 3000, ago: 0.1, urgent: true), "urgent — без гистерезиса")

// Дрожание цели ±60 вокруг 3000 каждые 2 с: за минуту только по таймеру (раз в 10 с)
var sent = 0, lastRPM: Double? = nil, lastAt: Date? = nil
for k in 0..<30 {
    let now = t0.addingTimeInterval(Double(k) * 2)
    let want = 3000 + (k % 2 == 0 ? 60.0 : -60.0)
    if FanGate.shouldSend(desired: want, lastSent: lastRPM, lastSentAt: lastAt, now: now, urgent: false) {
        sent += 1; lastRPM = want; lastAt = now
    }
}
check(sent <= 7, "шум ±60 за минуту: \(sent) команд вместо 30")

var sm = TempSmoother(size: 4)
check(sm.add(60) == 60, "первое значение")
_ = sm.add(60); _ = sm.add(60)
check(abs(sm.add(80) - 65) < 1e-9, "скачок 60→80 даёт 65 при окне 4")
_ = sm.add(80); _ = sm.add(80)
check(sm.add(80) == 80, "окно сошлось к 80")
check(sm.samples.count == 4, "окно не растёт")
sm.reset()
check(sm.samples.isEmpty, "reset")

print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
