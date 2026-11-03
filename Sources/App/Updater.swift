import Foundation
import AppKit

/// Обновление из GitHub Releases: релиз собирает GitHub Actions
/// (.github/workflows/release.yml) и прикладывает Utilitumus.zip.
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
                    state = quiet ? .idle : .upToDate
                    return
                }
                let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Self.isNewer(version, than: currentVersion) else {
                    state = quiet ? .idle : .upToDate
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
        let failure = State.failed(message)
        state = failure
        Task {
            try? await Task.sleep(for: .seconds(8))
            if state == failure { state = .idle }
        }
    }

    func install() {
        guard case let .available(version, _, url) = state else { return }
        state = .installing
        Task {
            do {
                try await Self.downloadAndReplace(from: url, expectedVersion: version,
                                                  target: Bundle.main.bundleURL)
                Self.relaunch(Bundle.main.bundleURL)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Шаги (nonisolated — и для тестов)

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
        }
        let tagName: String
        let body: String?
        let assets: [Asset]
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    /// Сравнение по числам: 0.10.0 новее 0.9.1.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Скачивает zip, распаковывает, проверяет, что внутри именно Utilitumus
    /// нужной версии с целой подписью, и подменяет `target`. Старая версия
    /// удаляется только после успешной подмены.
    nonisolated static func downloadAndReplace(from url: URL, expectedVersion: String, target: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("utilitumus-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Не удалось скачать обновление") }
        let zip = work.appendingPathComponent(assetName)
        try fm.moveItem(at: downloaded, to: zip)

        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("Utilitumus.app")

        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == "local.utilitumus",
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError("В архиве не та версия Utilitumus")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])

        // Копия рядом с целью (тот же том) — тогда подмена атомарная.
        let staged = target.deletingLastPathComponent().appendingPathComponent("Utilitumus.app.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: app, to: staged)
        _ = try fm.replaceItemAt(target, withItemAt: staged)
    }

    /// Открыть новую версию после выхода текущей. Выход штатный —
    /// applicationWillTerminate вернёт вентиляторы в «Авто» и погасит lambscape.
    static func relaunch(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError("\((tool as NSString).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
