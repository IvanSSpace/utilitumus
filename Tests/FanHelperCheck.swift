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
    check(FanLink.helperVersion == "6", "версия помощника")
    check(FanLink.holdTimeout == 15, "служба терпит без удержания 15 с")
    check(FanGate.holdRefresh * 2 < FanLink.holdTimeout, "клиент повторяет удержание минимум дважды за срок службы")
    check(FanLink.connectionOptions == .privileged, "клиент ищет службу в системном домене")
    check(FanHelperClient.timeout == 3, "срок клиента 3 с")

    let marker = "info[\"UtilitumusSecurityEpoch\"] = \"1\""
    let listener = "(identifier \"local.utilitumus\" and certificate leaf = H\"\(leaf)\" and \(marker)) or (identifier \"local.utilitumus.app.fans\" and certificate leaf = H\"\(leaf)\" and \(marker))"
    check(FanLink.listenerRequirement == listener, "требование слушателя дословно")
    check(FanLink.serviceRequirement == "identifier \"local.utilitumus.fan\" and certificate leaf = H\"\(leaf)\"", "требование к службе дословно")
    for text in [FanLink.listenerRequirement, FanLink.serviceRequirement] {
        var requirement: SecRequirement?
        check(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, "требование разбирается Security")
    }

    check(FanHelperClient.quitBudget == 1.5, "выход ждёт не больше 1,5 с")
    check(KitLink.requirement(identifier: "x", hashes: ["aa"]) == "(identifier \"x\" and certificate leaf = H\"aa\" and \(marker))", "KitLink: то же требование с меткой")
    thermalChecks()
    epochChecks()
    legacyChecks()
    statusChecks()
    refreshChecks()
    plistChecks()
    scriptChecks()
}

/// Перегрев в службе: чистая логика. Пороги те же, что у клиента (проверка текста в скрипте запуска).
func thermalChecks() {
    check(FanLink.thermalTrip == 95 && FanLink.thermalRelease == 85, "пороги перегрева 95/85")
    var guardState = ThermalGuard()
    check(!guardState.update(hottest: nil), "датчики не читаются: не перегрев")
    check(!guardState.update(hottest: 94.9), "94,9 °C: ещё не перегрев")
    check(guardState.update(hottest: 95), "95 °C: перегрев")
    check(guardState.update(hottest: 90), "90 °C после перегрева: держится (гистерезис)")
    check(guardState.update(hottest: 85), "85 °C: держится, возврат ниже 85")
    check(!guardState.update(hottest: 84.9), "84,9 °C: перегрев снят")
    check(!guardState.update(hottest: 90), "90 °C после остывания: не перегрев, порог 95")
    check(guardState.update(hottest: 120), "120 °C: перегрев")
    check(!guardState.update(hottest: nil), "датчики пропали при перегреве: не считаем горячим, не блокируем")
    check(ThermalGuard.hottest([60, 96, nil]) == 96, "самый горячий из датчиков")
    check(ThermalGuard.hottest([nil, nil]) == nil, "нет показаний — нет температуры")
    check(ThermalGuard.hottest([0, -5, 200, .nan, .infinity]) == nil, "неправдоподобные показания отброшены")
    check(ThermalGuard.hottest([0, 70, 200]) == 70, "неправдоподобное не мешает правдоподобному")
}

/// Метка стоит в Info.plist центра и каждой утилиты, значение одно на всех: новую утилиту без неё не собрать незаметно.
func epochChecks() {
    let apps = (try? FileManager.default.contentsOfDirectory(atPath: "Sources/Apps")) ?? []
    check(!apps.isEmpty, "утилиты найдены")
    for path in ["Info.plist", "Tests/EmbeddedInfo.plist"] + apps.map({ "Sources/Apps/\($0)/Info.plist" }) {
        let data = FileManager.default.contents(atPath: path) ?? Data()
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        check(plist?[KitSigning.securityEpochKey] as? String == KitSigning.securityEpoch, "метка в \(path)")
    }
    // Требование без метки на месте: Updater сверяет им и старые сборки, и бинарник помощника.
    check(!KitSigning.requirement(identifier: "x", leafHash: "aa").contains("info["), "проверка файлов подписи без метки")
    check(!FanLink.serviceRequirement.contains("info["), "у службы без бандла требование без метки")
}

