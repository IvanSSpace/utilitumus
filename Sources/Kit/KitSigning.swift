import Foundation

/// Проверка подписи: свои бинарники и скачанные сборки сверяются со списком сертификатов, вшитым в приложение.
enum KitSigning {
    /// SHA-1 листовых сертификатов, которыми разрешено подписывать релизы. Список
    /// вшит в приложение: его не подменить через GitHub. Новый ключ добавляется
    /// сюда ДО того, как им подписан первый релиз, старый убирается позже.
    static let trustedLeafHashes = [
        "31e93f4b9e4ada7f6de82066c2194b35d92f7db4",  // «Utilitumus Signing»
    ]

    /// Требование к подписи: свой identifier и листовой сертификат из доверенного списка.
    static func requirement(identifier: String, leafHash: String) -> String {
        "identifier \"\(identifier)\" and certificate leaf = H\"\(leafHash)\""
    }

    /// Проходит `codesign --verify` хотя бы с одним доверенным хэшем. `-R=текст` —
    /// требование строкой (без `=` codesign принял бы это за путь к файлу).
    static func verifySignature(of path: URL, identifier: String, strict: Bool) throws {
        var lastError: Error?
        for hash in trustedLeafHashes {
            var args = ["--verify"]
            if strict { args += ["--deep", "--strict"] }
            args += ["-R=" + requirement(identifier: identifier, leafHash: hash), path.path]
            do {
                try run("/usr/bin/codesign", args)
                return
            } catch {
                lastError = error
            }
        }
        throw Failure("Подпись \(path.lastPathComponent) не от автора Utilitumus: \(lastError?.localizedDescription ?? "")")
    }

    /// Запускает системную программу и ждёт её. Код выхода не 0 — ошибка с текстом из stderr.
    static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        try process.run()
        // Сначала чтение: процесс, заполнивший канал, не выйдет, пока его не прочитают.
        let output = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            throw Failure("\((tool as NSString).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
