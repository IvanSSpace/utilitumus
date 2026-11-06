import AppKit
import Darwin

// Что считается нашим: точный список, а не префикс. Запуск: Tests/run-own-identity-check.sh
// Настройки, настоящие утилиты и процессы не трогаются: два настоящих процесса-заглушки поднимает скрипт, лаунчер только читается.

var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}

guard CommandLine.arguments.count >= 3, let oursPid = Int32(CommandLine.arguments[1]), let evilPid = Int32(CommandLine.arguments[2]) else {
    print("Использование: check <pid заглушки с нашим id> <pid заглушки-подделки> [id из сборочных файлов...]")
    exit(2)
}
let realIDs = CommandLine.arguments.dropFirst(3)

// MARK: Список

check("точный размер: 4 + все модули", Kit.ownBundleIDs.count == 4 + Module.allCases.count, "\(Kit.ownBundleIDs.sorted())")
for id in ["local.utilitumus", "local.utilitumus.links", "local.utilitumus.fan", "local.utilitumus.voice"] {
    check("наш: \(id)", Kit.isOurs(id))
}
for module in Module.allCases { check("утилита модуля \(module.id)", Kit.isOurs("local.utilitumus.app.\(module.id)")) }
check("id из сборочных файлов переданы", !realIDs.isEmpty)
for id in realIDs { check("из сборочных файлов: \(id)", Kit.isOurs(id)) }

let lookalikes = [
    "local.utilitumus.evil", "local.utilitumus.app.x.y", "local.utilitumus.app.sound.evil", "local.utilitumus.app.fans.evil",
    "local.utilitumus.app.", "local.utilitumus.app", "local.utilitumus.app.nosuchmodule", "local.utilitumus.app.Sound",
    "local.utilitumus.selftest", "local.utilitumus.test.awake", "local.utilitumus.test.kit", "local.utilitumus.clipboard",
    "local.utilitumus.fan.xpc", "local.utilitumus.app.awake.xpc", "xlocal.utilitumus", "local.utilitumusx",
    "LOCAL.UTILITUMUS", "local.utilitumus ", " local.utilitumus", "local.utilitumus\n", "", "com.apple.finder", "com.google.Chrome",
]
for id in lookalikes { check("не наш: \(id.debugDescription)", !Kit.isOurs(id)) }
check("nil не наш", !Kit.isOurs(nil))

// MARK: Стеш

MainActor.assumeIsolated {
    for id in Kit.ownBundleIDs { check("Стеш не закрывает \(id)", !StashStore.isEligible(bundleID: id)) }
    check("Стеш не закрывает Finder", !StashStore.isEligible(bundleID: "com.apple.finder"))
    for id in lookalikes where id != "com.apple.finder" {
        check("Стеш может закрыть чужое \(id.debugDescription)", StashStore.isEligible(bundleID: id))
    }
}

// MARK: Агенты Нагрузки

func refused(_ label: String) -> String? { LaunchAgents.whyRefused(label: label, domain: "gui", botLabels: [], appleService: false) }
for id in Kit.ownBundleIDs { check("Нагрузка не останавливает агента \(id)", refused(id) == "это сама панель", refused(id) ?? "nil") }
for id in lookalikes { check("чужой агент \(id.debugDescription) не защищён как наш", refused(id) == nil, refused(id) ?? "") }

// MARK: Процессы Нагрузки: настоящие приложения с нашим id и с похожим

// Список приложений обновляется главным циклом, заглушке нужно время подняться.
func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
}

check("заглушка видна с нашим id", waitUntil { NSRunningApplication(processIdentifier: oursPid)?.bundleIdentifier == "local.utilitumus.app.sound" })
check("заглушка-подделка видна со своим id", waitUntil { NSRunningApplication(processIdentifier: evilPid)?.bundleIdentifier == "local.utilitumus.evil" })
check("своё приложение среди своих процессов", waitUntil { Protection.ownPids().contains(oursPid) })
check("подделка не среди своих процессов", !Protection.ownPids().contains(evilPid))

func process(pid: Int32) -> LoadProcess {
    LoadProcess(pid: pid, ppid: 1, user: getuid(), uniqueID: 1, startTime: 0, name: "stub", exe: "/Users/u/stub/stub",
                exeName: "stub", isClaude: false, terminal: nil, cwd: nil, args: [], tty: nil, memMB: 1, residentMB: 1, wiredMB: nil,
                compressedMB: 0, readable: true, pgid: pid, tpgid: 0, cpuPercent: nil)
}
let procs = [oursPid: process(pid: oursPid), evilPid: process(pid: evilPid)]
let tree = ProcessTree(procs)
// Как в настоящем вызове: без подстановки, список берётся у системы.
let fence = Protection.fence(procs: procs, tree: tree)
check("свой процесс за оградой", fence[oursPid] == "компонент Utilitumus", fence[oursPid] ?? "nil")
check("подделка не за оградой", fence[evilPid] == nil, fence[evilPid] ?? "")
let planner = StopPlanner(procs: procs, fence: fence, tree: tree)
check("свой процесс остановить нельзя", !planner.canStop(procs[oursPid]!) && planner.plan(process: oursPid) == nil)
check("подделку остановить можно", planner.canStop(procs[evilPid]!) && planner.plan(process: evilPid) != nil)

let own = Protection.fence(procs: [:], tree: ProcessTree([:]), selfPid: oursPid, ownPids: [oursPid])
check("причина у самой панели прежняя", own[oursPid] == "это сама панель", own[oursPid] ?? "nil")

// Настоящий лаунчер только читается: запущен ли он, зависит от Mac, где идёт проверка.
if let hub = NSRunningApplication.runningApplications(withBundleIdentifier: Kit.hubBundleID).first {
    check("запущенный лаунчер pid \(hub.processIdentifier) среди своих", Protection.ownPids().contains(hub.processIdentifier))
    check("лаунчер за оградой", Protection.fence(procs: [:], tree: ProcessTree([:]))[hub.processIdentifier] != nil)
} else {
    print("     лаунчер здесь не запущен, эта часть не проверялась")
}

exit(failed ? 1 : 0)
