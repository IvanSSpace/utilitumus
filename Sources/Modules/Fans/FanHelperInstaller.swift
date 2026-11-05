import Foundation
import AppKit

/// Установка/удаление root-помощника `utilitumus-fan`. Права спрашивает сама
/// macOS — стандартное окно «Utilitumus хочет внести изменения» (пароль или
/// Touch ID) через `do shell script … with administrator privileges`.
@MainActor
final class FanHelperInstaller: ObservableObject {
    static let shared = FanHelperInstaller()

    enum Status: Equatable {
        case notInstalled
        /// Стоит, но версия старше помощника внутри приложения.
        case outdated
        case ready
    }

    nonisolated static let installedPath = "/Library/PrivilegedHelperTools/local.utilitumus.fan"
    private nonisolated static var bundledPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/utilitumus-fan").path
    }

    @Published private(set) var status: Status = .notInstalled
    @Published private(set) var lastError: String?

    private init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.installedPath),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              perms & 0o4000 != 0 else {
            status = .notInstalled
            return
        }
        // По номеру версии, а не побайтово: байты меняются при каждой сборке
        // (и всегда отличаются у сборки с GitHub), а просить пароль надо, только
        // когда помощник действительно изменился.
        //
        // В фоне, не на главном потоке: waitUntilExit крутит run loop, и пока
        // shared ещё создаётся, SwiftUI успевал отрисовать FansView, тот лез в
        // недосозданный shared — падение «dispatch_once: lock recursively».
        // До ответа считаем установленный помощник рабочим — без мигания плашки.
        if status == .notInstalled { status = .ready }
        // Права 4755 от старых установок — тоже «устарел»: переустановка даст 4750 root:admin.
        let modeOK = perms & 0o7777 == 0o4750
        let installedPath = Self.installedPath, bundledPath = Self.bundledPath
        Task { [weak self] in
            let ready = await Task.detached {
                let installed = Self.version(of: installedPath)
                return installed != nil && installed == Self.version(of: bundledPath)
            }.value
            self?.status = ready && modeOK ? .ready : .outdated
        }
    }

    /// `utilitumus-fan version`; nil — старый помощник без этой команды.
    private nonisolated static func version(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    func install() {
        let src = Self.bundledPath
        let dir = "/Library/PrivilegedHelperTools"
        let dst = Self.installedPath
        let id = "local.utilitumus.fan"
        // Проверка подписи — ВНУТРИ root-скрипта и на копии, которую пользователь уже
        // не может подменить: иначе между проверкой и установкой (TOCTOU) обычный
        // процесс успел бы подсунуть другой бинарь, и он получил бы root (setuid).
        // Временный каталог создаётся в /Library/PrivilegedHelperTools (пишет только root,
        // тот же том — mv атомарный) с правами 0700.
        let verify = KitSigning.trustedLeafHashes.map {
            "/usr/bin/codesign --verify " + Self.shQuote("-R=" + KitSigning.requirement(identifier: id, leafHash: $0)) + " \"$T\""
        }.joined(separator: " || ")
        let script = [
            "set -e",
            "/bin/mkdir -p \(Self.shQuote(dir))",
            "D=$(/usr/bin/mktemp -d \(Self.shQuote(dir + "/.install.XXXXXX")))",
            "trap '/bin/rm -rf \"$D\"' EXIT",
            "T=\"$D/helper\"",
            "/bin/cp \(Self.shQuote(src)) \"$T\"",
            "/usr/sbin/chown root:wheel \"$T\"",
            "/bin/chmod 0755 \"$T\"",
            "(\(verify)) || { echo 'Подпись помощника не совпала с подписью автора' >&2; exit 1; }",
            // 4750 root:admin — запускать помощника могут только администраторы мака,
            // а не любой локальный пользователь.
            "/usr/sbin/chown root:admin \"$T\"",
            "/bin/chmod 4750 \"$T\"",
            "/bin/mv -f \"$T\" \(Self.shQuote(dst))",
        ].joined(separator: "; ")
        run(admin: script)
    }

    func uninstall() {
        run(admin: "/bin/rm -f \(Self.shQuote(Self.installedPath))")
    }

    /// Строка в одинарных кавычках для sh: внутренняя `'` → `'\''`.
    private nonisolated static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Строка для AppleScript в двойных кавычках: экранируем `\` и `"`.
    private nonisolated static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func run(admin shell: String) {
        lastError = nil
        let source = "do shell script \(Self.appleScriptQuote(shell)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // -128 — пользователь нажал «Отменить», это не ошибка.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "Не удалось"
        }
        refresh()
    }
}
