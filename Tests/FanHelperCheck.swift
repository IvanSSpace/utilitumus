import AppKit
import Security

// Проверка помощника вентиляторов. Запуск: Tests/run-fan-helper-check.sh
// Сборка без шва: production-значения, текст скриптов, плист, статус.
// Сборка со швом FAN_TEST_FAKE_SMC: роли клиента под launchd, подписи ставит скрипт.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func finish() -> Never {
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Без шва

let leaf = KitSigning.trustedLeafHashes[0]

func pureChecks() {
    check(FanLink.service == "local.utilitumus.fan.xpc", "имя службы")
    check(FanLink.label == "local.utilitumus.fan", "метка")
    check(FanLink.helperVersion == "4", "версия помощника")
    check(FanLink.connectionOptions == .privileged, "клиент ищет службу в системном домене")
    check(FanHelperClient.timeout == 3, "срок клиента 3 с")

    let listener = "(identifier \"local.utilitumus\" and certificate leaf = H\"\(leaf)\") or (identifier \"local.utilitumus.app.fans\" and certificate leaf = H\"\(leaf)\")"
    check(FanLink.listenerRequirement == listener, "требование слушателя дословно")
    check(FanLink.serviceRequirement == "identifier \"local.utilitumus.fan\" and certificate leaf = H\"\(leaf)\"", "требование к службе дословно")
    for text in [FanLink.listenerRequirement, FanLink.serviceRequirement] {
        var requirement: SecRequirement?
        check(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, "требование разбирается Security")
    }

    statusChecks()
    plistChecks()
    scriptChecks()
}

func statusChecks() {
    typealias I = FanHelperInstaller
    let binary = (owner: 0, mode: 0o755), plist = (owner: 0, mode: 0o644)
    check(I.statusFromFiles(binary: nil, plist: nil) == .notInstalled, "ничего нет — notInstalled")
    check(I.statusFromFiles(binary: binary, plist: plist) == nil, "файлы верны — решает версия по XPC")
    check(I.statusFromFiles(binary: (0, 0o4750), plist: nil) == .outdated, "старый setuid 4750 — outdated")
    check(I.statusFromFiles(binary: (0, 0o4755), plist: nil) == .outdated, "старый setuid 4755 — outdated")
    check(I.statusFromFiles(binary: (0, 0o4755), plist: plist) == .outdated, "setuid при плисте — outdated")
    check(I.statusFromFiles(binary: (0, 0o2755), plist: plist) == .outdated, "setgid — outdated")
    check(I.statusFromFiles(binary: binary, plist: nil) == .outdated, "без плиста — outdated")
    check(I.statusFromFiles(binary: nil, plist: plist) == .outdated, "без бинарника — outdated")
    check(I.statusFromFiles(binary: binary, plist: (501, 0o644)) == .outdated, "плист не root — outdated")
    check(I.statusFromFiles(binary: binary, plist: (0, 0o666)) == .outdated, "плист пишут все — outdated")
    check(I.statusFromFiles(binary: (0, 0o775), plist: plist) == .outdated, "бинарник пишет группа — outdated")
    check(I.statusFromFiles(binary: (501, 0o755), plist: plist) == .notInstalled, "бинарник не root — notInstalled")
    check(I.statusFromFiles(binary: (501, 0o4755), plist: nil) == .notInstalled, "setuid не от root — notInstalled")
}

func plistChecks() {
    let data = Data(FanHelperInstaller.plistXML.utf8)
    let parsed = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    check(parsed != nil, "плист разбирается")
    check(Set(parsed?.keys.map { $0 } ?? []) == ["Label", "ProgramArguments", "MachServices"], "в плисте только нужные ключи")
    check(parsed?["Label"] as? String == "local.utilitumus.fan", "Label")
    check(parsed?["ProgramArguments"] as? [String] == ["/Library/PrivilegedHelperTools/local.utilitumus.fan"], "ProgramArguments без аргументов")
    check(parsed?["MachServices"] as? [String: Bool] == ["local.utilitumus.fan.xpc": true], "MachServices")
    check(!FanHelperInstaller.plistXML.contains("\n"), "плист в одну строку: идёт внутрь AppleScript")
    check(FanHelperInstaller.plistPath == "/Library/LaunchDaemons/local.utilitumus.fan.plist", "путь плиста")
}

