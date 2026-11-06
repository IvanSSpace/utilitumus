import CryptoKit
import Foundation

struct SatellitePaths {
    var appsDir: URL
    var agentsDir: URL

    static let live = SatellitePaths(
        appsDir: URL(fileURLWithPath: "/Applications/Utilitumus"),
        agentsDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"))
}

enum SatelliteInstallError: LocalizedError, Equatable {
    case checksum
    case archive(String)
    case invalidName(String)
    case server(Int)
    case rollbackFailed(cause: String, problems: [String])

    var errorDescription: String? {
        switch self {
        case .checksum: return "Скачанный архив модуля повреждён: контрольная сумма не совпала"
        case .archive(let reason): return "Архив модуля не подходит: \(reason)"
        case .invalidName(let name): return "Недопустимое имя модуля: \(name)"
        case .server(let code): return "Не удалось скачать модуль: сервер ответил \(code)"
        case .rollbackFailed(let cause, let problems):
            return "\(cause). Вернуть прежнюю версию модуля не удалось: \(problems.joined(separator: "; "))"
        }
    }
}

/// Разговор с запущенной утилитой во время обновления и удаления.
struct SatelliteLink {
    /// Результат — выход процесса, а не ответ: ответа может и не быть, поэтому ошибок здесь нет.
    /// Не вышел — его снимет `bootout`.
    var quit: (String, LinkQuitReason) async -> Void
    var hello: (String) async throws -> Void
    /// launchd придерживает перезапуск процесса, прожившего меньше 10 с.
    var helloWindow: TimeInterval = 15

    static let live = SatelliteLink(
        quit: { id, reason in await liveQuit(id, reason) },
        hello: { id in try await liveHello(id) })

    @MainActor private static func liveQuit(_ id: String, _ reason: LinkQuitReason) async {
        try? await LinkClient(id: id).quit(reason)
    }

    @MainActor private static func liveHello(_ id: String) async throws {
        _ = try await LinkClient(id: id).hello()
    }
}

/// Ставит, обновляет и снимает утилиты. Порядок: скачать → `sha256` → распаковать во временную папку
/// на том же томе → проверить архив и подпись → заменить → плист → `bootstrap`. Пока подпись
/// не проверена, установленная версия и её агент не тронуты; ошибка после замены возвращает всё назад.
final class SatelliteInstaller {
    private let paths: SatellitePaths
    private let launchctl: ([String]) throws -> Void
    private let download: (URL) async throws -> URL
    private let verify: (URL, String) throws -> Void
    private let link: SatelliteLink
    private let fm = FileManager.default

    static let liveLaunchctl: ([String]) throws -> Void = { try KitSigning.run("/bin/launchctl", $0) }

