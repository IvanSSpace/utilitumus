import Darwin
import Foundation

// Модуль «Нагрузка»: защита от остановки и подписи агентов не верят тому, что процесс и агент пишут о себе сами.

var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}

func process(name: String, exe: String, args: [String] = [], pid: Int32 = 500, cwd: String? = nil) -> LoadProcess {
    LoadProcess(pid: pid, ppid: 1, user: getuid(), uniqueID: 1, startTime: 0, name: name, exe: exe,
                exeName: String(exe.split(separator: "/").last ?? ""), isClaude: false,
                terminal: Kinds.terminalApp(exe: exe), cwd: cwd, args: args, tty: nil, memMB: 1, residentMB: 1, wiredMB: nil, compressedMB: 0,
                readable: true, pgid: pid, tpgid: 0, cpuPercent: nil)
}
func why(_ p: LoadProcess, root: Bool = true) -> String? { Protection.why(p, fence: [:], root: root) }

// MARK: Бот только для наблюдения

do {
    var watched = BotSpec.none
    watched.id = "procbot"
    watched.name = "Процесс"
    watched.watchDir = "/p/procbot"
    let bot = process(name: "python3", exe: "/usr/bin/python3", pid: 700, cwd: "/p/procbot")
    let shell = process(name: "zsh", exe: "/bin/zsh", pid: 701, cwd: "/p/procbot")
    let elsewhere = process(name: "python3", exe: "/usr/bin/python3", pid: 702, cwd: "/p/other")
    let procs = [bot.pid: bot, shell.pid: shell, elsewhere.pid: elsewhere]
    let tree = ProcessTree(procs)
    let up = BotRegistry.status(watched, procs: procs, tree: tree, launchd: [:])
    check("бот с watch_dir работает: «Нагрузка» не пишет «Остановлен»", up.state == .running && up.pids == [700], "\(up.state) \(up.pids)")
    let fence = BotRegistry.fence([watched], procs: procs, tree: tree, launchd: [:])
    check("процесс бота с watch_dir защищён от остановки", fence[700] != nil, "\(fence)")
    check("оболочка и чужая папка под защиту не попали", fence[701] == nil && fence[702] == nil, "\(fence)")
    let down = BotRegistry.status(watched, procs: [shell.pid: shell], tree: ProcessTree([shell.pid: shell]), launchd: [:])
    check("процесса нет: бот остановлен", down.state == .stopped, "\(down.state)")
}

// MARK: Имя процесса

