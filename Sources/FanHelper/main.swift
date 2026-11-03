import Foundation

// utilitumus-fan — единственный кусок Utilitumus, работающий от root.
// Ставится кнопкой «Дать доступ» в /Library/PrivilegedHelperTools/local.utilitumus.fan
// с setuid root: писать в SMC может только root.
//
// Поверхность намеренно узкая — ни путей, ни шелла, ни окружения:
//   utilitumus-fan auto <fan>        вернуть вентилятор под управление системы
//   utilitumus-fan set <fan> <rpm>   держать обороты (зажимается в Mn…Mx вентилятора)
// <fan> = 0…FNum-1. Код выхода 0 — SMC принял запись и режим перечитан.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// SMC применяет запись не мгновенно: сразу после неё ещё читается старое
/// значение. Ждём до секунды, пока условие не станет правдой.
func waitUntil(_ condition: () -> Bool) -> Bool {
    for _ in 0..<20 {
        if condition() { return true }
        usleep(50_000)
    }
    return false
}

let args = CommandLine.arguments
guard args.count >= 3, let fan = Int(args[2]), fan >= 0 else {
    fail("usage: utilitumus-fan auto <fan> | set <fan> <rpm>")
}
guard let smc = SMC() else { fail("AppleSMC недоступен") }
guard let count = smc.uint8("FNum"), fan < Int(count) else { fail("нет вентилятора \(fan)") }

switch args[1] {
case "auto" where args.count == 3:
    guard smc.setUInt8("F\(fan)Md", 0) else { fail("SMC отклонил запись (нужен root?)") }
    guard waitUntil({ smc.uint8("F\(fan)Md") == 0 }) else { fail("режим не сменился") }

case "set" where args.count == 4:
    guard let requested = Float(args[3]), requested.isFinite,
          let minRPM = smc.float("F\(fan)Mn"), let maxRPM = smc.float("F\(fan)Mx") else {
        fail("некорректные обороты")
    }
    let rpm = min(max(requested, minRPM), maxRPM)
    guard smc.setUInt8("F\(fan)Md", 1), smc.setFloat("F\(fan)Tg", rpm) else {
        fail("SMC отклонил запись (нужен root?)")
    }
    // Ждём и режим, и цель: иначе приложение сразу перечитывает старую цель
    // и шлёт команду снова и снова, пока SMC её не применит.
    guard waitUntil({ smc.uint8("F\(fan)Md") == 1 && abs((smc.float("F\(fan)Tg") ?? -1) - rpm) < 1 }) else {
        fail("режим или цель не применились")
    }

default:
    fail("usage: utilitumus-fan auto <fan> | set <fan> <rpm>")
}
