import Foundation
import AppKit

/// Обновление из GitHub Releases: релиз собирает и подписывает автор на своём Mac
/// (scripts/release.sh) и прикладывает Utilitumus.zip.
/// Приложение скачивает его, проверяет, подменяет себя на месте и перезапускается.
///
/// Скачанное через URLSession карантинный атрибут не получает (приложение не
/// включает LSFileQuarantineEnabled) — Gatekeeper новую версию не блокирует.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    nonisolated static let repo = "IvanSSpace/utilitumus"
    nonisolated static let assetName = "Utilitumus.zip"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String, download: URL)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {}

    /// `quiet` — фоновая проверка при запуске: ошибки сети не показываем.
    func check(quiet: Bool = false) {
        if case .installing = state { return }
        state = .checking
        Task {
            do {
                // Релизов на GitHub ещё нет — значит, и новее нечего.
                guard let release = try await Self.latestRelease() else {
                    if quiet { state = .idle } else { show(.upToDate) }
                    return
                }
                let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Kit.isNewer(version, than: currentVersion) else {
                    if quiet { state = .idle } else { show(.upToDate) }
                    return
                }
                guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
                    if quiet { state = .idle } else { fail("В релизе \(release.tagName) нет \(Self.assetName)") }
                    return
                }
                state = .available(version: version, notes: release.body ?? "", download: asset.browserDownloadURL)
            } catch {
                if !quiet { fail(error.localizedDescription) }
                else { state = .idle }
            }
        }
    }

    /// Ошибка видна несколько секунд и уходит сама — не висит до перезапуска.
    private func fail(_ message: String) {
        show(.failed(message), for: 8)
    }

    /// Временный статус: если за это время ничего не поменялось — обратно в покой.
    private func show(_ status: State, for seconds: Double = 5) {
        state = status
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if state == status { state = .idle }
        }
    }

    func install() {
        guard case let .available(version, _, url) = state else { return }
        state = .installing
        Task {
            do {
                try await Self.downloadAndReplace(from: url, expectedVersion: version,
                                                  target: Bundle.main.bundleURL,
                                                  beforeReplace: {}, replaceFailed: {})
                Self.relaunch(Bundle.main.bundleURL)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Шаги (nonisolated — и для тестов)

    struct Release: Decodable {
        // Имена полей явно: convertFromSnakeCase превращает browser_download_url
        // в browserDownloadUrl (Url, не URL) — поле не находилось, и обновление
        // падало с «The data couldn't be read because it is missing».
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let body: String?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", body, assets
        }
    }

    /// nil — релизов ещё нет (GitHub отвечает 404).
    nonisolated static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Utilitumus-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError("GitHub ответил \(status)") }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Скачивает zip, распаковывает, проверяет, что внутри именно Utilitumus
    /// нужной версии с целой подписью, и подменяет `target`. Старая версия
    /// удаляется только после успешной подмены.
    nonisolated static func downloadAndReplace(
        from url: URL, expectedVersion: String, target: URL,
        beforeReplace: @escaping @MainActor @Sendable () -> Void,
        replaceFailed: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("utilitumus-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Не удалось скачать обновление") }
        let zip = work.appendingPathComponent(assetName)
        try fm.moveItem(at: downloaded, to: zip)

        let unpacked = work.appendingPathComponent("unpacked")
        try KitSigning.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        // После подмены бандла на диске служба может не принять этот процесс по подписи: «Авто» при выходе не дойдёт.
        try await UpdateBundle.install(unpacked.appendingPathComponent("Utilitumus.app"), expectedVersion: expectedVersion, target: target,
                                       beforeReplace: beforeReplace, replaceFailed: replaceFailed)
    }

    /// Открыть новую версию после выхода текущей. Выход штатный —
    /// applicationWillTerminate вернёт вентиляторы в «Авто».
    static func relaunch(_ app: URL) {
        if Kit.standRefuses("перезапуск приложения") { return }
        // Новый экземпляр открываем только после того, как этот процесс действительно
        // завершился: иначе `open` просто активирует ещё живое старое окно.
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                           app.path, String(pid)]
        try? shell.run()
        // Открытый лист (например, настройки, откуда нажали «Перезапустить») мешает
        // завершению: сначала закрываем листы, затем выходим.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
            // Если что-то всё же отменило выход — выходим принудительно через секунду.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
