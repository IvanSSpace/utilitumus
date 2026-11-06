import Foundation

/// Распаковка скачанного zip. Архив недоверенный, а `ditto` пишет на диск раньше любой проверки подписи:
/// ссылка внутри архива, за которой идёт файл «через» неё, увела бы запись за пределы папки.
/// Поэтому состав архива смотрится до распаковки по его оглавлению, а не по готовой папке.
enum KitArchive {
    /// Проверяет оглавление и только потом распаковывает. При отказе `destination` не создаётся.
    static func extract(_ archive: URL, to destination: URL) throws {
        try vet(archive)
        try KitSigning.run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
    }

    /// Отказ на путь за пределы папки и на всё, кроме обычных файлов и каталогов (ссылки, устройства, сокеты).
    static func vet(_ archive: URL) throws {
        guard let names = list(archive, ["-Z1"]), let modes = list(archive, ["-Z"]) else {
            throw KitSigning.Failure("Скачанный файл — не zip")
        }
        for entry in names.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            // ditto молча убирает `..` и начальный `/`, и такой архив выглядел бы обычным.
            let parts = entry.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }
            guard !entry.hasPrefix("/"), !parts.contains("..") else {
                throw KitSigning.Failure("В архиве путь за пределы папки: \(entry)")
            }
            guard !entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw KitSigning.Failure("В архиве управляющий символ в имени: \(entry.debugDescription)")
            }
        }
        // Строка записи начинается с режима вроде `lrwxr-xr-x` или `-rw-a--` (zip из DOS); шапка и итог в неё не попадают.
        let entryLine = try NSRegularExpression(pattern: #"^([-dlcbpsD])[-rwxsStTa]{6,9}\s"#)
        for line in modes.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = entryLine.firstMatch(in: line, range: range),
                  let kind = Range(match.range(at: 1), in: line).map({ line[$0] }) else { continue }
            guard kind == "-" || kind == "d" else {
                throw KitSigning.Failure("В архиве ссылка или особый файл: \(line)")
            }
        }
    }

    private static func list(_ archive: URL, _ options: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = options + [archive.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Сначала чтение: процесс, заполнивший канал, не выйдет, пока его не прочитают.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
