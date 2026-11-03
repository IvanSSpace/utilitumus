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
        /// Стоит, но не совпадает с помощником внутри приложения (пересобрали).
        case outdated
        case ready
    }

    nonisolated static let installedPath = "/Library/PrivilegedHelperTools/local.utilitumus.fan"
    private static var bundledPath: String {
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
        status = fm.contentsEqual(atPath: Self.installedPath, andPath: Self.bundledPath) ? .ready : .outdated
    }

    func install() {
        let src = Self.bundledPath
        let dst = Self.installedPath
        run(admin: "mkdir -p /Library/PrivilegedHelperTools && cp '\(src)' '\(dst)' && chown root:wheel '\(dst)' && chmod 4755 '\(dst)'")
    }

    func uninstall() {
        run(admin: "rm -f '\(Self.installedPath)'")
    }

    private func run(admin shell: String) {
        lastError = nil
        let source = "do shell script \"\(shell)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // -128 — пользователь нажал «Отменить», это не ошибка.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "Не удалось"
        }
        refresh()
    }
}