func legacyChecks() {
    typealias L = LegacyFanHelper
    check(L.isSetuidRoot((0, 0o4750)) && L.isSetuidRoot((0, 0o4755)), "прежний помощник: root и setuid")
    check(!L.isSetuidRoot((0, 0o755)), "без setuid — не прежний")
    check(!L.isSetuidRoot((501, 0o4755)), "setuid не от root — не запускаем")
    check(!L.isSetuidRoot(nil), "файла нет — не запускаем")

    typealias I = FanHelperInstaller
    let plain = I.outdatedDetail(fanStuckManual: false), stuck = I.outdatedDetail(fanStuckManual: true)
    check(!plain.contains("ручном"), "плашка без застрявшего вентилятора о нём молчит")
    check(stuck.contains("ручном режиме") && stuck.hasPrefix(plain), "плашка говорит о ручном режиме, только когда так и есть")

    func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    let controller = source("Sources/Modules/Fans/FanController.swift")
    let view = source("Sources/Modules/Fans/FansView.swift")
    let installer = source("Sources/Modules/Fans/FanHelperInstaller.swift")
    let restore = controller.components(separatedBy: "func restoreAutoBlocking()").last?.components(separatedBy: "func stop()").first ?? ""
    check(restore.contains("status != .notInstalled"), "выход отдаёт вентиляторы и при устаревшем помощнике")
    // Экран вызывает модель, а возврат «Авто» перед удалением доступа делает встроенная модель (и разбор действия со связи).
    let model = source("Sources/Modules/Fans/FansModel.swift").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let wire = source("Sources/Modules/Fans/FansWire.swift").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    check(view.contains("model.uninstallHelper()") && model.contains("controller.restoreAutoBlocking() installer.uninstall()"), "«Забрать доступ» сперва отдаёт вентиляторы")
    check(wire.contains("restoreAutoBlocking() installer.uninstall()"), "«Забрать доступ» со связи сперва отдаёт вентиляторы")
    let wake = controller.components(separatedBy: "didWakeNotification").last?.components(separatedBy: "screensDidSleepNotification").first ?? ""
    check(wake.contains("FanHelperInstaller.shared.refresh()"), "после сна статус спрашивается заново")

    let runAdmin = installer.components(separatedBy: "func run(admin").last ?? ""
    for name in ["SHELLOPTS", "BASHOPTS", "PS4", "ENV", "BASH_ENV", "IFS"] {
        check(installer.contains("\"\(name)\""), "окружение: убирается \(name)")
    }
    if let unset = runAdmin.range(of: "scrubRootShellEnvironment()"), let script = runAdmin.range(of: "NSAppleScript(source") {
        check(unset.lowerBound < script.lowerBound, "окружение чистится до вызова оболочки root")
    } else {
        check(false, "окружение чистится до вызова оболочки root")
    }
    check(runAdmin.contains("appleScriptQuote(Self.adminCommand(shell))"), "оболочка root получает команду с пустым окружением")

    check(restore.contains("hasLegacySetuid") && restore.contains("LegacyFanHelper.restoreAutoWithin"), "выход при setuid идёт через прежний помощник")
    let updater = source("Sources/App/Updater.swift")
    // Сам порядок и удержание проверяет поведением Tests/run-update-order-check.sh; здесь — что Updater подключён именно к ним.
    check(updater.contains("beforeReplace: { if !ModuleManager.shared.isExternal(.fans) { FanController.shared.holdForUpdate() } }"), "обновление отдаёт вентиляторы, но не поднимает модуль, который ведёт утилита")
    check(updater.contains("replaceFailed: { if !ModuleManager.shared.isExternal(.fans) { FanController.shared.resumeAfterFailedUpdate() } }"), "неудачное обновление возвращает управление")
    check(updater.contains("try await UpdateBundle.install(") && !updater.contains("UpdateBundle.commit"), "обновление идёт через install с шагами вокруг подмены")
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

/// Даёт доехать задачам на главном акторе.
func spin(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Когда статус спрашивает службу. Счётчик стоит на месте вызова XPC, настоящий launchd — в `refreshOffRole`.
func refreshChecks() {
    let good = (binary: (owner: 0, mode: 0o755) as FanHelperInstaller.FileInfo?, plist: (owner: 0, mode: 0o644) as FanHelperInstaller.FileInfo?)
    MainActor.assumeIsolated {
        let probes = Counter()
        @MainActor func installer(version: String? = FanLink.helperVersion) -> FanHelperInstaller {
            FanHelperInstaller(files: { good }, probeVersion: { probes.bump(); return version })
        }

        let off = installer()
        off.refresh()
        spin()
        check(probes.count == 0, "модуль выключен, экран закрыт: XPC нет")
        check(off.status == .installed, "модуль выключен: статус только по файлам")

        off.moduleRunning = true
        off.refresh()
        spin()
        check(probes.count == 1, "модуль включён: одна проверка XPC")
        check(off.status == .ready, "модуль включён, версия совпала: ready")

        off.moduleRunning = false
        off.refresh()
        spin()
        check(probes.count == 1, "модуль снова выключен: XPC нет")
        check(off.status == .installed, "модуль снова выключен: прежний ready не держится")

        off.screenOpen = true
        off.refresh()
        spin()
        check(probes.count == 2, "экран открыт: проверка XPC")
        check(off.status == .ready, "экран открыт, версия совпала: ready")
        off.screenOpen = false

        off.refresh(afterInstall: true)
        spin()
        check(probes.count == 3, "сразу после установки: проверка XPC")
        check(off.status == .ready, "после установки при выключенном модуле: ready")

        let other = installer(version: "3")
        other.moduleRunning = true
        other.refresh()
        spin()
        check(other.status == .outdated, "служба старше клиента: outdated")

        check(other.serviceAnswered, "служба старше клиента: жива, ей можно отдать «Авто»")

        // Один сбой — ещё не устаревший помощник: повторы через паузу.
        let silentProbes = Counter()
        let silent = FanHelperInstaller(files: { good }, probeVersion: { silentProbes.bump(); return nil }, retryDelay: 0.05)
        silent.moduleRunning = true
        silent.refresh()
        spin(0.02)
        check(silent.status == .installed, "первый сбой: плашки ещё нет")
        spin(0.4)
        check(silentProbes.count == 3, "два повтора после сбоя: \(silentProbes.count)")
        check(silent.status == .outdated && !silent.serviceAnswered, "служба так и не ответила: outdated, живой не считается")

        let flakyProbes = Counter()
        let flaky = FanHelperInstaller(files: { good }, probeVersion: {
            flakyProbes.bump()
            return flakyProbes.count == 1 ? nil : FanLink.helperVersion
        }, retryDelay: 0.05)
        flaky.moduleRunning = true
        flaky.refresh()
        spin(0.4)
        check(flaky.status == .ready && flakyProbes.count == 2, "сбой один раз, потом ответ: ready без плашки")

        let readyProbes = Counter()
        let wasReady = FanHelperInstaller(files: { good }, probeVersion: {
            readyProbes.bump()
            return readyProbes.count == 2 ? nil : FanLink.helperVersion
        }, retryDelay: 0.3)
        wasReady.moduleRunning = true
        wasReady.refresh()
        spin()
        wasReady.refresh()
        spin(0.1)
        check(wasReady.status == .ready, "сбой при ready: статус держится, пока идут повторы")
        spin(0.5)
        check(wasReady.status == .ready && readyProbes.count == 3, "повтор подтвердил ready")

        // Модуль выключили, пока ждём повтора: службу больше не поднимаем.
        let offProbes = Counter()
        let turnedOff = FanHelperInstaller(files: { good }, probeVersion: { offProbes.bump(); return nil }, retryDelay: 0.1)
        turnedOff.moduleRunning = true
        turnedOff.refresh()
        spin(0.03)
        turnedOff.moduleRunning = false
        spin(0.4)
        check(offProbes.count == 1, "модуль выключен во время паузы: повтора нет: \(offProbes.count)")

        let before = probes.count
        let setuid = FanHelperInstaller(files: { ((0, 0o4750), nil) }, probeVersion: { probes.bump(); return nil })
        setuid.moduleRunning = true
        setuid.refresh()
        spin()
        check(setuid.status == .outdated && probes.count == before, "старый setuid: outdated без XPC, даже с модулем")

        // Ответ пришёл после удаления: файлов уже нет, старый ответ не должен оживить статус.
        let box = FilesBox(good)
        let late = FanHelperInstaller(files: { box.value }, probeVersion: { usleep(100_000); return FanLink.helperVersion })
        late.moduleRunning = true
        late.refresh()
        box.value = (nil, nil)
        late.refresh()
        spin(0.4)
        check(late.status == .notInstalled, "запоздавший ответ не отменяет новый статус")
    }

    let source = (try? String(contentsOfFile: "Sources/Modules/Fans/FanHelperInstaller.swift", encoding: .utf8)) ?? ""
    let install = source.components(separatedBy: "func install()").last?.components(separatedBy: "func uninstall()").first ?? ""
    check(install.contains("refresh(afterInstall: true)"), "install() проверяет службу сразу после установки")
}

final class FilesBox {
    var value: (binary: FanHelperInstaller.FileInfo?, plist: FanHelperInstaller.FileInfo?)
    init(_ value: (binary: FanHelperInstaller.FileInfo?, plist: FanHelperInstaller.FileInfo?)) { self.value = value }
}

func plistChecks() {
    let data = Data(FanHelperInstaller.plistXML.utf8)
    let parsed = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    check(parsed != nil, "плист разбирается")
    check(Set(parsed?.keys.map { $0 } ?? []) == ["Label", "ProgramArguments", "MachServices", "KeepAlive"], "в плисте только нужные ключи")
    check(parsed?["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false], "KeepAlive только на сбой: чистый выход по простою службу не поднимает")
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
    let steps = ["/usr/bin/mktemp -d", "/bin/cp -X ", "/usr/sbin/chown root:wheel", "/bin/chmod 0755",
                 "/usr/bin/codesign --verify", "\"$T\" version", "/bin/chmod 0755 '/Library/PrivilegedHelperTools/local.utilitumus.fan' 2>/dev/null || /usr/bin/true",
                 "/bin/mv -f", "/bin/chmod 0644", "/bin/launchctl bootout",
                 "/bin/launchctl bootstrap system"]
    for (a, b) in zip(steps, steps.dropFirst()) {
        check(before(a, b, in: install), "установка: «\(a)» раньше «\(b)»")
    }
    check(install.contains("/Library/PrivilegedHelperTools/.install."), "копия в каталоге root, тот же том")
    check(install.contains("bootout system/local.utilitumus.fan"), "снимает службу по метке")
    check(install.contains("bootstrap system '/Library/LaunchDaemons/local.utilitumus.fan.plist'"), "ставит службу по плисту")

    // Только значение строки, без `do shell script`: кавычки и кириллица доходят до sh без потерь.
    var error: NSDictionary?
    let command = FanHelperInstaller.adminCommand(install)
    let quoted = NSAppleScript(source: "return " + FanHelperInstaller.appleScriptQuote(command))?.executeAndReturnError(&error)
    check(quoted?.stringValue == command, "команда переживает кавычки AppleScript: \(error ?? [:])")
    check(command.hasPrefix("/usr/bin/env -i /bin/sh -c '"), "скрипт идёт в оболочку с пустым окружением")
    check(FanHelperInstaller.adminCommand("a'b") == #"/usr/bin/env -i /bin/sh -c 'a'\''b'"#, "кавычки внутри скрипта экранируются")

    let remove = FanHelperInstaller.uninstallScript
    check(remove.contains("/bin/launchctl bootout system/local.utilitumus.fan"), "удаление снимает службу")
    check(remove.contains("/bin/rm -f '/Library/LaunchDaemons/local.utilitumus.fan.plist'"), "удаление убирает плист")
    check(remove.contains("/bin/rm -f '/Library/PrivilegedHelperTools/local.utilitumus.fan'"), "удаление убирает бинарник")
    check(before("bootout", "/bin/rm", in: remove), "удаление: сначала снять службу")
    check(before("/bin/chmod 0755 '/Library/PrivilegedHelperTools/local.utilitumus.fan'", "/bin/rm -f '/Library/PrivilegedHelperTools/local.utilitumus.fan'", in: remove), "удаление: setuid снимается раньше rm")

    // Функция из окружения подменила бы `[`, `echo` или `true`. Пустое окружение её не пропустит, а скрипт ещё и не зовёт такие имена.
    for (name, script) in [("установка", install), ("удаление", remove)] {
        for (word, pattern) in [("[", #"(^|[;(&| ])\[ "#), ("echo", #"(^|[;{(&| ])echo "#), ("true", #"(^|[;{(&| ])true($|[; ])"#)] {
            check(script.range(of: pattern, options: .regularExpression) == nil, "\(name): нет встроенного «\(word)»")
        }
    }
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
    // Сторож службы не должен вмешаться в чужие проверки: вентилятор не оставляем в ручном режиме.
    check(FanHelperClient.send(.auto(0)) == nil, "вентилятор 0 возвращён в Авто")
}

/// Удержание вентилятора 0 при заданной температуре: принято (`ok`) или отклонено (`refused`).
func thermalSetRole(_ expected: String) {
    clearWrites()
    let error = FanHelperClient.send(.set(0, 2000))
    if expected == "ok" {
        check(error == nil, "удержание принято: \(error ?? "nil")")
        check(writes().contains("F0Md=1"), "вентилятор взят в ручной режим: \(writes())")
    } else {
        check(error != nil, "удержание отклонено")
        check(!writes().contains("F0Md=1"), "при перегреве в SMC ручной режим не писался: \(writes())")
    }
}

/// Берёт вентилятор 0 в ручной режим и держит соединение, пока скрипт не убьёт процесс (SIGKILL).
func holdManualRole(_ seconds: UInt32) {
    clearWrites()
    check(FanHelperClient.send(.set(0, 2000)) == nil, "set(0, 2000) успешно")
    check(writes() == ["F0Md=1", "F0Tg=2000.0"], "вентилятор взят в ручной режим: \(writes())")
    holdRole(seconds)
}

/// Повторяет удержание раз в секунду `count` раз: сторож службы (3 с) не должен отдавать вентилятор.
func keepaliveRole(_ count: Int) {
    clearWrites()
    for _ in 0..<count {
        check(FanHelperClient.send(.set(0, 2000)) == nil, "удержание принято")
        sleep(1)
    }
    check(!writes().contains("F0Md=0"), "пока удержание повторяют, вентилятор не отдан: \(writes())")
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
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed >= 1.9, "ожидание по секунде на команду: \(elapsed)")
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

/// Настоящий клиент и настоящий launchd: скрипт смотрит, запустилась ли служба.
func refreshRole(moduleRunning: Bool) {
    MainActor.assumeIsolated {
        let installer = FanHelperInstaller(files: { ((0, 0o755), (0, 0o644)) })
        installer.moduleRunning = moduleRunning
        installer.refresh()
        // Нечего возвращать в «Авто»: выход и сон не должны поднимать службу ради пустого списка.
        FanHelperClient.sendAll([], on: DispatchQueue(label: "test.helper")) { _, _ in }
        spin(1)
        check(installer.status == (moduleRunning ? .ready : .installed), "статус при модуле \(moduleRunning ? "вкл" : "выкл"): \(installer.status)")
    }
}

/// Общий срок на все вентиляторы, как при выходе из приложения.
func quitRole(_ scenario: String) {
    clearWrites()
    let queue = DispatchQueue(label: "test.helper")
    let results = NSLock()
    var replies: [String?] = []
    var queuedSet: String?? = nil
    if scenario == "busy" {
        queue.async { sleep(3) }
        queue.async {
            let error = FanHelperClient.send(.set(0, 2000), until: .now() + 3)
            results.lock(); queuedSet = .some(error); results.unlock()
        }
    }
    let started = Date()
    FanHelperClient.sendAll([.auto(0), .auto(1)], on: queue) { _, error in
        results.lock(); replies.append(error); results.unlock()
    }
    let elapsed = Date().timeIntervalSince(started)
    switch scenario {
    case "ok":
        check(elapsed < 1, "обычный выход не ждёт срока: \(elapsed)")
        check(writes() == ["F0Md=0", "F1Md=0"], "оба вентилятора в Авто: \(writes())")
    case "silent":
        check(elapsed > 1.3 && elapsed < 1.8, "молчащая служба: всего около 1,5 с, а не 3 с на вентилятор: \(elapsed)")
        check(writes().isEmpty, "без рукопожатия команд нет: \(writes())")
    case "stuck":
        check(elapsed > 1.3 && elapsed < 1.8, "оба вентилятора зависли: всего около 1,5 с: \(elapsed)")
        // Второй ждёт, пока служба отпустит первый: его запись проверяет скрипт, когда клиента уже нет.
        check(writes().first == "F0Md=0", "первый вентилятор получил команду: \(writes())")
    case "busy":
        check(elapsed > 0.6 && elapsed < 1.2, "очередь занята: через половину срока «Авто» уходит мимо неё: \(elapsed)")
        check(writes() == ["F0Md=0", "F1Md=0"], "оба вентилятора в Авто, очередь ещё занята: \(writes())")
        spin(3)
        check(writes() == ["F0Md=0", "F1Md=0"], "команда set из очереди не перебила «Авто»: \(writes())")
        results.lock()
        check(queuedSet == .some(FanHelperClient.Failure.cancelled.localizedDescription), "команда set отменена: \(String(describing: queuedSet))")
        check(replies.count == 2 && replies.allSatisfy { $0 == nil }, "ответы на «Авто»: \(replies)")
        results.unlock()
        var next: String?
        queue.sync { next = FanHelperClient.send(.set(0, 2000)) }
        check(next == nil && writes().last == "F0Tg=2000.0", "после этого новые set снова идут: \(writes())")
    default:
        fatalError("неизвестный сценарий")
    }
}

/// Набор из ревью: всё это оболочка исполнила бы при старте. Безвредно: только создаёт файлы в папке стенда.
func poison(_ dir: String) {
    setenv("BASH_FUNC_[%%", "() { /usr/bin/touch \(dir)/pwn-func; }", 1)
    setenv("BASH_FUNC_echo%%", "() { /usr/bin/touch \(dir)/pwn-func; }", 1)
    setenv("SHELLOPTS", "xtrace", 1)
    setenv("PS4", "$(/usr/bin/touch \(dir)/pwn-ps4)", 1)
    setenv("IFS", "e", 1)
    setenv("ENV", "\(dir)/poison.sh", 1)
    setenv("BASH_ENV", "\(dir)/poison.sh", 1)
}

/// `do shell script` без прав администратора: та же внешняя команда, что идёт root, со скриптом-пустышкой.
/// Пустышка сама зовёт `[` и `echo`: подмена сработала бы на них. Никакого пароля и никакого root.
func poisonRole(_ mode: String, _ dir: String) -> Never {
    poison(dir)
    let harmless = "[ 1 = 1 ]; echo x; /usr/bin/touch \(dir)/ran"
    var command = harmless
    switch mode {
    case "raw": break
    case "env-only": command = FanHelperInstaller.adminCommand(harmless)
    case "full":
        FanHelperInstaller.scrubRootShellEnvironment()
        command = FanHelperInstaller.adminCommand(harmless)
    default: fatalError("неизвестный режим")
    }
    var error: NSDictionary?
    NSAppleScript(source: "do shell script " + FanHelperInstaller.appleScriptQuote(command))?.executeAndReturnError(&error)
    if let error { print("do shell script: \(error)") }
    exit(0)
}

/// `set` уже прошёл рукопожатие, пока выход отменял такие команды: уйти он не должен.
func cancelAfterHandshakeRole() {
    clearWrites()
    let queue = DispatchQueue(label: "test.helper")
    let lock = NSLock()
    var queued: String?
    queue.async {
        let error = FanHelperClient.send(.set(0, 2000), until: .now() + 3)
        lock.lock(); queued = error; lock.unlock()
    }
    usleep(100_000)
    FanHelperClient.sendAll([.auto(0)], on: queue, within: 1) { _, _ in }
    spin(2)
    lock.lock()
    check(queued == FanHelperClient.Failure.cancelled.localizedDescription, "set после рукопожатия отменён: \(queued ?? "nil")")
    lock.unlock()
    check(!writes().contains("F0Md=1"), "set не дошёл до SMC: \(writes())")
}

/// Прежний помощник при выходе: не дольше срока, а запущенный доделает и без нас.
func legacyBoundedRole(_ path: String) {
    let started = Date()
    LegacyFanHelper.restoreAutoWithin(fans: [0, 1], path: path, on: DispatchQueue(label: "test.helper")) { _ in }
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 1.8, "прежний помощник: ожидание в пределах срока: \(elapsed)")
    print("ждали \(elapsed)")
}

// MARK: - Вход

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil: pureChecks()
case "print-install": print(FanHelperInstaller.adminCommand(FanHelperInstaller.installScript(source: args[1]))); exit(0)
case "print-uninstall": print(FanHelperInstaller.adminCommand(FanHelperInstaller.uninstallScript)); exit(0)
case "poison": poisonRole(args[1], args[2])
case "cancel-after-handshake": cancelAfterHandshakeRole()
case "legacy-bounded": legacyBoundedRole(args[1])
case "legacy":
    if let error = LegacyFanHelper.restoreAuto(fans: args[2...].compactMap { Int($0) }, path: args[1]) { print(error); exit(1) }
    exit(0)
case "hub": hubRole()
case "rogue": rogueRole()
case "spoofed": spoofedRole()
case "silent": silentRole()
case "stuck": stuckRole()
case "hold": holdRole(UInt32(args[1]) ?? 1)
case "hold-manual": holdManualRole(UInt32(args[1]) ?? 1)
case "thermal-set": thermalSetRole(args[1])
case "keepalive": keepaliveRole(Int(args[1]) ?? 1)
case "refresh-off": refreshRole(moduleRunning: false)
case "refresh-on": refreshRole(moduleRunning: true)
case "quit": quitRole(args[1])
default: fatalError("неизвестная роль")
}
finish()
