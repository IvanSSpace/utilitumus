import Foundation
import ObjectiveC

// Направление версии помощника вентиляторов. Запуск: Tests/run-fan-version-check.sh
// Служба здесь — строка в таблице: ни XPC, ни установки, ни пароля.

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let good = (binary: (owner: 0, mode: 0o755) as FanHelperInstaller.FileInfo?, plist: (owner: 0, mode: 0o644) as FanHelperInstaller.FileInfo?)

@MainActor func spin(_ seconds: TimeInterval = 0.15) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func matrix() {
    let table: [(service: String, client: String, expected: FanHelperInstaller.Status)] = [
        ("4", "4", .ready),
        ("5", "4", .ready),
        ("40", "5", .ready),
        ("10", "9", .ready),
        ("3", "4", .outdated),
        ("9", "10", .outdated),
        ("", "4", .outdated),
        ("abc", "4", .outdated),
        ("4.1", "4", .outdated),
        ("99999999999999999999", "4", .outdated),
    ]
    for row in table {
        check(FanHelperInstaller.status(service: row.service, client: row.client) == row.expected,
              "служба «\(row.service)», клиент \(row.client): \(row.expected)")
    }
    check(!FanLink.helperVersion.isEmpty && FanLink.helperVersion.allSatisfy { "0123456789".contains($0) }, "helperVersion — целое число: \(FanLink.helperVersion)")
}

/// Служба одна, клиентов два, каждый со своей вшитой версией. Плашка видна — пользователь вводит пароль: так считаются запросы.
/// «Установка» здесь пишет вшитую версию, понижение отвергает скрипт, его проверяет shell-часть.
@MainActor func twoClients(installed start: String, first: String, second: String, firstLoads: Bool) -> (prompts: Int, installed: String) {
    final class Box: @unchecked Sendable { var version: String; init(_ v: String) { version = v } }
    let service = Box(start)
    func client(_ version: String) -> FanHelperInstaller {
        let installer = FanHelperInstaller(files: { good }, probeVersion: { service.version }, clientVersion: version, retryDelay: 0.01)
        installer.moduleRunning = true
        return installer
    }
    let a = client(first), b = client(second)
    var prompts = 0
    for _ in 0..<6 {
        for (installer, version) in (firstLoads ? [(a, first), (b, second)] : [(b, second), (a, first)]) {
            installer.refresh()
            spin(0.05)
            if installer.status == .outdated {
                prompts += 1
                service.version = version
            }
        }
    }
    return (prompts, service.version)
}

@MainActor func clients() {
    let oldFirst = twoClients(installed: "4", first: "4", second: "5", firstLoads: true)
    check(oldFirst.prompts == 1 && oldFirst.installed == "5", "стоит 4, клиенты 4 и 5: один запрос пароля за 6 кругов (\(oldFirst.prompts)), стоит 5")
    let newFirst = twoClients(installed: "4", first: "4", second: "5", firstLoads: false)
    check(newFirst.prompts == 1 && newFirst.installed == "5", "то же в другом порядке (\(newFirst.prompts))")
    let older = twoClients(installed: "3", first: "4", second: "5", firstLoads: true)
    check(older.prompts <= 2 && older.installed == "5", "стоит 3, клиенты 4 и 5: только вверх, не больше двух запросов (\(older.prompts))")
    let same = twoClients(installed: "5", first: "4", second: "5", firstLoads: true)
    check(same.prompts == 0, "стоит 5, клиенты 4 и 5: запросов нет (\(same.prompts))")

    // Живой клиент старше службы: плашки нет, управление есть.
    let old = FanHelperInstaller(files: { good }, probeVersion: { "5" }, clientVersion: "4", retryDelay: 0.01)
    old.moduleRunning = true
    old.refresh()
    spin()
    check(old.status == .ready && old.serviceAnswered, "клиент 4, служба 5: ready")
    let new = FanHelperInstaller(files: { good }, probeVersion: { "4" }, clientVersion: "5", retryDelay: 0.01)
    new.moduleRunning = true
    new.refresh()
    spin()
    check(new.status == .outdated && new.serviceAnswered, "клиент 5, служба 4: outdated, но «Авто» ей отдать можно")

    // По умолчанию клиент — своя вшитая версия.
    let own = FanHelperInstaller(files: { good }, probeVersion: { FanLink.helperVersion }, retryDelay: 0.01)
    own.moduleRunning = true
    own.refresh()
    spin()
    check(own.status == .ready, "своя версия: ready")
}

/// Служба новее обязана понимать старых клиентов, старая — новых настолько, насколько клиент её зовёт.
/// Список ниже только растёт: новый метод дописывается, менять и убирать строки нельзя.
func protocolIsAppendOnly() {
    let frozen = [
        "versionWithReply: v24@0:8@?16",
        "setAuto:reply: v32@0:8q16@?24",
        "setRPM::reply: v40@0:8q16d24@?32",
    ]
    var count: UInt32 = 0
    let methods = protocol_copyMethodDescriptionList(FanHelperXPC.self as Protocol, true, true, &count)
    defer { free(methods) }
    var actual = Set<String>()
    for index in 0..<Int(count) {
        let method = methods![index]
        actual.insert("\(NSStringFromSelector(method.name!)) \(String(cString: method.types!))")
    }
    for method in frozen {
        check(actual.contains(method), "служба принимает прежний вызов: \(method) (есть: \(actual.sorted()))")
    }
}

/// Отказ установки должен дойти до скрипта: подпись новой копии проверяется до сравнения версий.
func scriptOrder() {
    let script = FanHelperInstaller.installScript(source: "/x/utilitumus-fan", helperVersion: "4")
    func at(_ needle: String) -> String.Index? { script.range(of: needle)?.lowerBound }
    guard let verifyNew = at("\"$T\""), let copyOld = at("\"$O\" 2>/dev/null"), let verifyOld = at("\"$O\") 2>/dev/null"),
          let runOld = at("\"$O\" version"), let move = at("/bin/mv -f") else {
        return check(false, "в скрипте нет шагов сравнения версий")
    }
    check(verifyNew < copyOld, "сравнение после проверки новой копии")
    check(copyOld < verifyOld && verifyOld < runOld, "установленный файл: копия, подпись, только потом запуск")
    check(runOld < move, "сравнение раньше замены файла")
    check(script.contains("'4'"), "сравнение с версией клиента")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "logic":
    matrix()
    // Без await: задачи главного актора идут, только пока главный поток крутит RunLoop вне другой задачи.
    MainActor.assumeIsolated { clients() }
    protocolIsAppendOnly()
    scriptOrder()
    print(failures == 0 ? "логика: ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
case "print-install":
    print(FanHelperInstaller.adminCommand(FanHelperInstaller.installScript(source: args[1], helperVersion: args[2])))
default:
    print("logic | print-install <файл> <версия>")
    exit(64)
}