func scriptChecks() {
    let install = FanHelperInstaller.installScript(source: "/Applications/Utilitumus.app/Contents/MacOS/utilitumus-fan")
    for bad in ["4750", "4755", "u+s", "+s "] {
        check(!install.contains(bad), "в установке нет «\(bad)»")
    }
    func at(_ needle: String, in text: String) -> Int? {
        text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }
    func before(_ a: String, _ b: String, in text: String) -> Bool {
        guard let x = at(a, in: text), let y = at(b, in: text) else { return false }
        return x < y
    }
    let steps = ["/usr/bin/mktemp -d", "/bin/cp ", "/usr/sbin/chown root:wheel", "/bin/chmod 0755",
                 "/usr/bin/codesign --verify", "/bin/mv -f", "/bin/chmod 0644", "/bin/launchctl bootout",
                 "/bin/launchctl bootstrap system"]
    for (a, b) in zip(steps, steps.dropFirst()) {
        check(before(a, b, in: install), "установка: «\(a)» раньше «\(b)»")
    }
    check(install.contains("/Library/PrivilegedHelperTools/.install."), "копия в каталоге root, тот же том")
    check(install.contains("bootout system/local.utilitumus.fan"), "снимает службу по метке")
    check(install.contains("bootstrap system '/Library/LaunchDaemons/local.utilitumus.fan.plist'"), "ставит службу по плисту")

    // Только значение строки, без `do shell script`: кавычки и кириллица доходят до sh без потерь.
    var error: NSDictionary?
    let quoted = NSAppleScript(source: "return " + FanHelperInstaller.appleScriptQuote(install))?.executeAndReturnError(&error)
    check(quoted?.stringValue == install, "скрипт переживает кавычки AppleScript: \(error ?? [:])")

    let remove = FanHelperInstaller.uninstallScript
    check(remove.contains("/bin/launchctl bootout system/local.utilitumus.fan"), "удаление снимает службу")
    check(remove.contains("/bin/rm -f '/Library/LaunchDaemons/local.utilitumus.fan.plist'"), "удаление убирает плист")
    check(remove.contains("/bin/rm -f '/Library/PrivilegedHelperTools/local.utilitumus.fan'"), "удаление убирает бинарник")
    check(before("bootout", "/bin/rm", in: remove), "удаление: сначала снять службу")
}

// MARK: - Роли со швом

let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FAN_TEST_DIR"] ?? ".")
    .appendingPathComponent("smc-writes.log")
func writes() -> [String] {
    ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}
func clearWrites() { try? Data().write(to: logURL) }

func hubRole() {
    clearWrites()
    check(FanHelperClient.version() == FanLink.helperVersion, "клиент получил версию")
    check(writes().isEmpty, "версия не пишет в SMC")

    check(FanHelperClient.send(.auto(0)) == nil, "auto(0) успешно")
    check(writes() == ["F0Md=0"], "auto пишет только режим: \(writes())")

    clearWrites()
    check(FanHelperClient.send(.set(0, 2000)) == nil, "set(0, 2000) успешно")
    check(writes() == ["F0Md=1", "F0Tg=2000.0"], "set пишет режим и цель: \(writes())")

    let clamps: [(Int, Double, String)] = [
        (0, 99999, "F0Tg=6000.0"), (0, 1, "F0Tg=1200.0"),
        (1, 99999, "F1Tg=5500.0"), (1, 1, "F1Tg=1500.0"),
        (0, 1e308, "F0Tg=6000.0"), (0, -1e308, "F0Tg=1200.0"), (0, -5, "F0Tg=1200.0"),
    ]
    for (fan, rpm, expected) in clamps {
        clearWrites()
        check(FanHelperClient.send(.set(fan, rpm)) == nil, "set(\(fan), \(rpm)) успешно")
        check(writes().last == expected, "зажим \(rpm) у вентилятора \(fan): \(writes())")
    }

    clearWrites()
    let invalid: [(String, FanHelperClient.Command)] = [
        ("NaN", .set(0, .nan)), ("тихий NaN со знаком", .set(0, -Double.nan)),
        ("+бесконечность", .set(0, .infinity)), ("-бесконечность", .set(0, -.infinity)),
        ("номер -1", .set(-1, 2000)), ("номер = числу вентиляторов", .set(2, 2000)),
        ("Int.max", .set(.max, 2000)), ("Int.min", .set(.min, 2000)),
        ("auto -1", .auto(-1)), ("auto 2", .auto(2)), ("auto Int.max", .auto(.max)),
    ]
    for (name, command) in invalid {
        check(FanHelperClient.send(command) != nil, "\(name): ошибка")
        check(writes().isEmpty, "\(name): записи нет")
    }
}