let dock = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
check("настоящий Dock защищён", why(process(name: "Dock", exe: dock)) == "системный процесс")
check("настоящий WindowServer защищён", why(process(name: "WindowServer",
      exe: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer")) == "системный процесс")
check("чужая программа с argv[0] Dock не защищена", why(process(name: "Dock", exe: "/Users/u/bin/x")) == nil)
check("чужой файл с именем Dock не защищён", why(process(name: "Dock", exe: "/Users/u/bin/Dock")) == nil)
check("Dock из /usr/local не защищён", why(process(name: "Dock", exe: "/usr/local/bin/Dock")) == nil)
let firmlink = "/System/Volumes/Data/Users/u/bin/Dock"
check("Dock через /System/Volumes/Data не защищён", why(process(name: "Dock", exe: firmlink)) == nil, why(process(name: "Dock", exe: firmlink)) ?? "")
check("системный файл по-прежнему не цель", why(process(name: "sleep", exe: "/usr/bin/sleep")) == "системный файл")
check("но потомком цели останавливается", why(process(name: "sleep", exe: "/usr/bin/sleep"), root: false) == nil)
check("шелл по-прежнему цель", why(process(name: "zsh", exe: "/bin/zsh")) == nil)
check("без пути по-прежнему не трогаем", why(process(name: "Dock", exe: "")) == "не удалось прочитать путь")

// MARK: Хост вкладок терминала

let iterm = "/Applications/iTerm.app/Contents/MacOS/iTerm2"
let server = "/Users/u/Library/Application Support/iTerm2/iTermServer-3.5.14"
let orca = "/Users/u/Library/Application Support/orca/daemon-host/macos/terminal-host-1/app.noindex/Orca Terminal Host.app/Contents/MacOS/orca-terminal-host"
let terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
check("iTerm2", Kinds.terminalApp(exe: iterm) == "iTerm2")
check("сервер iTerm2", Kinds.terminalApp(exe: server) == "iTerm2")
check("сервер iTerm2 внутри бандла", Kinds.terminalApp(exe: "/Applications/iTerm.app/Contents/MacOS/iTermServer") == "iTerm2")
check("хост Orca", Kinds.terminalApp(exe: orca) == "Orca")
check("Terminal", Kinds.terminalApp(exe: terminal) == "Terminal")
check("хост защищён от остановки", why(process(name: "iTermServer-3.5.14", exe: server)) == "хост вкладок терминала")
check("argv[0] iTermServer-1 не делает хостом", why(process(name: "iTermServer-1", exe: "/Users/u/bin/x")) == nil)
check("файл iTermServer-1 в чужой папке не хост", Kinds.terminalApp(exe: "/Users/u/bin/iTermServer-1") == nil)
check("файл orca-terminal-host в чужой папке не хост", Kinds.terminalApp(exe: "/Users/u/bin/orca-terminal-host") == nil)

// MARK: Метки com.apple.

func apple(_ label: String, plist: String? = nil, exe: String? = nil) -> Bool {
    LaunchAgents.isAppleService(label: label, plist: plist, exe: exe)
}
check("plist из /System/Library — служба macOS", apple("com.apple.x", plist: "/System/Library/LaunchAgents/com.apple.x.plist"))
check("plist в LaunchAgents пользователя — нет", !apple("com.apple.x", plist: "/Users/u/Library/LaunchAgents/com.apple.x.plist"))
check("plist в /Library/LaunchAgents — нет", !apple("com.apple.x", plist: "/Library/LaunchAgents/com.apple.x.plist"))
check("без plist с программой из системы — служба (mdworker, XPC)",
      apple("com.apple.mdworker.shared.1", exe: "/System/Library/Frameworks/CoreServices.framework/mdworker_shared"))
check("без plist с программой из /usr/libexec — служба", apple("com.apple.dmd", exe: "/usr/libexec/dmd"))
check("без plist с чужой программой — нет", !apple("com.apple.x", exe: "/Users/u/bin/x"))
check("без plist через /System/Volumes/Data — нет", !apple("com.apple.x", exe: firmlink))
check("без plist и процесса скрывать нечего", apple("com.apple.x"))
check("чужая метка службой macOS не бывает", !apple("com.logi.x", plist: "/System/Library/LaunchAgents/x.plist"))
check("службу macOS не трогаем", LaunchAgents.whyRefused(label: "com.apple.x", domain: "gui", botLabels: [], appleService: true) == "служба macOS")
check("метка com.apple. с чужим plist управляется как обычный агент",
      LaunchAgents.whyRefused(label: "com.apple.x", domain: "gui", botLabels: [], appleService: false) == nil)

// MARK: Производитель

let home = NSHomeDirectory()
func vendor(_ label: String, _ program: String) -> String { LaunchAgents.vendor(of: label, program: program).vendor }
check("Logitech", vendor("com.logi.optionsplus", "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent") == "Logitech")
check("Google из домашней папки", vendor("com.google.GoogleUpdater.wake", home + "/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater") == "Google")
check("Keystone", vendor("com.google.keystone.agent", home + "/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent") == "Google")
check("Zoom", vendor("us.zoom.updater", "/Applications/zoom.us.app/Contents/Library/LaunchAgents/ZoomUpdater.app/Contents/MacOS/ZoomUpdater") == "Zoom")
check("Zoom, служба", vendor("us.zoom.ZoomDaemon", "/Library/PrivilegedHelperTools/us.zoom.ZoomDaemon") == "Zoom")
check("Steam", vendor("com.valvesoftware.steamclean", home + "/Library/Application Support/Steam/SteamApps/steamclean") == "Steam")
check("Adobe", vendor("com.adobe.ccxprocess", "/Applications/Utilities/Adobe Creative Cloud Experience/CCXProcess/CCXProcess.app/Contents/MacOS/CCXProcess") == "Adobe")
check("Microsoft", vendor("com.microsoft.update.agent", "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant.app/Contents/MacOS/Microsoft Update Assistant") == "Microsoft")
check("Rogue Amoeba", vendor("com.rogueamoeba.arkaudiod", "/Library/Audio/Plug-Ins/HAL/ARK.driver/Contents/Resources/Audio Routing Kit (ARK).app/Contents/MacOS/arkaudiod") == "Rogue Amoeba")
check("Rogue Amoeba из домашней папки", vendor("com.rogueamoeba.loopbackd", home + "/Library/Application Support/Loopback/Loopback.app/Contents/MacOS/Loopback") == "Rogue Amoeba")
check("метка Logitech с чужой программой без подписи", vendor("com.logi.x", "/Users/u/bin/x") == "")
check("метка Logitech с программой Google без подписи", vendor("com.logi.x", "/Library/Application Support/Google/x") == "")
check("обход через .. без подписи", vendor("com.logi.x", "/Applications/logi/../../tmp/x") == "")
check("нет программы — нет подписи", vendor("com.logi.x", "") == "")
check("без подписи — общая заметка", LaunchAgents.vendor(of: "com.logi.x", program: "/tmp/x").note == LaunchAgents.unknown)

// MARK: Журнал действий

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let secrets = ["hunter2", "-psecret", "bob:pw"]
let sshpass = process(name: "sshpass", exe: "/Users/u/bin/sshpass", args: ["sshpass", "-p", "hunter2", "ssh", "bob:pw", "-psecret"], pid: 700)
check("подпись для экрана по-прежнему с аргументами", Kinds.label(sshpass).contains("ssh"))
if let plan = StopPlanner(procs: [sshpass.pid: sshpass], fence: [:]).plan(process: sshpass.pid) {
    let data = try! JSONSerialization.data(withJSONObject: ActionLog.targets(of: plan))
    let text = String(decoding: data, as: UTF8.self)
    check("в журнал идут только pid и имя", ActionLog.targets(of: plan).first?["name"] as? String == "sshpass", text)
    check("аргументов в журнале нет", !secrets.contains { text.contains($0) }, text)
    check("заголовок записи без аргументов", !secrets.contains { plan.title.contains($0) }, plan.title)
} else {
    check("план остановки составлен", false)
}

let log = work.appendingPathComponent("actions.log")
let line = "{\"строка\":\"" + String(repeating: "x", count: 90) + "\"}\n"
try! Data(String(repeating: line, count: 3000).utf8).write(to: log)
try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
let before = try! Data(contentsOf: log)
ActionLog.rotateIfNeeded(log, limit: before.count)
check("ровно на пределе файл не трогаем", try! Data(contentsOf: log) == before)
ActionLog.rotateIfNeeded(log, limit: before.count - 1)
let after = try! Data(contentsOf: log)
check("больше предела: остаётся половина", after.count <= before.count / 2 && after.count > before.count / 3, "\(after.count)")
check("остаётся хвост и целыми строками", after.first == UInt8(ascii: "{") && after.last == 0x0A
      && String(decoding: after, as: UTF8.self).split(separator: "\n").allSatisfy { $0.hasSuffix("\"}") })
let mode = (try! FileManager.default.attributesOfItem(atPath: log.path))[.posixPermissions] as? Int
check("права журнала остаются 0600", mode == 0o600, String(mode ?? -1, radix: 8))
ActionLog.rotateIfNeeded(work.appendingPathComponent("нет-файла"))
check("нет файла: не падаем и не создаём", !FileManager.default.fileExists(atPath: work.appendingPathComponent("нет-файла").path))

exit(failed ? 1 : 0)
