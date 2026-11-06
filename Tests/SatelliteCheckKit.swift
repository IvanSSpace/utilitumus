import AppKit

// Общая часть проверок модулей: журнал результатов, ожидания и связь с настоящей утилитой под launchd.
// Не знает о центре: годится и для лёгких стендов. Экран и снимки — в SatelliteStandKit.swift.

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func finish() -> Never {
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline { await pause(0.02) }
    return condition()
}

/// Насколько надолго занят главный поток.
@MainActor final class TickWatch {
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var maxGap = 0.0
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.maxGap = max(self.maxGap, now - self.last)
                self.last = now
            }
        }
    }
    deinit { timer?.invalidate() }
}

/// Убить утилиту насовсем. Одного SIGKILL мало: метка launchd держит сервис, и первое же сообщение центра поднимает
/// утилиту заново, как в жизни. Поэтому сразу после SIGKILL метку снимают; между двумя вызовами главный поток не отпускается.
/// Метку и домен даёт скрипт: `SATELLITE_CHECK_LABEL`, `SATELLITE_CHECK_DOMAIN`.
@MainActor func killUtilityForGood(_ pid: Int32) {
    kill(pid, SIGKILL)
    let env = ProcessInfo.processInfo.environment
    guard let label = env["SATELLITE_CHECK_LABEL"], let domain = env["SATELLITE_CHECK_DOMAIN"] else {
        return check(false, "killUtilityForGood: скрипт не передал метку launchd")
    }
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "\(domain)/\(label)"]
    try? bootout.run()
    bootout.waitUntilExit()
}

/// Плохие действия, общие для всех модулей. Модуль добавляет свои через `extra`.
let badActionsForAnyModule: [(String, Data)] = [
    ("мусор", Data("{не json".utf8)),
    ("пустое", Data()),
    ("неизвестное действие", Data(#"{"explode":{}}"#.utf8)),
    ("пустой объект", Data("{}".utf8)),
    ("массив", Data("[1]".utf8)),
    ("слишком длинное", Data(#"{"x":""#.utf8) + Data(repeating: 0x61, count: 100_000) + Data(#""}"#.utf8)),
]

/// Мусор доходит до утилиты: ответ — ошибка, состояние то же.
@MainActor func checkBadActions<State: Codable & Equatable>(_ state: State.Type, id: String, extra: [(String, Data)] = []) async {
    let link = LinkClient(id: id)
    guard let before = try? await link.moduleState(), let known = try? JSONDecoder().decode(State.self, from: before) else {
        return check(false, "мусор: состояние не прочитано")
    }
    for (name, payload) in badActionsForAnyModule + extra {
        do {
            let reply = try JSONDecoder().decode(LinkReply<State>.self, from: await link.moduleAction(payload))
            check(reply.error != nil, "\(name): ошибка («\(reply.error ?? "нет")»)")
            check(reply.state == known, "\(name): в ответе прежнее состояние")
        } catch {
            check(false, "\(name): \(error)")
        }
        let after = try? await link.moduleState()
        check(after == before, "\(name): состояние не изменилось, байт в байт")
    }
}

/// Роли процессов, общие для всех проверок: `foreign` — действие от чужой подписи, `state` — состояние строкой.
/// Возвращает false, если роль не из них.
@MainActor func runCommonRole(_ role: String, id: String, foreignAction: Data) async -> Bool {
    switch role {
    case "foreign":
        do {
            _ = try await LinkClient(id: id).moduleAction(foreignAction)
            print("прошло")
            exit(0)
        } catch {
            print("отказ: \(error)")
            exit(3)
        }
    case "state":
        // Канонический вид: скрипт сравнивает строки.
        print(String(decoding: (try? await LinkClient(id: id).moduleState()) ?? Data(), as: UTF8.self))
        exit(0)
    default:
        return false
    }
}
