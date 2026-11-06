import CryptoKit
import Foundation

/// Утилита обновляет себя, пока центра нет. Доверие держится на подписи, как у установщика центра,
/// но ни плист, ни агента здесь не трогаем: меняется только бандл.
enum SatelliteSelfUpdate {
    static func newer(in catalog: Catalog, id: String, than current: String) -> CatalogApp? {
        catalog.apps.first { $0.id == id && Kit.isNewer($0.version, than: current) }
    }

    /// Пока подпись и версия не проверены, `target` не тронут. Перезапуск — дело вызывающего.
    /// `beforeReplace` идёт после всех проверок и прямо перед заменой: после неё сервис вентиляторов может уже
    /// не принять этот процесс. Если он бросил, бандл остаётся прежним.
    static func install(_ app: CatalogApp, target: URL, beforeReplace: () async throws -> Void = {}) async throws {
        let fm = FileManager.default
        let (archive, response) = try await URLSession.shared.download(from: app.url)
        defer { try? fm.removeItem(at: archive) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KitSigning.Failure("Не удалось скачать обновление: сервер ответил \(http.statusCode)")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == app.sha256.lowercased() else {
            throw KitSigning.Failure("Скачанное обновление повреждено: контрольная сумма не совпала")
        }

        // На томе цели: замена атомарная.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: work) }
        try KitArchive.extract(archive, to: work)
        let name = target.lastPathComponent
        guard try fm.contentsOfDirectory(atPath: work.path) == [name] else {
            throw KitSigning.Failure("В архиве обновления не только \(name)")
        }
        let staged = work.appendingPathComponent(name)

        try KitSigning.rejectWritableModes(in: staged)

        let identifier = KitLink.bundleID(app.id)
        try KitSigning.verifyApp(staged, identifier: identifier)
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == identifier, info?["CFBundleShortVersionString"] as? String == app.version else {
            throw KitSigning.Failure("В архиве обновления не та версия")
        }
        try await beforeReplace()
        _ = try fm.replaceItemAt(target, withItemAt: staged)
    }
}
