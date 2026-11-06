import Foundation

/// Вложенный исполняемый код приложения со своей подписью.
struct KitHelper: Equatable {
    /// Относительно корня бандла. `.app` — вложенный бандл, иначе отдельный бинарник.
    let path: String
    let identifier: String

    var isBundle: Bool { path.hasSuffix(".app") }
}

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

    /// Метка выпуска в Info.plist, её скрепляет подпись. Выпуски v0.2.0–v0.4.4 подписаны нашим сертификатом
    /// с тем же identifier, но без hardened runtime: в такой бинарник внедряют код через DYLD_INSERT_LIBRARIES,
    /// и identifier с сертификатом он всё равно проходит. Выпуск с уязвимостью отсекается повышением эпохи.
    static let securityEpochKey = "UtilitumusSecurityEpoch"
    static let securityEpoch = "1"
    /// Метка сборок со швом `KIT_TEST_DEFAULTS` (стенды и проверки). Они подписаны тем же сертификатом и тем же
    /// identifier, поэтому от боевых их отличает только метка: боевые требования ждут `securityEpoch` и стенд не пропускают,
    /// а стенд ждёт эту и не пропускает боевых. Числом она не читается, значит и `checkEpoch` боевой сборки её отвергает.
    static let testPeerEpoch = "test.1"
    #if KIT_TEST_DEFAULTS
    static let peerEpoch = testPeerEpoch
    #else
    static let peerEpoch = securityEpoch
    #endif
    /// Боевым нельзя просто `>=`: для требований «test.1» больше «1», и сборка со швом прошла бы как боевая (проверено на `codesign -R`).
    /// Верхняя граница отсекает метки не из цифр. Сборка со швом ждёт только свою.
    #if KIT_TEST_DEFAULTS
    static let peerEpochClause = "info[\"\(securityEpochKey)\"] = \"\(testPeerEpoch)\""
    #else
    static let peerEpochClause = "info[\"\(securityEpochKey)\"] >= \"\(securityEpoch)\" and info[\"\(securityEpochKey)\"] < \"a\""
    #endif

    /// Требование к процессу-собеседнику по XPC: центру и утилите. Метка своей или новее, как у `checkEpoch` и `epoch_ok`
    /// в install.sh: иначе центр с меткой 1 поставил бы утилиту с меткой 2 и не смог бы с ней говорить. `>=` сравнивает
    /// как числа (проверено на `codesign -R`: «225» >= «9»), а не как строки.
    static func peerRequirement(identifier: String, leafHash: String) -> String {
        requirement(identifier: identifier, leafHash: leafHash) + " and " + peerEpochClause
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
        let message = "Подпись \(path.lastPathComponent) не от автора Utilitumus"
        throw Failure(log: "\(message): \(lastError?.localizedDescription ?? "")", user: message)
    }

    /// Помощники утилит по их bundle id. Новый помощник дописывается сюда и в `helpers_of` в install.sh:
    /// build-app.sh не соберёт манифест, который с install.sh расходится, а Tests/run-helper-identity-check.sh
    /// сверяет install.sh с этой таблицей. Список вшит в проверяющего: подделанный бандл не вычеркнет из него помощника.
    static let helpers: [String: [KitHelper]] = [
        "local.utilitumus.app.browser": [KitHelper(path: "Contents/Helpers/Utilitumus Links.app", identifier: "local.utilitumus.links")],
        "local.utilitumus.app.fans": [KitHelper(path: "Contents/MacOS/utilitumus-fan", identifier: "local.utilitumus.fan")],
        "local.utilitumus.app.voice": [KitHelper(path: "Contents/MacOS/utilitumus-voice", identifier: "local.utilitumus.voice")],
    ]

    /// Проверка утилиты перед установкой: сама подпись, метка выпуска и каждый её помощник.
    static func verifyApp(_ app: URL, identifier: String) throws {
        try verifySignature(of: app, identifier: identifier, strict: true)
        try checkEpoch(of: app)
        try rejectTestSeam(in: app)
        for helper in helpers[identifier] ?? [] {
            try verifyHelper(helper, in: app)
        }
    }

    /// Вложенный код запечатан подписью внешнего бандла, но личность его подписанта она не проверяет.
    /// У бинарника нет Info.plist, а значит и метки выпуска (как у службы в `FanLink.serviceRequirement`). Метка нужна,
    /// чтобы отсечь сборки без hardened runtime, поэтому у всех помощников runtime проверяется прямо.
    static func verifyHelper(_ helper: KitHelper, in app: URL) throws {
        let url = app.appendingPathComponent(helper.path)
        // attributesOfItem не идёт по ссылке: помощник не может указывать на другой файл.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard type == (helper.isBundle ? .typeDirectory : .typeRegular) else {
            throw Failure("В сборке нет помощника \(url.lastPathComponent)")
        }
        try verifySignature(of: url, identifier: helper.identifier, strict: helper.isBundle)
        if helper.isBundle { try checkEpoch(of: url) }
        try requireRuntime(url, what: "Помощник \(url.lastPathComponent)")
    }

    /// Hardened runtime в подписи: без него в процесс внедряют код через DYLD_INSERT_LIBRARIES.
    static func requireRuntime(_ url: URL, what: String) throws {
        let details = try run("/usr/bin/codesign", ["-d", "--verbose=1", url.path])
        guard details.range(of: #"flags=0x[0-9a-f]+\([^)]*\bruntime\b"#, options: .regularExpression) != nil else {
            throw Failure("\(what) собран без hardened runtime")
        }
    }

    /// Вызывать после проверки подписи: Info.plist запечатан ею. Метка может быть новее своей: иначе старая
    /// утилита не обновилась бы до выпуска с поднятой меткой. Старее нельзя: ради этого метку и поднимают.
    static func checkEpoch(of bundle: URL) throws {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        #if KIT_TEST_DEFAULTS
        if info?[securityEpochKey] as? String == testPeerEpoch { return }
        #endif
        guard let found = (info?[securityEpochKey] as? String).flatMap({ Int($0) }),
              let own = Int(securityEpoch), found >= own else {
            throw Failure("У \(bundle.lastPathComponent) нет метки выпуска \(securityEpoch) или новее")
        }
    }

    /// Сборка для проверок не должна попасть к человеку: она подписана боевым ключом, но несёт шов (SIGUSR, свой домен
    /// настроек). Метка выпуска её и так не пропустит (`checkEpoch`); это вторая, независимая проверка по содержимому.
    /// Образец собран из частей: целиком он был бы строкой в самом проверяющем и находил бы его.
    static func rejectTestSeam(in bundle: URL) throws {
        // Стенд сам собран со швом и ставит сборки со швом.
        #if !KIT_TEST_DEFAULTS
        let needle = Data(["local", "utilitumus", "test", ""].joined(separator: ".").utf8)
        let walker = FileManager.default.enumerator(atPath: bundle.path)
        while let relative = walker?.nextObject() as? String {
            guard walker?.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  relative.hasSuffix("Info.plist") || relative.contains("Contents/MacOS/") || relative.contains("Contents/Helpers/"),
                  let data = try? Data(contentsOf: bundle.appendingPathComponent(relative), options: .mappedIfSafe) else { continue }
            if data.range(of: needle) != nil {
                throw Failure("В сборке следы тестового шва: \(relative)")
            }
        }
        #endif
    }

    /// Режимы файлов подпись не запечатывает: перепакованная настоящая сборка с правами 0777
    /// пройдёт проверку подписи, а файлы приложения сможет менять другая учётная запись.
    static func rejectWritableModes(in bundle: URL) throws {
        let fm = FileManager.default
        func safe(_ attributes: [FileAttributeKey: Any]) -> Bool {
            attributes[.type] as? FileAttributeType == .typeSymbolicLink
                || (attributes[.posixPermissions] as? Int).map { $0 & 0o022 == 0 } == true
        }
        guard safe(try fm.attributesOfItem(atPath: bundle.path)) else {
            throw Failure("В обновлении запись разрешена группе или всем: \(bundle.lastPathComponent)")
        }
        let walker = fm.enumerator(atPath: bundle.path)
        while let relative = walker?.nextObject() as? String {
            guard safe(walker?.fileAttributes ?? [:]) else {
                throw Failure("В обновлении запись разрешена группе или всем: \(relative)")
            }
        }
    }

    /// Запускает системную программу и ждёт её. Код выхода не 0 — ошибка с текстом из stderr. Возвращает stderr.
    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        try process.run()
        // Сначала чтение: процесс, заполнивший канал, не выйдет, пока его не прочитают.
        let output = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: output, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure(log: "\((tool as NSString).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))", user: nil)
        }
        return text
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        /// Для интерфейса. Вывод системных программ английский, ему место в журнале: nil — своего текста нет.
        let userMessage: String?

        init(_ message: String) { self.init(log: message, user: message) }

        init(log: String, user: String?) {
            errorDescription = log
            userMessage = user
        }
    }
}
