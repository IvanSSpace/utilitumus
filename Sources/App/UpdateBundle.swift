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
        // Вложенные бинарники запечатаны подписью основного бандла, но личность их
        // подписанта отдельно не проверена — сверяем со своим identifier.
        let links = app.appendingPathComponent("Contents/Helpers/Utilitumus Links.app")
        if fm.fileExists(atPath: links.path) {
            try KitSigning.verifySignature(of: links, identifier: "local.utilitumus.links", strict: true)
        }
        let fan = app.appendingPathComponent("Contents/MacOS/utilitumus-fan")
        if fm.fileExists(atPath: fan.path) {
            try KitSigning.verifySignature(of: fan, identifier: "local.utilitumus.fan", strict: false)
        }
        let voice = app.appendingPathComponent("Contents/MacOS/utilitumus-voice")
        if fm.fileExists(atPath: voice.path) {
            try KitSigning.verifySignature(of: voice, identifier: "local.utilitumus.voice", strict: false)
        }
    }

    /// `afterCopy` нужен только проверке: подмена копии в промежутке между копированием и заменой.
    static func install(_ app: URL, expectedVersion: String, target: URL, afterCopy: (URL) throws -> Void = { _ in }) throws {
        let fm = FileManager.default
        try verify(app, expectedVersion: expectedVersion)
        // Копия рядом с целью (тот же том) — тогда подмена атомарная.
        let staged = target.deletingLastPathComponent().appendingPathComponent("Utilitumus.app.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: app, to: staged)
        do {
            try afterCopy(staged)
            // Распакованную папку могли изменить после первой проверки, поэтому ещё раз — то, что встанет на место.
            try verify(staged, expectedVersion: expectedVersion)
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }
}
