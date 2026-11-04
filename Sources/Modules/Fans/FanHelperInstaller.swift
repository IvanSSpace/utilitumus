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
        let installedPath = Self.installedPath, bundledPath = Self.bundledPath
        Task { [weak self] in
            let ready = await Task.detached {
                let installed = Self.version(of: installedPath)
                return installed != nil && installed == Self.version(of: bundledPath)
            }.value
            self?.status = ready ? .ready : .outdated
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
