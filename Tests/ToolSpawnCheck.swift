import Darwin
import Foundation

// Запуск внешних программ: снятие ответственности, вывод, тайм-аут, окружение, сокет tmux.
// Разрешения macOS здесь не измеряются: дочерний процесс сам сообщает, кто за него отвечает.

var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}

let args = CommandLine.arguments
let child = args[1]   // печатает «свой pid ответственный pid»
let work = args[2]

nonisolated(unsafe) var disclaimCalls: [Int32] = []
let counting: Tool.Disclaim = { attr, value in
    disclaimCalls.append(value)
    return Tool.systemDisclaim!(attr, value)
}
let noop: Tool.Disclaim = { _, _ in 0 }
let refusing: Tool.Disclaim = { _, _ in 1 }

func responsible(_ output: String?) -> (own: Int, by: Int)? {
    let parts = output?.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } ?? []
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}

// MARK: Снятие ответственности

check("функция снятия ответственности найдена", Tool.systemDisclaim != nil)
let disclaimed = responsible(Tool.run(child, [], timeout: 5, disclaim: counting))
check("запуск вызывает снятие ответственности один раз со значением 1", disclaimCalls == [1], "\(disclaimCalls)")
check("процесс отвечает сам за себя", disclaimed.map { $0.own == $0.by } == true, "\(String(describing: disclaimed))")
let plain = responsible(Tool.run(child, [], timeout: 5, disclaim: noop))
check("без снятия за процесс отвечает родитель (стенд видит разницу)", plain.map { $0.own != $0.by } == true,
      "\(String(describing: plain))")
let byDefault = responsible(Tool.run(child, [], timeout: 5))
check("обычный вызов Tool.run снимает ответственность", byDefault.map { $0.own == $0.by } == true,
      "\(String(describing: byDefault))")

// MARK: Функции нет

let marker = work + "/marker"
let script = work + "/tool.sh"
try! "#!/bin/sh\n/usr/bin/touch \"$1\"\necho ran\n".write(toFile: script, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
check("сторонняя программа без функции не запускается", Tool.run(script, [marker], timeout: 5, disclaim: nil) == nil)
check("и её файл не тронут", !FileManager.default.fileExists(atPath: marker))
check("функция вернула ошибку: программа не запускается", Tool.run(script, [marker], timeout: 5, disclaim: refusing) == nil)
check("и её файл не тронут (ошибка)", !FileManager.default.fileExists(atPath: marker))
check("системная программа без функции работает", Tool.run("/bin/echo", ["да"], timeout: 5, disclaim: nil) == "да\n")
check("/usr/local не считается защищённым", !Tool.isSealed("/usr/local/bin/tmux"))
check("обход через .. не считается защищённым", !Tool.isSealed("/usr/../private/tmp/x"))

// MARK: Вывод, код выхода, тайм-аут, окружение

check("нет файла: nil", Tool.run(work + "/нет-такого", [], timeout: 1) == nil)
check("вывод возвращается", Tool.run("/bin/echo", ["привет"], timeout: 5) == "привет\n")
check("код выхода не важен", Tool.run("/bin/sh", ["-c", "echo часть; exit 4"], timeout: 5) == "часть\n")
let big = Tool.run("/bin/sh", ["-c", "/usr/bin/yes line | /usr/bin/head -c 1000000"], timeout: 10)
check("большой вывод не упирается в буфер пайпа", big?.utf8.count == 1_000_000, "\(big?.utf8.count ?? -1)")
check("stderr не попадает в вывод", Tool.run("/bin/sh", ["-c", "echo ошибка >&2"], timeout: 5) == "")
let started = Date()
check("тайм-аут: nil", Tool.run("/bin/sleep", ["30"], timeout: 0.3) == nil)
check("тайм-аут не ждёт конца программы", Date().timeIntervalSince(started) < 5)
check("чистое окружение пусто", Tool.run("/usr/bin/env", [], timeout: 5, environment: []) == "")
setenv("TOOL_CHECK_SECRET", "значение", 1)
check("обычное окружение наследуется", Tool.run("/usr/bin/env", [], timeout: 5)?.contains("TOOL_CHECK_SECRET") == true)
dup2(STDERR_FILENO, 50) // без CLOEXEC, как дескриптор, открытый где-то в приложении
let fds = Tool.run("/bin/ls", ["/dev/fd"], timeout: 5)?.split(separator: "\n").compactMap { Int($0) } ?? []
check("дескрипторы приложения не наследуются", fds.contains(1) && !fds.contains(50), "\(fds)")
close(50)

// MARK: Настоящие программы (только чтение)

check("launchctl list отвечает", Tool.run("/bin/launchctl", ["list"], timeout: 10)?.contains("PID") == true)
check("launchctl print-disabled отвечает",
      Tool.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"], timeout: 10)?.contains("disabled") == true)
check("ioreg отвечает", Tool.run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOBlockStorageDriver", "-d", "2", "-l"], timeout: 10)?.isEmpty == false)
check("top отвечает", Tool.run("/usr/bin/top", ["-l", "1", "-stats", "pid,mem,cmprs"], timeout: 30)?.contains("PID") == true)
for smartctl in ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl"] where FileManager.default.isExecutableFile(atPath: smartctl) {
    check("smartctl отвечает", Tool.run(smartctl, ["-a", "disk0"], timeout: 10)?.contains("smartctl") == true)
}

// MARK: Сокет tmux

FileManager.default.changeCurrentDirectoryPath(work)
func listen(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { strlcpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path)) }
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    return fd
}
try! FileManager.default.createDirectory(atPath: "own", withIntermediateDirectories: true)
let fd = listen("own/default")
check("свой каталог и свой сокет подходят", MuxProbe.isOwnSocket("own/default"))
check("чужой владелец не подходит", !MuxProbe.isOwnSocket("own/default", uid: getuid() + 1))
check("нет сокета: не подходит", !MuxProbe.isOwnSocket("own/none"))
try! "".write(toFile: "own/file", atomically: true, encoding: .utf8)
check("обычный файл вместо сокета не подходит", !MuxProbe.isOwnSocket("own/file"))
try! FileManager.default.createSymbolicLink(atPath: "own/link", withDestinationPath: "default")
check("ссылка на сокет не подходит", !MuxProbe.isOwnSocket("own/link"))
try! FileManager.default.createSymbolicLink(atPath: "linkdir", withDestinationPath: "own")
check("ссылка вместо каталога не подходит", !MuxProbe.isOwnSocket("linkdir/default"))
close(fd)

if let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
    // Только свой сервер стенда на своём сокете. Сессию имя стенда отличает от настоящих.
    let sock = "t.sock"
    _ = Tool.run(tmux, ["-u", "-S", sock, "new-session", "-d", "-s", "работа-стенд"], timeout: 5,
                 environment: ["LC_ALL=en_US.UTF-8", "PATH=/usr/bin:/bin", "SHELL=/bin/sh", "HOME=" + work])
    let listed = Tool.run(tmux, MuxProbe.tmuxArguments(socket: sock), timeout: 3, environment: [])
    let sessions = MuxProbe.parseTmux(listed ?? "")
    check("tmux с чистым окружением отвечает и не портит русские имена",
          sessions.count == 1 && sessions[0].name == "работа-стенд" && sessions[0].windows == 1, listed ?? "nil")
    _ = Tool.run(tmux, ["-S", sock, "kill-server"], timeout: 5, environment: [])
    check("tmux без сервера: пусто", Tool.run(tmux, MuxProbe.tmuxArguments(socket: "нет.sock"), timeout: 3, environment: []) == "")
}

exit(failed ? 1 : 0)