    /// URLSession не ставит карантинный атрибут (см. `Updater`). Скачанное убирает `install`.
    static let liveDownload: (URL) async throws -> URL = { url in
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: file)
            throw SatelliteInstallError.server(http.statusCode)
        }
        return file
    }

    static let liveVerify: (URL, String) throws -> Void = {
        try KitSigning.verifySignature(of: $0, identifier: $1, strict: true)
    }

    init(
        paths: SatellitePaths,
        launchctl: @escaping ([String]) throws -> Void,
        download: @escaping (URL) async throws -> URL,
        verify: @escaping (URL, String) throws -> Void,
        link: SatelliteLink = .live
    ) {
        self.paths = paths
        self.launchctl = launchctl
        self.download = download
        self.verify = verify
        self.link = link
    }

    func install(_ app: CatalogApp, name: String) async throws {
        try Self.check(id: app.id)
        try Self.check(name: name)
        let archive = try await download(app.url)
        defer { try? fm.removeItem(at: archive) }
        // Только целостность скачанного: доверие держится на подписи.
        guard try Self.sha256(of: archive) == app.sha256.lowercased() else { throw SatelliteInstallError.checksum }

        // Система сама выбирает папку на нужном томе и сама подчищает её после сбоя процесса.
        // От родителя appsDir: при отказе в проверке appsDir так и не появится.
        let parent = paths.appsDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
        defer { try? fm.removeItem(at: work) }

        let staged = try unpack(archive, into: work, name: name)
        try verify(staged, KitLink.bundleID(app.id))
        let executable = try checkInfo(of: staged, against: app)

        let bundle = bundleURL(name)
        let agent = agentURL(app.id)
        let hadBundle = fm.fileExists(atPath: bundle.path)
        let oldAgent = try? Data(contentsOf: agent)
        let updating = hadBundle || oldAgent != nil
        let createdAppsDir = !fm.fileExists(atPath: paths.appsDir.path)
        // Копия на том же томе: APFS делает её мгновенно, старая версия нужна для отката.
        let oldBundle = work.appendingPathComponent("previous.app")
        if hadBundle { try fm.copyItem(at: bundle, to: oldBundle) }

        if updating { await link.quit(app.id, .update) }
        var replaced = false
        do {
            try fm.createDirectory(at: paths.appsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.agentsDir, withIntermediateDirectories: true)
            if hadBundle {
                _ = try fm.replaceItemAt(bundle, withItemAt: staged)
                replaced = true
            } else {
                try fm.moveItem(at: staged, to: bundle)
            }
            let installed = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
            try SatelliteAgent.plist(id: app.id, executable: installed).write(to: agent, options: .atomic)
            // И при первой установке: агент мог остаться загруженным без файла.
            bootout(app.id)
            try await bootstrap(agent)
            if updating { try await waitForHello(app.id) }
        } catch {
            let undo = Undo(
                id: app.id, bundle: bundle, agent: agent,
                oldBundle: hadBundle ? oldBundle : nil, oldAgent: oldAgent,
                replaced: replaced, createdAppsDir: createdAppsDir)
            // Своя задача: отмена install не должна оборвать откат, иначе `Task.sleep` между
            // попытками `bootstrap` бросит сразу и старая версия останется не загруженной.
            let problems = await Task { await self.rollback(undo) }.value
            guard problems.isEmpty else {
                throw SatelliteInstallError.rollbackFailed(cause: error.localizedDescription, problems: problems)
            }
            throw error
        }
    }

    /// Настройки утилиты остаются: они в общем домене и пригодятся при повторной установке.
    func remove(id: String, name: String) async throws {
        try Self.check(id: id)
        try Self.check(name: name)
        await link.quit(id, .uninstall)
        try removeStaleAgent(id: id)
        let bundle = bundleURL(name)
        if fm.fileExists(atPath: bundle.path) { try fm.removeItem(at: bundle) }
    }

    func removeStaleAgent(id: String) throws {
        try Self.check(id: id)
        bootout(id)
        let agent = agentURL(id)
        if fm.fileExists(atPath: agent.path) { try fm.removeItem(at: agent) }
    }

    /// Что вернуть, если установка сорвалась после начала изменений.
    private struct Undo {
        let id: String
        let bundle: URL
        let agent: URL
        let oldBundle: URL?
        let oldAgent: Data?
        let replaced: Bool
        let createdAppsDir: Bool
    }

    /// Возвращает то, что вернуть не удалось. Трогает только изменённое: при запрете записи старые
    /// бандл и плист целы, и повторная запись дала бы ложный сбой отката.
    private func rollback(_ undo: Undo) async -> [String] {
        var problems: [String] = []
        bootout(undo.id)
        do {
            if let oldBundle = undo.oldBundle {
                if undo.replaced || !fm.fileExists(atPath: undo.bundle.path) {
                    try Self.restore(oldBundle, to: undo.bundle)
                }
            } else if fm.fileExists(atPath: undo.bundle.path) {
                try fm.removeItem(at: undo.bundle)
            }
        } catch {
            problems.append(error.localizedDescription)
        }
        do {
            if let oldAgent = undo.oldAgent {
                if (try? Data(contentsOf: undo.agent)) != oldAgent {
                    try oldAgent.write(to: undo.agent, options: .atomic)
                }
                try await bootstrap(undo.agent)
            } else if fm.fileExists(atPath: undo.agent.path) {
                try fm.removeItem(at: undo.agent)
            }
        } catch {
            problems.append(error.localizedDescription)
        }
        // rmdir, а не removeItem: непустую папку он не удалит.
        if undo.createdAppsDir { rmdir(paths.appsDir.path) }
        return problems
    }

    /// Поведение `replaceItemAt` без цели документация не обещает, поэтому без цели — перемещение.
    static func restore(_ backup: URL, to bundle: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundle.path) {
            _ = try fm.replaceItemAt(bundle, withItemAt: backup)
        } else {
            try fm.moveItem(at: backup, to: bundle)
        }
    }

    /// `id` подставляется в требование подписи и в путь к плисту, а вызвать можно и в обход каталога.
    private static func check(id: String) throws {
        guard SatelliteCatalog.isValidID(id) else { throw SatelliteCatalogError.invalidID(id) }
    }

    /// Имя становится путём: `../Имя` указал бы на бандл вне `appsDir`, а `remove` его удалит.
    private static func check(name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw SatelliteInstallError.invalidName(name)
        }
    }

    private func bundleURL(_ name: String) -> URL { paths.appsDir.appendingPathComponent(name + ".app") }
    private func agentURL(_ id: String) -> URL { paths.agentsDir.appendingPathComponent(KitLink.bundleID(id) + ".plist") }

    /// Отказ — обычно значит «не был загружен»; настоящий сбой покажет следующий `bootstrap`.
    private func bootout(_ id: String) {
        try? launchctl(["bootout", "gui/\(getuid())/\(KitLink.bundleID(id))"])
    }

    /// launchd отпускает метку не сразу после `bootout`.
    private func bootstrap(_ agent: URL) async throws {
        var attemptsLeft = 10
        while true {
            do {
                try launchctl(["bootstrap", "gui/\(getuid())", agent.path])
                return
            } catch {
                attemptsLeft -= 1
                if attemptsLeft == 0 { throw error }
                try await Task.sleep(for: .seconds(0.3))
            }
        }
    }

    private func waitForHello(_ id: String) async throws {
        let deadline = Date().addingTimeInterval(link.helloWindow)
        while true {
            do {
                try await link.hello(id)
                return
            } catch {
                if Date() >= deadline { throw error }
                try await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    // MARK: - Архив

    /// Распаковывает и проверяет форму архива. Подпись проверяется уже после этого, у результата.
    private func unpack(_ archive: URL, into work: URL, name: String) throws -> URL {
        // ditto молча убирает `..` и начальный `/`, и такой архив выглядел бы обычным:
        // смотреть надо до распаковки.
        for entry in try Self.entries(of: archive) {
            let parts = entry.split { $0 == "/" || $0 == "\\" }
            guard !entry.hasPrefix("/"), !parts.contains("..") else {
                throw SatelliteInstallError.archive("путь выходит за пределы папки: \(entry)")
            }
        }
        let unpacked = work.appendingPathComponent("unpacked")
        do {
            try KitSigning.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        } catch {
            throw SatelliteInstallError.archive(error.localizedDescription)
        }

        let top = try fm.contentsOfDirectory(atPath: unpacked.path)
        guard top == [name + ".app"] else {
            throw SatelliteInstallError.archive("ждали только \(name).app, внутри: \(top.sorted().joined(separator: ", "))")
        }
        let app = unpacked.appendingPathComponent(name + ".app")
        // attributesOfItem не идёт по ссылке: сам бандл ссылкой быть не может.
        let attributes = try fm.attributesOfItem(atPath: app.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw SatelliteInstallError.archive("\(name).app — не папка")
        }
        guard !Self.writableByOthers(attributes) else {
            throw SatelliteInstallError.archive("запись разрешена группе или всем: \(name).app")
        }
        try rejectUnsafeItems(in: app)
        return app
    }

    /// Ссылка годится, только если настоящий путь ведёт внутрь бандла. Цепочки и ссылки в пустоту
    /// проверяет realpath: разобрать такое на строках надёжно нельзя. Режимы файлов подпись
    /// не запечатывает, поэтому запись для группы и всех проверяется здесь.
    private func rejectUnsafeItems(in app: URL) throws {
        guard let root = Self.realPath(app.path), let walker = fm.enumerator(atPath: app.path) else {
            throw SatelliteInstallError.archive("бандл не читается")
        }
        for case let relative as String in walker {
            let attributes = walker.fileAttributes ?? [:]
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let target = Self.realPath(app.path + "/" + relative)
                guard let target, target == root || target.hasPrefix(root + "/") else {
                    throw SatelliteInstallError.archive("ссылка ведёт за пределы бандла: \(relative)")
                }
            } else if Self.writableByOthers(attributes) {
                throw SatelliteInstallError.archive("запись разрешена группе или всем: \(relative)")
            }
        }
    }

    /// Нет сведений о режиме — считается небезопасным.
    private static func writableByOthers(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let mode = attributes[.posixPermissions] as? Int else { return true }
        return mode & 0o022 != 0
    }

    /// Сверка с каталогом уже после подписи: Info.plist ею запечатан. Возвращает имя исполняемого файла.
    private func checkInfo(of bundle: URL, against app: CatalogApp) throws -> String {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let identifier = info?["CFBundleIdentifier"] as? String
        guard identifier == KitLink.bundleID(app.id) else {
            throw SatelliteInstallError.archive("в бандле другой identifier: \(identifier ?? "нет")")
        }
        let version = info?["CFBundleShortVersionString"] as? String
        guard version == app.version else {
            throw SatelliteInstallError.archive("в бандле версия \(version ?? "нет"), в каталоге \(app.version)")
        }
        guard let executable = info?["CFBundleExecutable"] as? String,
              fm.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path) else {
            throw SatelliteInstallError.archive("в бандле нет исполняемого файла")
        }
        return executable
    }

    private static func entries(of archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let listing = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SatelliteInstallError.archive("это не zip") }
        return String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func sha256(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
