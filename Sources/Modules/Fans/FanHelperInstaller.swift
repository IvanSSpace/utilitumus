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
        /// Прежний setuid-помощник, неполная установка или служба с другой версией либо без ответа после
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

    typealias FileInfo = (owner: Int, mode: Int)
    private let files: () -> (binary: FileInfo?, plist: FileInfo?)
    private let probeVersion: @Sendable () -> String?
    /// Номер последнего `refresh`: ответ службы на более ранний уже не считается.
    private var refreshID = 0
    private let retryDelay: TimeInterval
    /// Сколько раз ещё спросить службу после сбоя: один сбой — не повод просить пароль.
    private var retriesLeft = 0
    private static let probeRetries = 2

    init(
        files: @escaping () -> (binary: FileInfo?, plist: FileInfo?) = {
            (FanHelperInstaller.fileInfo(FanHelperInstaller.installedPath), FanHelperInstaller.fileInfo(FanHelperInstaller.plistPath))
        },
        probeVersion: @escaping @Sendable () -> String? = { FanHelperClient.version() },
        retryDelay: TimeInterval = 3
    ) {
        self.files = files
        self.probeVersion = probeVersion
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
        let id = refreshID, probe = probeVersion
        Task { [weak self] in
            let version = await Task.detached { probe() }.value
            guard let self, self.refreshID == id else { return }
            self.serviceAnswered = version != nil
            if let version {
                self.status = version == FanLink.helperVersion ? .ready : .outdated
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
        run(admin: Self.installScript(source: Self.bundledPath))
        refresh(afterInstall: true)
    }

    func uninstall() {
        run(admin: Self.uninstallScript)
        refresh()
    }

    /// В одну строку: идёт внутрь строки AppleScript. Без `RunAtLoad` и `KeepAlive`: launchd поднимает службу по подключению.
    nonisolated static var plistXML: String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
            + "<key>Label</key><string>\(FanLink.label)</string>"
            + "<key>ProgramArguments</key><array><string>\(installedPath)</string></array>"
            + "<key>MachServices</key><dict><key>\(FanLink.service)</key><true/></dict>"
            + "</dict></plist>"
    }

    /// Проверка подписи — ВНУТРИ root-скрипта и на копии, которую пользователь уже
    /// не может подменить: иначе между проверкой и установкой (TOCTOU) обычный
    /// процесс успел бы подсунуть другой бинарь, и launchd запустил бы его от root.
    /// Временный каталог создаётся в /Library/PrivilegedHelperTools (пишет только root,
    /// тот же том — mv атомарный) с правами 0700. Плист пишется туда же, из текста скрипта, а не из файла.
    /// `mv` поверх прежнего пути заодно убирает старый setuid-помощник.
    nonisolated static func installScript(source: String) -> String {
        let dir = "/Library/PrivilegedHelperTools"
        let verify = KitSigning.trustedLeafHashes.map {
            "/usr/bin/codesign --verify " + shQuote("-R=" + KitSigning.requirement(identifier: "local.utilitumus.fan", leafHash: $0)) + " \"$T\""
        }.joined(separator: " || ")
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
            "(\(verify)) || { echo 'Подпись помощника не совпала с подписью автора' >&2; exit 1; }",
            // Запускать можно только после проверки подписи. Подменённая более старая сборка с нашей подписью не пройдёт.
            "[ \"$(\"$T\" version)\" = \(shQuote(FanLink.helperVersion)) ] || { echo 'Версия помощника не совпала с приложением' >&2; exit 1; }",
            // Жёсткая ссылка на старый файл сохранила бы его inode с setuid и после mv.
            "/bin/chmod 0755 \(shQuote(installedPath)) 2>/dev/null || true",
            "/bin/mv -f \"$T\" \(shQuote(installedPath))",
            "P=\"$D/plist\"",
            "/usr/bin/printf '%s' \(shQuote(plistXML)) > \"$P\"",
            "/usr/sbin/chown root:wheel \"$P\"",
            "/bin/chmod 0644 \"$P\"",
            "/bin/mv -f \"$P\" \(shQuote(plistPath))",
            "/bin/launchctl bootout \(serviceTarget) 2>/dev/null || true",
            // launchd отпускает метку не сразу после bootout.
            "for i in 1 2 3 4 5 6 7 8 9 10; do /bin/launchctl bootstrap system \(shQuote(plistPath)) && break; [ \"$i\" = 10 ] && exit 1; /bin/sleep 0.3; done",
        ].joined(separator: "; ")
    }

    nonisolated static var uninstallScript: String {
        [
            "/bin/launchctl bootout \(serviceTarget) 2>/dev/null || true",
            "/bin/rm -f \(shQuote(plistPath))",
            "/bin/rm -f \(shQuote(installedPath))",
        ].joined(separator: "; ")
    }

    private nonisolated static var serviceTarget: String { "system/\(FanLink.label)" }

    /// Строка в одинарных кавычках для sh: внутренняя `'` → `'\''`.
    private nonisolated static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Строка для AppleScript в двойных кавычках: экранируем `\` и `"`.
    nonisolated static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func run(admin shell: String) {
        lastError = nil
        // Окружение приложения может дойти до оболочки root: с такими переменными она выполнила бы чужой код.
        for name in ["SHELLOPTS", "BASHOPTS", "PS4", "ENV", "BASH_ENV", "IFS"] { unsetenv(name) }
        let source = "do shell script \(Self.appleScriptQuote(shell)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // -128 — пользователь нажал «Отменить», это не ошибка.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "Не удалось"
        }
    }
}
