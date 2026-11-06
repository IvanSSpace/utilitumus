import Foundation
import AppKit

/// Установка/удаление root-службы `utilitumus-fan` (launchd, XPC; setuid больше нет). Права
/// спрашивает сама macOS — стандартное окно «Utilitumus хочет внести изменения» (пароль или
/// Touch ID) через `do shell script … with administrator privileges`.
@MainActor
final class FanHelperInstaller: ObservableObject {
    static let shared = FanHelperInstaller()

    enum Status: Equatable {
        case notInstalled
        /// Файлы в порядке, служба не спрошена: она сейчас никому не нужна или ответ ещё не пришёл.
        /// Ни плашки, ни команд.
        case installed
        /// Прежний setuid-помощник, неполная установка или служба старше клиента либо без ответа после
        /// повторов. Управления нет, только возврат вентиляторов в «Авто». Плашка «Обновить доступ».
        case outdated
        case ready
    }

    nonisolated static let installedPath = "/Library/PrivilegedHelperTools/local.utilitumus.fan"
    nonisolated static let plistPath = "/Library/LaunchDaemons/local.utilitumus.fan.plist"
    private nonisolated static var bundledPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/utilitumus-fan").path
    }

    @Published private(set) var status: Status = .notInstalled
    @Published private(set) var lastError: String?

    /// Модуль запущен: службу спрашиваем. Выставляет `FanController`.
    var moduleRunning = false
    /// Экран модуля открыт: службу спрашиваем ради плашки. Выставляет `FansView`.
    var screenOpen = false
    /// Служба ответила хоть какой-то версией при последней проверке: ей можно отдать «Авто», даже если устарела.
    private(set) var serviceAnswered = false
    /// Окно пароля сейчас открыто.
    private var adminRunning = false

    typealias FileInfo = (owner: Int, mode: Int)
    private let files: () -> (binary: FileInfo?, plist: FileInfo?)
    private let probeVersion: @Sendable () -> String?
    private let clientVersion: String
    /// Номер последнего `refresh`: ответ службы на более ранний уже не считается.
    private var refreshID = 0
    private let retryDelay: TimeInterval
    /// Сколько раз ещё спросить службу после сбоя: один сбой — не повод просить пароль.
    private var retriesLeft = 0
    private static let probeRetries = 2

    init(
        files: @escaping () -> (binary: FileInfo?, plist: FileInfo?) = {
            #if KIT_TEST_DEFAULTS
            // Стенд не смотрит в настоящие файлы службы: на этом Mac может стоять прежний помощник, и тогда стенд
            // получил бы «Доступ нужно обновить», окно пароля на удаление и запись в настоящий SMC через прежний помощник.
            return (nil, nil)
            #else
            return (FanHelperInstaller.fileInfo(FanHelperInstaller.installedPath), FanHelperInstaller.fileInfo(FanHelperInstaller.plistPath))
            #endif
        },
        probeVersion: @escaping @Sendable () -> String? = { FanHelperClient.version() },
        clientVersion: String = FanLink.helperVersion,
        retryDelay: TimeInterval = 3
    ) {
        self.files = files
        self.probeVersion = probeVersion
        self.clientVersion = clientVersion
        self.retryDelay = retryDelay
        refresh()
    }

    /// Подключение запускает root-службу, поэтому XPC только когда она нужна: модуль запущен, экран
    /// открыт или установка только что прошла. Иначе статус по одним файлам.
    func refresh(afterInstall: Bool = false) {
        retriesLeft = Self.probeRetries
        check(afterInstall: afterInstall)
    }

    private func check(afterInstall: Bool) {
        refreshID += 1
        let found = files()
        if let settled = Self.statusFromFiles(binary: found.binary, plist: found.plist) {
            serviceAnswered = false
            status = settled
            return
        }
        guard afterInstall || moduleRunning || screenOpen else {
            serviceAnswered = false
            status = .installed
            return
        }
        // По номеру версии, а не побайтово: байты меняются при каждой сборке
        // (и всегда отличаются у сборки с GitHub), а просить пароль надо, только
        // когда помощник действительно изменился.
        //
        // В фоне, не на главном потоке: пока shared ещё создаётся, SwiftUI успевал
        // отрисовать FansView, тот лез в недосозданный shared — падение
        // «dispatch_once: lock recursively». До ответа плашки нет, но и команд нет.
        if status == .notInstalled { status = .installed }
        let id = refreshID, probe = probeVersion, client = clientVersion
        Task { [weak self] in
            let version = await Task.detached { probe() }.value
            guard let self, self.refreshID == id else { return }
            self.serviceAnswered = version != nil
            if let version {
                self.status = Self.status(service: version, client: client)
            } else if self.retriesLeft > 0 {
                self.retriesLeft -= 1
                try? await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
                guard self.refreshID == id else { return }
                self.check(afterInstall: afterInstall)
            } else {
                self.status = .outdated
            }
        }
    }

    /// Служба новее клиента — обычное дело: центр и утилита обновляются порознь, а старые команды служба обязана
    /// принимать (см. `FanHelperXPC`). Считай клиент такую службу устаревшей, он просил бы пароль, чтобы поставить
    /// старую, а второй клиент потом просил бы его снова. Непонятный ответ — не новее.
    nonisolated static func status(service: String, client: String) -> Status {
        guard let found = Int(service), let own = Int(client), found >= own else { return .outdated }
        return .ready
    }

    /// Текст плашки. О ручном режиме только когда так и есть: иначе это лишняя тревога.
    nonisolated static func outdatedDetail(fanStuckManual: Bool) -> String {
        let base = "Помощник устарел. macOS один раз спросит пароль администратора."
        return fanStuckManual ? base + " Вентилятор может оставаться в ручном режиме, пока доступ не обновлён." : base
    }

    /// Прежний setuid-файл ещё на месте. Убрать вместе с поддержкой setuid.
    var hasLegacySetuid: Bool { LegacyFanHelper.isSetuidRoot(files().binary) }

    /// Что видно по файлам; nil — файлы в порядке, решает версия службы по XPC.
    /// Прежний setuid-помощник сюда попадает как `outdated`: запускать его незачем.
    nonisolated static func statusFromFiles(binary: FileInfo?, plist: FileInfo?) -> Status? {
        guard binary != nil || plist != nil else { return .notInstalled }
        if let binary, binary.owner != 0 { return .notInstalled }
        // Ни setuid/setgid, ни записи для группы и остальных.
        guard let binary, binary.mode & 0o6022 == 0,
              let plist, plist.owner == 0, plist.mode & 0o022 == 0 else { return .outdated }
        return nil
    }

    nonisolated static func fileInfo(_ path: String) -> FileInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue,
              let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue else { return nil }
        return (owner, mode)
    }

    func install() {
        run(admin: Self.installScript(source: Self.bundledPath)) { $0.refresh(afterInstall: true) }
    }

    func uninstall() {
        run(admin: Self.uninstallScript) { $0.refresh() }
    }

    /// В одну строку: идёт внутрь строки AppleScript. Без `RunAtLoad`: launchd поднимает службу по подключению.
    /// `KeepAlive` только на сбой: после падения или выхода с кодом не 0 launchd запускает службу снова, и при запуске она
    /// возвращает вентиляторы в «Авто». Выход по простою с кодом 0 её не поднимает. Менять плист — значит поднимать `FanLink.helperVersion`.
    nonisolated static var plistXML: String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
            + "<key>Label</key><string>\(FanLink.label)</string>"
            + "<key>ProgramArguments</key><array><string>\(installedPath)</string></array>"
            + "<key>MachServices</key><dict><key>\(FanLink.service)</key><true/></dict>"
            + "<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>"
            + "</dict></plist>"
    }

    /// Проверка подписи — ВНУТРИ root-скрипта и на копии, которую пользователь уже
    /// не может подменить: иначе между проверкой и установкой (TOCTOU) обычный
    /// процесс успел бы подсунуть другой бинарь, и launchd запустил бы его от root.
    /// Временный каталог создаётся в /Library/PrivilegedHelperTools (пишет только root,
    /// тот же том — mv атомарный) с правами 0700. Плист пишется туда же, из текста скрипта, а не из файла.
    /// `mv` поверх прежнего пути заодно убирает старый setuid-помощник.
    /// Понижения нет: стоит служба новее — отказ, файлы не тронуты. Та же версия ставится: так чинятся права файлов.
    nonisolated static func installScript(source: String, helperVersion: String = FanLink.helperVersion) -> String {
        let dir = "/Library/PrivilegedHelperTools"
        func verify(_ path: String) -> String {
            KitSigning.trustedLeafHashes.map {
                "/usr/bin/codesign --verify " + shQuote("-R=" + KitSigning.requirement(identifier: "local.utilitumus.fan", leafHash: $0)) + " \"\(path)\""
            }.joined(separator: " || ")
        }
        return [
            "set -e",
            "/bin/mkdir -p \(shQuote(dir))",
            "D=$(/usr/bin/mktemp -d \(shQuote(dir + "/.install.XXXXXX")))",
            "trap '/bin/rm -rf \"$D\"' EXIT",
            "T=\"$D/helper\"",
            // -X: чужие расширенные атрибуты до файла root не доходят.
            "/bin/cp -X \(shQuote(source)) \"$T\"",
            "/usr/sbin/chown root:wheel \"$T\"",
            "/bin/chmod 0755 \"$T\"",
            "(\(verify("$T"))) || { /bin/echo 'Подпись помощника не совпала с подписью автора' >&2; exit 1; }",
            // Запускать можно только после проверки подписи. Подменённая более старая сборка с нашей подписью не пройдёт.
            "case \"$(\"$T\" version)\" in \(shQuote(helperVersion))) ;; *) /bin/echo 'Версия помощника не совпала с приложением' >&2; exit 1 ;; esac",
            // Установленный файл root запускает тоже только как копию из своего каталога и после проверки подписи.
            "O=\"$D/installed\"",
            "if /bin/cp -X \(shQuote(installedPath)) \"$O\" 2>/dev/null; then"
                + " /usr/sbin/chown root:wheel \"$O\"; /bin/chmod 0755 \"$O\";"
                + " if (\(verify("$O"))) 2>/dev/null; then"
                + " V=$(\"$O\" version 2>/dev/null) || V='';"
                + " case \"$V\" in ''|*[!0-9]*) ;; *) if /bin/test \"$V\" -gt \(shQuote(helperVersion)); then"
                + " /bin/echo 'Уже стоит более новая версия помощника: обнови приложение' >&2; exit 1; fi ;; esac;"
                + " fi; fi",
            // Жёсткая ссылка на старый файл сохранила бы его inode с setuid и после mv.
            "/bin/chmod 0755 \(shQuote(installedPath)) 2>/dev/null || /usr/bin/true",
            "/bin/mv -f \"$T\" \(shQuote(installedPath))",
            "P=\"$D/plist\"",
            "/usr/bin/printf '%s' \(shQuote(plistXML)) > \"$P\"",
            "/usr/sbin/chown root:wheel \"$P\"",
            "/bin/chmod 0644 \"$P\"",
            "/bin/mv -f \"$P\" \(shQuote(plistPath))",
            "/bin/launchctl bootout \(serviceTarget) 2>/dev/null || /usr/bin/true",
            // launchd отпускает метку не сразу после bootout.
            "for i in 1 2 3 4 5 6 7 8 9 10; do /bin/launchctl bootstrap system \(shQuote(plistPath)) && break; case \"$i\" in 10) exit 1 ;; esac; /bin/sleep 0.3; done",
        ].joined(separator: "; ")
    }

    nonisolated static var uninstallScript: String {
        [
            "/bin/launchctl bootout \(serviceTarget) 2>/dev/null || /usr/bin/true",
            "/bin/rm -f \(shQuote(plistPath))",
            // Жёсткая ссылка на старый файл сохранила бы его inode с setuid и после rm.
            "/bin/chmod 0755 \(shQuote(installedPath)) 2>/dev/null || /usr/bin/true",
            "/bin/rm -f \(shQuote(installedPath))",
        ].joined(separator: "; ")
    }

    private nonisolated static var serviceTarget: String { "system/\(FanLink.label)" }

    /// Окружение приложения доходит до внешней оболочки `do shell script`, а `/bin/sh` — это bash 3.2: он исполняет
    /// `PS4` при `SHELLOPTS=xtrace` и берёт функции из `BASH_FUNC_<имя>%%`, в том числе `[` и `echo`. Эта оболочка
    /// читает окружение раньше, чем сработает `env -i`, поэтому чистить надо и в самом процессе.
    nonisolated static func scrubRootShellEnvironment() {
        let functions = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("BASH_FUNC_") }
        for name in ["SHELLOPTS", "BASHOPTS", "PS4", "ENV", "BASH_ENV", "IFS"] + functions { unsetenv(name) }
    }

    /// Скрипт идёт в оболочку с пустым окружением. Внутри только абсолютные пути и ключевые слова: `PATH` там нет.
    nonisolated static func adminCommand(_ script: String) -> String {
        "/usr/bin/env -i /bin/sh -c " + shQuote(script)
    }

    /// Строка в одинарных кавычках для sh: внутренняя `'` → `'\''`.
    private nonisolated static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Строка для AppleScript в двойных кавычках: экранируем `\` и `"`.
    nonisolated static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Окно пароля ждёт человека сколько угодно, поэтому идёт не на главном потоке: утилита, зависшая на главном,
    /// для центра не отвечает. Пока окно открыто, второе не поднимается. Один поток на все вызовы: AppleScript держим на нём.
    private func run(admin shell: String, then finish: @escaping @MainActor (FanHelperInstaller) -> Void) {
        guard !adminRunning else { return }
        adminRunning = true
        lastError = nil
        Self.scrubRootShellEnvironment()
        let source = "do shell script \(Self.appleScriptQuote(Self.adminCommand(shell))) with administrator privileges"
        Self.adminQueue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            // -128 — пользователь нажал «Отменить», это не ошибка.
            let message = error.flatMap { dict -> String? in
                (dict[NSAppleScript.errorNumber] as? Int) == -128 ? nil : (dict[NSAppleScript.errorMessage] as? String ?? "Не удалось")
            }
            Task { @MainActor [self] in
                self.adminRunning = false
                if let message { self.lastError = message }
                finish(self)
            }
        }
    }

    private nonisolated static let adminQueue = DispatchQueue(label: "utilitumus.fans.admin")
}
