import Foundation

/// Проверка и установка распакованного обновления. Пока всё не проверено, `target` не тронут.
enum UpdateBundle {
    static func verify(_ app: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == "local.utilitumus",
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw KitSigning.Failure("В архиве не та версия Utilitumus")
        }
        try KitSigning.rejectWritableModes(in: app)
        // Подпись проверяем ВСЕГДА и по вшитому в приложение списку хэшей, а не по
        // подписи текущей сборки: иначе, если текущая сборка ad-hoc (или подменена),
        // атакующий, получивший контроль над GitHub, подсунул бы любой архив.
        try KitSigning.verifySignature(of: app, identifier: "local.utilitumus", strict: true)
        // Метка выпуска и hardened runtime: старые сборки автора с тем же identifier и сертификатом, но без них,
        // подпись проходят. Метка может быть новее своей (checkEpoch), поэтому будущие выпуски обновляются.
        try KitSigning.checkEpoch(of: app)
        try KitSigning.rejectTestSeam(in: app)
        try KitSigning.requireRuntime(app, what: app.lastPathComponent)
        // Вложенные бинарники запечатаны подписью основного бандла, но личность их
        // подписанта отдельно не проверена — сверяем со своим identifier, меткой и runtime.
        for helper in [
            KitHelper(path: "Contents/Helpers/Utilitumus Links.app", identifier: "local.utilitumus.links"),
            KitHelper(path: "Contents/MacOS/utilitumus-fan", identifier: "local.utilitumus.fan"),
            KitHelper(path: "Contents/MacOS/utilitumus-voice", identifier: "local.utilitumus.voice"),
        ] where fm.fileExists(atPath: app.appendingPathComponent(helper.path).path) || isLink(app.appendingPathComponent(helper.path)) {
            try KitSigning.verifyHelper(helper, in: app)
        }
    }

    /// Битая ссылка на месте помощника тоже должна дойти до проверки: `fileExists` ходит по ссылке.
    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Проверяет `app` и кладёт копию рядом с целью (тот же том, подмена будет атомарной). `target` не тронут.
    /// `afterCopy` нужен только проверке: подмена копии в промежутке между копированием и заменой.
    static func stage(_ app: URL, expectedVersion: String, target: URL, afterCopy: (URL) throws -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        try verify(app, expectedVersion: expectedVersion)
        let staged = target.deletingLastPathComponent().appendingPathComponent("Utilitumus.app.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: app, to: staged)
        do {
            try afterCopy(staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// Распакованную папку и копию могли изменить после первой проверки, поэтому ещё раз — то, что встанет на место.
    static func commit(_ staged: URL, expectedVersion: String, target: URL) throws {
        let fm = FileManager.default
        do {
            try verify(staged, expectedVersion: expectedVersion)
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    static func install(_ app: URL, expectedVersion: String, target: URL, afterCopy: (URL) throws -> Void = { _ in }) throws {
        let staged = try stage(app, expectedVersion: expectedVersion, target: target, afterCopy: afterCopy)
        try commit(staged, expectedVersion: expectedVersion, target: target)
    }
}