/// Без требования к службе и без рукопожатия: сразу команда, как сделал бы чужой процесс.
func rogueRole() {
    clearWrites()
    let connection = NSXPCConnection(machServiceName: FanLink.service, options: FanLink.connectionOptions)
    connection.remoteObjectInterface = NSXPCInterface(with: FanHelperXPC.self)
    connection.resume()
    let lock = NSLock()
    var replies = 0, errors: [Int] = []
    func attempt(_ send: (FanHelperXPC, @escaping (String?) -> Void) -> Void) {
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            lock.lock(); errors.append((error as NSError).code); lock.unlock()
            done.signal()
        } as! FanHelperXPC
        send(proxy) { _ in
            lock.lock(); replies += 1; lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
    attempt { proxy, reply in proxy.setRPM(0, 2000, reply: reply) }
    attempt { proxy, reply in proxy.setAuto(0, reply: reply) }
    check(replies == 0, "чужой не получил ответа")
    check(errors.first == NSXPCConnectionInterrupted, "чужому отказал слушатель (4097): \(errors)")
    connection.invalidate()
    check(FanHelperClient.version() == nil, "чужой через штатный клиент: нет версии")
    check(FanHelperClient.send(.set(0, 2000)) != nil, "чужой через штатный клиент: ошибка")
    check(writes().isEmpty, "поддельный SMC не тронут: \(writes())")
}

func spoofedRole() {
    clearWrites()
    check(FanHelperClient.version() == nil, "подменённая служба: версия не принята")
    let error = FanHelperClient.send(.set(0, 2000))
    check(error == FanHelperClient.Failure.rejected.localizedDescription, "подменённая служба: отказ подписи: \(error ?? "nil")")
    check(writes().isEmpty, "команда подменённой службе не ушла: \(writes())")
}

func silentRole() {
    clearWrites()
    let started = Date()
    let error = FanHelperClient.send(.set(0, 2000))
    let elapsed = Date().timeIntervalSince(started)
    check(error == FanHelperClient.Failure.timeout.localizedDescription, "молчащая служба: срок вышел: \(error ?? "nil")")
    check(elapsed > 2.8 && elapsed < 3.6, "срок около 3 с: \(elapsed)")
    check(writes().isEmpty, "без рукопожатия команда не ушла: \(writes())")
}

/// Режим или цель не применились: ошибка, как в прежнем помощнике, примерно через секунду ожидания.
func stuckRole() {
    let started = Date()
    check(FanHelperClient.send(.set(0, 2000)) != nil, "цель не применилась: ошибка")
    check(FanHelperClient.send(.auto(0)) != nil, "режим не применился: ошибка")
    check(Date().timeIntervalSince(started) >= 1.9, "ожидание по секунде на команду")
}

/// Держит соединение открытым: служба не должна уйти, пока оно есть.
func holdRole(_ seconds: UInt32) {
    let connection = NSXPCConnection(machServiceName: FanLink.service, options: FanLink.connectionOptions)
    connection.remoteObjectInterface = NSXPCInterface(with: FanHelperXPC.self)
    connection.resume()
    let done = DispatchSemaphore(value: 0)
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! FanHelperXPC
    proxy.version { _ in done.signal() }
    _ = done.wait(timeout: .now() + 3)
    print("соединение открыто")
    fflush(stdout)
    sleep(seconds)
    connection.invalidate()
}

// MARK: - Вход

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil: pureChecks()
case "print-install": print(FanHelperInstaller.installScript(source: args[1])); exit(0)
case "print-uninstall": print(FanHelperInstaller.uninstallScript); exit(0)
case "hub": hubRole()
case "rogue": rogueRole()
case "spoofed": spoofedRole()
case "silent": silentRole()
case "stuck": stuckRole()
case "hold": holdRole(UInt32(args[1]) ?? 1)
default: fatalError("неизвестная роль")
}
finish()
