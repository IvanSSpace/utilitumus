import CryptoKit
import Foundation

// Проверка каталога и установщика. Запуск: Tests/run-satellite-installer-check.sh
// Аргументы: папка с готовыми архивами, папка для стендов, путь к Catalog/catalog.json.
// Каждая отвергнутая установка сверяет и причину отказа: фикстура, сломанная по ошибке, не пройдёт за успех.

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let workRoot = URL(fileURLWithPath: CommandLine.arguments[2])
let repoCatalog = URL(fileURLWithPath: CommandLine.arguments[3])
nonisolated(unsafe) let fm = FileManager.default

let appID = "test.fixture"
let identifier = "local.utilitumus.app.test.fixture"
let appName = "Fixture"

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// MARK: - Каталог

func json(schema: Int = 1, ids: [String] = ["awake"], version: String = "1.0.0", minHub: String = "0.6.0") -> Data {
    let apps = ids.map { id -> [String: Any] in
        ["id": id, "version": version, "minHub": minHub, "url": "https://example.com/Awake.zip", "sha256": "ab", "sizeMB": 2]
    }
    return try! JSONSerialization.data(withJSONObject: ["schema": schema, "apps": apps])
}

func catalogChecks() {
    check(SatelliteCatalog.url.absoluteString == "https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/Catalog/catalog.json", "адрес каталога")

    let one = try? SatelliteCatalog.decode(json())
    check(one?.schema == 1, "хороший каталог: schema")
    check(one?.apps == [CatalogApp(id: "awake", version: "1.0.0", minHub: "0.6.0", url: URL(string: "https://example.com/Awake.zip")!, sha256: "ab", sizeMB: 2)], "хороший каталог: поля приложения")

    let repo = (try? Data(contentsOf: repoCatalog)).flatMap { try? SatelliteCatalog.decode($0) }
    check(repo?.schema == 1 && repo?.apps.isEmpty == true, "Catalog/catalog.json: schema 1, пустой")

    check((try? SatelliteCatalog.decode(Data("{не json".utf8))) == nil, "мусор — ошибка")
    func decodeError(_ data: Data) -> SatelliteCatalogError? {
        do {
            _ = try SatelliteCatalog.decode(data)
            return nil
        } catch {
            return error as? SatelliteCatalogError
        }
    }
    check(decodeError(json(schema: 2)) == .schema(2), "schema 2 — ошибка schema(2)")
    for bad in [#"x" or identifier "y"#, "awake\n", "Awake", ".awake", "-awake", "", "a/b", "../x", "a b", "аwake"] {
        check(decodeError(json(ids: [bad])) == .invalidID(bad), "id «\(bad)» отвергается")
    }
    check(decodeError(json(ids: ["awake", #"x" or identifier "y"#])) == .invalidID(#"x" or identifier "y"#), "один плохой id отвергает весь каталог")
    for good in ["awake", "a", "0", "a.b-c9"] {
        check((try? SatelliteCatalog.decode(json(ids: [good]))) != nil, "id «\(good)» принимается")
    }

    for bad in ["", "abc", "1.0-beta", "1..0", ".1", "1.", "1.0\n", "v1.0", "１.０"] {
        check(decodeError(json(version: bad)) == .invalidVersion(bad), "version «\(bad)» отвергается")
        check(decodeError(json(minHub: bad)) == .invalidVersion(bad), "minHub «\(bad)» отвергается")
    }
    for good in ["1", "0.6.0", "10.20.30.40"] {
        check((try? SatelliteCatalog.decode(json(version: good, minHub: good))) != nil, "версия «\(good)» принимается")
    }

    // Проверка в самом CatalogApp: мимо decode её не обойти.
    let single = #"{"id":"a/b","version":"1.0.0","minHub":"0.6.0","url":"https://example.com/a.zip","sha256":"ab","sizeMB":1}"#
    do {
        _ = try JSONDecoder().decode(CatalogApp.self, from: Data(single.utf8))
        check(false, "CatalogApp сам отвергает плохой id")
    } catch {
        check((error as? SatelliteCatalogError) == .invalidID("a/b"), "CatalogApp сам отвергает плохой id (\(error))")
    }

    func available(minHub: String, hub: String) -> Bool {
        let catalog = try! SatelliteCatalog.decode(json(minHub: minHub))
        return !SatelliteCatalog.available(catalog, hubVersion: hub).isEmpty
    }
    check(!available(minHub: "9.0.0", hub: "0.6.0"), "minHub 9.0.0 — нет в выдаче")
    check(available(minHub: "0.6.0", hub: "0.6.0"), "minHub равен версии центра — в выдаче")
    check(available(minHub: "0.9.0", hub: "0.10.0"), "центр 0.10.0 новее minHub 0.9.0")
    check(!available(minHub: "0.10.0", hub: "0.9.0"), "центр 0.9.0 старше minHub 0.10.0")

    check(Kit.isNewer("0.10.0", than: "0.9.0"), "0.10.0 новее 0.9.0")
    check(!Kit.isNewer("0.9.0", than: "0.10.0"), "0.9.0 не новее 0.10.0")
    check(!Kit.isNewer("1.0", than: "1.0.0"), "1.0 и 1.0.0 — одна версия")
}

// MARK: - Плист агента

func agentChecks() {
    let exe = URL(fileURLWithPath: "/somewhere/Fixture.app/Contents/MacOS/Fixture")
    let data = SatelliteAgent.plist(id: "awake", executable: exe)
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return check(false, "плист не парсится")
    }
    check(Set(plist.keys) == ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "MachServices"], "плист: ровно нужные ключи (\(plist.keys.sorted()))")
    check(plist["Label"] as? String == "local.utilitumus.app.awake", "плист: Label")
    check(plist["ProgramArguments"] as? [String] == [exe.path], "плист: ProgramArguments")
    check(plist["RunAtLoad"] as? Bool == true, "плист: RunAtLoad")
    check(plist["KeepAlive"] as? Bool == false, "плист: KeepAlive")
    check(plist["MachServices"] as? [String: Bool] == ["local.utilitumus.app.awake.xpc": true], "плист: MachServices")
}

// MARK: - Стенд установщика

/// Своя папка на каждый сценарий; подставные launchctl, download и связь пишут в общий журнал,
/// рядом с вызовом — версия бандла на тот момент: так виден порядок вызовов и замены.
final class Stand {
    let root: URL
    let paths: SatellitePaths
    var events: [String] = []
    var downloaded: [URL] = []
    var verifyCalls = 0
    var failBootstraps = 0
    var failBootstrapsOfVersion: [String: Int] = [:]
    var onBootstrap: (() -> Void)?
    var onHello: (() -> Void)?
    var failBootouts = false
    var failDownload = false
    var failHellos = 0
    var helloWindow: TimeInterval = 5

    init(_ name: String) {
        root = workRoot.appendingPathComponent(name)
        paths = SatellitePaths(appsDir: root.appendingPathComponent("apps"), agentsDir: root.appendingPathComponent("agents"))
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var bundle: URL { paths.appsDir.appendingPathComponent(appName + ".app") }
    var agent: URL { paths.agentsDir.appendingPathComponent(identifier + ".plist") }
    var calls: [String] { events.map { String($0.prefix { $0 != "@" }) } }

    var version: String {
        (NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "нет"
    }
    func log(_ name: String) { events.append("\(name)@\(version)") }

    lazy var installer = SatelliteInstaller(
        paths: paths,
        launchctl: { [unowned self] args in
            switch args.first {
            case "bootstrap":
                self.log("bootstrap")
                let domain = "gui/\(getuid())"
                check(args == ["bootstrap", domain, self.agent.path], "bootstrap: домен и путь к плисту")
                self.onBootstrap?()
                if self.failBootstraps > 0 {
                    self.failBootstraps -= 1
                    throw KitSigning.Failure("launchctl: bootstrap")
                }
                if let left = self.failBootstrapsOfVersion[self.version], left > 0 {
                    self.failBootstrapsOfVersion[self.version] = left - 1
                    throw KitSigning.Failure("launchctl: bootstrap")
                }
            case "bootout":
                self.log("bootout")
                check(args == ["bootout", "gui/\(getuid())/\(identifier)"], "bootout: домен и метка")
                if self.failBootouts { throw KitSigning.Failure("launchctl: bootout") }
            default:
                check(false, "неожиданный launchctl \(args)")
            }
        },
        download: { [unowned self] url in
            if self.failDownload { throw KitSigning.Failure("нет сети") }
            let copy = self.root.deletingLastPathComponent().appendingPathComponent("download-\(UUID().uuidString).zip")
            try fm.copyItem(at: url, to: copy)
            self.downloaded.append(copy)
            return copy
        },
        verify: { [unowned self] app, wanted in
            self.verifyCalls += 1
            check(wanted == identifier, "verify: identifier \(wanted)")
            try KitSigning.verifySignature(of: app, identifier: wanted, strict: true)
        },
        link: SatelliteLink(
            quit: { [unowned self] id in
                check(id == appID, "quit: id")
                self.log("quit")
            },
            hello: { [unowned self] id in
                check(id == appID, "hello: id")
                self.log("hello")
                self.onHello?()
                if self.failHellos > 0 {
                    self.failHellos -= 1
                    throw LinkError.timeout
                }
            },
            helloWindow: helloWindow))

    func catalogApp(_ fixture: String, sha: String? = nil, version: String? = nil) -> CatalogApp {
        let zip = fixtures.appendingPathComponent(fixture + ".zip")
        let real = SHA256.hash(data: try! Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        // Все фикстуры, кроме v1, собраны с версией 2.0.0.
        let inArchive = fixture == "v1" ? "1.0.0" : "2.0.0"
        return CatalogApp(id: appID, version: version ?? inArchive, minHub: "0.0.0", url: zip, sha256: sha ?? real, sizeMB: 1)
    }

    /// Ошибка установки; nil — прошла.
    func install(_ fixture: String, sha: String? = nil, version: String? = nil) async -> Error? {
        do {
            try await installer.install(catalogApp(fixture, sha: sha, version: version), name: appName)
            return nil
        } catch {
            return error
        }
    }

    /// appsDir не должно быть вовсе: установка, которая его создала, за собой его убирает.
    var nothingInstalled: Bool {
        let agents = (try? fm.contentsOfDirectory(atPath: paths.agentsDir.path)) ?? []
        return !fm.fileExists(atPath: paths.appsDir.path) && agents.isEmpty
    }
    /// Рядом с appsDir и agentsDir ничего постороннего, скачанный архив убран.
    var noLitter: Bool {
        let extra = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).subtracting(["apps", "agents"])
        return extra.isEmpty && downloaded.allSatisfy { !fm.fileExists(atPath: $0.path) }
    }
    var plist: [String: Any]? {
        (try? Data(contentsOf: agent)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }
    func executable(in app: URL) -> String { app.appendingPathComponent("Contents/MacOS/Fixture").path }
}

func isArchiveError(_ error: Error?) -> Bool {
    if case .archive = error as? SatelliteInstallError { return true }
    return false
}
/// Подпись бывает отвергнута и за другое (например, за ссылку в бандле), поэтому сверяется и текст codesign.
func isSignatureError(_ error: Error?, _ reason: String) -> Bool {
    guard let text = error?.localizedDescription else { return false }
    return text.hasPrefix("Подпись") && text.contains(reason)
}

// MARK: - Сценарии

func installChecks() async {
    do {
        let s = Stand("good")
        let error = await s.install("v1")
        check(error == nil, "хороший архив: установка прошла (\(error.map(String.init(describing:)) ?? "-"))")
        check(s.version == "1.0.0", "хороший архив: бандл на месте")
        check(fm.fileExists(atPath: s.agent.path), "хороший архив: плист на месте")
        check(s.plist?["ProgramArguments"] as? [String] == [s.executable(in: s.bundle)], "хороший архив: плист указывает на исполняемый файл в установленном бандле")
        check(fm.isExecutableFile(atPath: s.executable(in: s.bundle)), "хороший архив: этот файл есть и исполняемый")
        check(s.calls == ["bootout", "bootstrap"], "хороший архив: launchctl получил bootstrap, quit и hello не было (\(s.calls))")
        check(s.verifyCalls == 1, "хороший архив: подпись проверена")
        check((try? KitSigning.verifySignature(of: s.bundle, identifier: identifier, strict: true)) != nil, "хороший архив: подпись цела и после перемещения")
        check(s.noLitter, "хороший архив: ни скачанного, ни мусора")
    }

    do {
        let s = Stand("sha")
        let error = await s.install("v1", sha: String(repeating: "0", count: 64))
        check((error as? SatelliteInstallError) == .checksum, "неверный sha256: ошибка checksum (\(String(describing: error)))")
        check(s.nothingInstalled && s.events.isEmpty && s.verifyCalls == 0, "неверный sha256: ничего не тронуто")
        check(s.noLitter, "неверный sha256: ни скачанного, ни мусора")
    }

    do {
        let s = Stand("sha-case")
        let upper = s.catalogApp("v1").sha256.uppercased()
        check(await s.install("v1", sha: upper) == nil, "sha256 заглавными: принимается")
    }

    do {
        let s = Stand("download")
        s.failDownload = true
        let error = await s.install("v1")
        check(error?.localizedDescription == "нет сети", "сбой скачивания: ошибка как есть")
        check(s.nothingInstalled && s.events.isEmpty, "сбой скачивания: ничего не тронуто")
    }

    for (fixture, reason) in [("adhoc", "code requirement"), ("foreign", "code requirement"), ("tampered", "Info.plist")] {
        let s = Stand("sign-" + fixture)
        let error = await s.install(fixture)
        check(isSignatureError(error, reason), "\(fixture): отказ по подписи (\(String(describing: error)))")
        check(s.nothingInstalled && s.events.isEmpty, "\(fixture): ничего не тронуто")
        check(s.noLitter, "\(fixture): ни скачанного, ни мусора")
    }

    for fixture in ["traversal", "two", "renamed", "extra", "link-rel", "link-abs", "link-dangling", "link-top", "garbage"] {
        let s = Stand("archive-" + fixture)
        let error = await s.install(fixture)
        check(isArchiveError(error), "\(fixture): отказ по архиву (\(String(describing: error)))")
        check(s.verifyCalls == 0, "\(fixture): до подписи не дошло")
        check(s.nothingInstalled && s.events.isEmpty, "\(fixture): ничего не тронуто")
        check(s.noLitter, "\(fixture): ни скачанного, ни мусора")
    }

    for fixture in ["mode-exe", "mode-dir"] {
        let s = Stand("archive-" + fixture)
        let error = await s.install(fixture)
        check(isArchiveError(error), "\(fixture): запись для группы или всех — отказ по архиву (\(String(describing: error)))")
        check(s.verifyCalls == 0, "\(fixture): до подписи не дошло")
        check(s.nothingInstalled && s.events.isEmpty, "\(fixture): ничего не тронуто")
    }

    do {
        let s = Stand("wrong-version")
        let error = await s.install("v1", version: "9.9.9")
        check(isArchiveError(error), "версия в бандле не та, что в каталоге: отказ (\(String(describing: error)))")
        check(s.verifyCalls == 1, "версия в бандле не та: подпись при этом верна")
        check(s.nothingInstalled && s.events.isEmpty, "версия в бандле не та: ничего не тронуто")
    }

    do {
        let s = Stand("plist-id")
        let error = await s.install("plist-id")
        check(isArchiveError(error), "identifier в Info.plist чужой: отказ (\(String(describing: error)))")
        check(s.verifyCalls == 1, "identifier в Info.plist чужой: подпись при этом верна")
        check(s.nothingInstalled && s.events.isEmpty, "identifier в Info.plist чужой: ничего не тронуто")
    }

    do {
        let s = Stand("existing-apps-dir")
        try! fm.createDirectory(at: s.paths.appsDir, withIntermediateDirectories: true)
        s.failBootstraps = 1000
        check(await s.install("v1") != nil, "appsDir уже был, bootstrap не проходит: ошибка")
        check(fm.fileExists(atPath: s.paths.appsDir.path), "appsDir уже был: откат его не удалил")
        check(!fm.fileExists(atPath: s.bundle.path), "appsDir уже был: бандла нет")
    }

    do {
        let s = Stand("bootstrap-fresh")
        s.failBootstraps = 1000
        check(await s.install("v1") != nil, "первая установка, bootstrap не проходит: ошибка")
        check(s.nothingInstalled, "первая установка, bootstrap не проходит: откат, ничего не осталось")
        check(s.noLitter, "первая установка, bootstrap не проходит: мусора нет")
    }
}

func updateChecks() async {
    /// Установленная v1 с чистым журналом.
    func standWithV1(_ name: String) async -> (Stand, Data) {
        let s = Stand(name)
        check(await s.install("v1") == nil, "\(name): v1 поставилась")
        s.events = []
        s.verifyCalls = 0
        return (s, try! Data(contentsOf: s.agent))
    }

    for (fixture, sha) in [("foreign", nil), ("adhoc", nil), ("two", nil), ("v2", String(repeating: "0", count: 64))] as [(String, String?)] {
        let (s, plist) = await standWithV1("over-\(fixture)")
        check(await s.install(fixture, sha: sha) != nil, "поверх v1, \(fixture): ошибка")
        check(s.version == "1.0.0", "поверх v1, \(fixture): старая версия на месте")
        check((try? KitSigning.verifySignature(of: s.bundle, identifier: identifier, strict: true)) != nil, "поверх v1, \(fixture): её подпись цела")
        check((try? Data(contentsOf: s.agent)) == plist, "поверх v1, \(fixture): её плист не менялся")
        check(s.events.isEmpty, "поверх v1, \(fixture): её не останавливали, launchctl не вызывался (\(s.events))")
        check(s.noLitter, "поверх v1, \(fixture): мусора нет")
    }

    do {
        let (s, _) = await standWithV1("update")
        check(await s.install("v2") == nil, "обновление: прошло")
        check(s.events == ["quit@1.0.0", "bootout@2.0.0", "bootstrap@2.0.0", "hello@2.0.0"], "обновление: quit, замена, bootout, bootstrap, hello (\(s.events))")
        check(s.version == "2.0.0", "обновление: новая версия на месте")
        check((try? KitSigning.verifySignature(of: s.bundle, identifier: identifier, strict: true)) != nil, "обновление: подпись цела после замены")
        check(s.noLitter, "обновление: мусора нет")
        check((try? fm.contentsOfDirectory(atPath: s.paths.appsDir.path)) == [appName + ".app"], "обновление: в appsDir только бандл")
    }

    do {
        let (s, _) = await standWithV1("update-not-loaded")
        s.failBootouts = true
        check(await s.install("v2") == nil, "обновление: агент не был загружен, bootout падает — не помеха")
        check(s.calls.contains("bootstrap"), "обновление без загруженного агента: bootstrap был")
    }

    do {
        let (s, _) = await standWithV1("update-bootstrap-retry")
        s.failBootstraps = 3
        check(await s.install("v2") == nil, "обновление: launchd не сразу отпустил метку, bootstrap повторён")
        check(s.calls.filter { $0 == "bootstrap" }.count == 4 && s.version == "2.0.0", "обновление: три отказа и успех (\(s.calls))")
    }

    do {
        let (s, plist) = await standWithV1("update-bootstrap-fail")
        s.failBootstraps = 10  // столько, чтобы отказать новой версии; откат проходит
        check(await s.install("v2") != nil, "обновление, bootstrap не проходит: ошибка")
        check(s.version == "1.0.0", "обновление, bootstrap не проходит: старая версия возвращена")
        check((try? Data(contentsOf: s.agent)) == plist, "обновление, bootstrap не проходит: старый плист возвращён")
        check(s.events.last == "bootstrap@1.0.0", "обновление, bootstrap не проходит: старая версия снова запущена (\(s.events))")
        check((try? KitSigning.verifySignature(of: s.bundle, identifier: identifier, strict: true)) != nil, "обновление, bootstrap не проходит: подпись старой цела")
        check(s.noLitter, "обновление, bootstrap не проходит: мусора нет")
    }

    do {
        let (s, _) = await standWithV1("update-hello-retry")
        s.failHellos = 2
        check(await s.install("v2") == nil, "обновление: hello с повторами")
        check(s.calls.filter { $0 == "hello" }.count == 3, "обновление: два отказа hello и успех (\(s.calls))")
    }

    do {
        let s = Stand("update-hello-fail")
        s.helloWindow = 0.2
        check(await s.install("v1") == nil, "update-hello-fail: v1 поставилась")
        let plist = try! Data(contentsOf: s.agent)
        s.events = []
        s.failHellos = 1000
        let started = Date()
        check((await s.install("v2") as? LinkError) == .timeout, "обновление, hello молчит: ошибка hello")
        check(Date().timeIntervalSince(started) < 5, "обновление, hello молчит: ждём только окно helloWindow")
        check(s.version == "1.0.0", "обновление, hello молчит: старая версия возвращена")
        check((try? Data(contentsOf: s.agent)) == plist, "обновление, hello молчит: старый плист возвращён")
        check(s.events.last == "bootstrap@1.0.0", "обновление, hello молчит: старая версия снова запущена (\(s.events))")
    }
}

func rollbackChecks() async {
    func standWithV1(_ name: String) async -> (Stand, Data) {
        let s = Stand(name)
        check(await s.install("v1") == nil, "\(name): v1 поставилась")
        s.events = []
        return (s, try! Data(contentsOf: s.agent))
    }
    func setMode(_ dir: URL, _ mode: Int) {
        try! fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dir.path)
    }

    // Запись запрещена: новая версия не встала, значит возвращать на место нечего и незачем.
    do {
        let (s, plist) = await standWithV1("readonly-agents")
        setMode(s.paths.agentsDir, 0o555)
        let error = await s.install("v2")
        setMode(s.paths.agentsDir, 0o755)
        check(error != nil, "agentsDir только для чтения: ошибка")
        if case .rollbackFailed = error as? SatelliteInstallError { check(false, "agentsDir только для чтения: откат не должен считаться сбоем (\(String(describing: error)))") }
        check(s.version == "1.0.0", "agentsDir только для чтения: версия 1.0.0 (\(s.version))")
        check((try? Data(contentsOf: s.agent)) == plist, "agentsDir только для чтения: старый плист цел")
        check(s.events.last == "bootstrap@1.0.0", "agentsDir только для чтения: старая версия снова запущена (\(s.events))")
    }
    do {
        let (s, plist) = await standWithV1("readonly-apps")
        setMode(s.paths.appsDir, 0o555)
        let error = await s.install("v2")
        setMode(s.paths.appsDir, 0o755)
        check(error != nil, "appsDir только для чтения: ошибка")
        if case .rollbackFailed = error as? SatelliteInstallError { check(false, "appsDir только для чтения: откат не должен считаться сбоем (\(String(describing: error)))") }
        check(s.version == "1.0.0", "appsDir только для чтения: версия 1.0.0 (\(s.version))")
        check((try? Data(contentsOf: s.agent)) == plist, "appsDir только для чтения: старый плист цел")
        check(s.events.last == "bootstrap@1.0.0", "appsDir только для чтения: старая версия снова запущена (\(s.events))")
    }

    // Цель исчезла: replaceItemAt как есть и restore с запасным moveItem.
    do {
        let dir = workRoot.appendingPathComponent("restore-missing")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let make = { (name: String) -> URL in
            let url = dir.appendingPathComponent(name)
            try! fm.createDirectory(at: url, withIntermediateDirectories: true)
            try! Data("старая".utf8).write(to: url.appendingPathComponent("file"))
            return url
        }
        let raw = make("raw-backup")
        let rawTarget = dir.appendingPathComponent("raw-target")
        let rawResult = Result { try fm.replaceItemAt(rawTarget, withItemAt: raw) }
        print("     replaceItemAt на отсутствующую цель: \(rawResult), цель есть: \(fm.fileExists(atPath: rawTarget.path))")

        let backup = make("backup")
        let target = dir.appendingPathComponent("target")
        check((try? SatelliteInstaller.restore(backup, to: target)) != nil, "restore: цели нет — не ошибка")
        check((try? Data(contentsOf: target.appendingPathComponent("file"))) == Data("старая".utf8), "restore: цели нет — резервная копия встала на место")

        let replacement = make("replacement")
        try! Data("новая".utf8).write(to: replacement.appendingPathComponent("file"))
        check((try? SatelliteInstaller.restore(replacement, to: target)) != nil, "restore: цель есть — заменена")
        check((try? Data(contentsOf: target.appendingPathComponent("file"))) == Data("новая".utf8), "restore: цель есть — содержимое новое")
    }

    do {
        let s = Stand("bundle-vanished")
        s.helloWindow = 0.2
        check(await s.install("v1") == nil, "bundle-vanished: v1 поставилась")
        let plist = try! Data(contentsOf: s.agent)
        s.failHellos = 1000
        s.onHello = { [unowned s] in try? fm.removeItem(at: s.bundle) }
        let error = await s.install("v2")
        check(error != nil, "бандл исчез во время обновления: ошибка")
        check(s.version == "1.0.0", "бандл исчез во время обновления: старая версия возвращена (\(s.version))")
        check((try? Data(contentsOf: s.agent)) == plist, "бандл исчез во время обновления: старый плист цел")
    }

    // Сам откат не удался: это должно быть видно отдельной ошибкой.
    do {
        let (s, _) = await standWithV1("rollback-bundle-fails")
        s.failBootstraps = 10
        var locked = false
        s.onBootstrap = { [unowned s] in
            if !locked {
                locked = true
                setMode(s.paths.appsDir, 0o555)
            }
        }
        let error = await s.install("v2")
        setMode(s.paths.appsDir, 0o755)
        if case .rollbackFailed(let cause, let problems) = error as? SatelliteInstallError {
            check(cause == "launchctl: bootstrap" && problems.count == 1, "откат бандла не удался: причина и сбой отката (\(cause), \(problems))")
        } else {
            check(false, "откат бандла не удался: отдельная ошибка (\(String(describing: error)))")
        }
    }
    do {
        let (s, _) = await standWithV1("rollback-bootstrap-fails")
        s.failBootstraps = 1000
        let error = await s.install("v2")
        if case .rollbackFailed(_, let problems) = error as? SatelliteInstallError {
            check(problems == ["launchctl: bootstrap"], "bootstrap старой версии не прошёл: отдельная ошибка (\(problems))")
        } else {
            check(false, "bootstrap старой версии не прошёл: отдельная ошибка (\(String(describing: error)))")
        }
        check(s.version == "1.0.0", "bootstrap старой версии не прошёл: бандл всё же возвращён")
    }

    // Отмена: откат всё равно должен получить все попытки bootstrap.
    do {
        let (s, _) = await standWithV1("update-cancel-rollback")
        s.failHellos = 1000
        s.failBootstrapsOfVersion = ["1.0.0": 1]
        s.onHello = { withUnsafeCurrentTask { $0?.cancel() } }
        let error = await Task { await s.install("v2") }.value
        check(error is CancellationError, "обновление отменено: ошибка отмены (\(String(describing: error)))")
        check(s.events.filter { $0 == "bootstrap@1.0.0" }.count == 2, "обновление отменено: первый bootstrap отката не прошёл, второй был (\(s.events))")
        check(s.version == "1.0.0", "обновление отменено: старая версия возвращена")
    }
}

func entryPointChecks() async {
    let badIDs = [#"x" or identifier "y"#, "../x", "a/b", "Awake", ""]
    for (index, bad) in badIDs.enumerated() {
        let s = Stand("bad-id-\(index)")
        let app = CatalogApp(id: bad, version: "1.0.0", minHub: "0.0.0", url: fixtures.appendingPathComponent("v1.zip"), sha256: "ab", sizeMB: 1)
        do {
            try await s.installer.install(app, name: appName)
            check(false, "install: id «\(bad)» отвергается")
        } catch {
            check((error as? SatelliteCatalogError) == .invalidID(bad), "install: id «\(bad)» отвергается (\(error))")
        }
        do {
            try await s.installer.remove(id: bad, name: appName)
            check(false, "remove: id «\(bad)» отвергается")
        } catch {
            check((error as? SatelliteCatalogError) == .invalidID(bad), "remove: id «\(bad)» отвергается (\(error))")
        }
        do {
            try s.installer.removeStaleAgent(id: bad)
            check(false, "removeStaleAgent: id «\(bad)» отвергается")
        } catch {
            check((error as? SatelliteCatalogError) == .invalidID(bad), "removeStaleAgent: id «\(bad)» отвергается (\(error))")
        }
        check(s.events.isEmpty && s.downloaded.isEmpty && s.verifyCalls == 0, "id «\(bad)»: ни скачивания, ни launchctl, ни связи (\(s.events))")
    }

    for (index, bad) in ["../Victim", "", "a/b", ".hidden", "..", "/abs"].enumerated() {
        let s = Stand("bad-name-\(index)")
        let victim = s.root.appendingPathComponent("Victim.app")
        try! fm.createDirectory(at: victim, withIntermediateDirectories: true)
        do {
            try await s.installer.remove(id: appID, name: bad)
            check(false, "remove: имя «\(bad)» отвергается")
        } catch {
            check((error as? SatelliteInstallError) == .invalidName(bad), "remove: имя «\(bad)» отвергается (\(error))")
        }
        do {
            try await s.installer.install(s.catalogApp("v1"), name: bad)
            check(false, "install: имя «\(bad)» отвергается")
        } catch {
            check((error as? SatelliteInstallError) == .invalidName(bad), "install: имя «\(bad)» отвергается (\(error))")
        }
        check(fm.fileExists(atPath: victim.path), "имя «\(bad)»: папка рядом с appsDir цела")
        check(s.events.isEmpty && s.downloaded.isEmpty, "имя «\(bad)»: ни скачивания, ни launchctl, ни связи (\(s.events))")
    }
}

/// KitSigning.run: процесс пишет в stderr больше, чем вмещает канал. Срок — чтобы зависание было провалом, а не вечным тестом.
func chattyProcessCheck() {
    final class Box: @unchecked Sendable { var message: String? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        do {
            try KitSigning.run("/bin/sh", ["-c", "yes x | head -c 200000 >&2; exit 3"])
        } catch {
            box.message = error.localizedDescription
        }
        done.signal()
    }
    let finished = done.wait(timeout: .now() + 10) == .success
    check(finished, "KitSigning.run: 200 КБ в stderr не вешают")
    if finished {
        check(box.message?.contains("x\nx") == true, "KitSigning.run: код выхода не 0 — ошибка с текстом stderr")
    }
}

func removeChecks() async {
    do {
        let s = Stand("remove")
        check(await s.install("v1") == nil, "remove: v1 поставилась")
        let neighbour = s.paths.appsDir.appendingPathComponent("Other.app")
        try! fm.createDirectory(at: neighbour, withIntermediateDirectories: true)
        s.events = []
        do {
            try await s.installer.remove(id: appID, name: appName)
            check(true, "remove: прошло")
        } catch {
            check(false, "remove: \(error)")
        }
        check(!fm.fileExists(atPath: s.bundle.path), "remove: бандла нет")
        check(!fm.fileExists(atPath: s.agent.path), "remove: плиста нет")
        check(s.calls == ["quit", "bootout"], "remove: quit, затем bootout (\(s.calls))")
        check(s.events.last == "bootout@1.0.0", "remove: бандл удалён после bootout (\(s.events))")
        check(fm.fileExists(atPath: neighbour.path), "remove: соседний бандл на месте")
    }

    do {
        let s = Stand("remove-nothing")
        s.failBootouts = true
        do {
            try await s.installer.remove(id: appID, name: appName)
            check(true, "remove: ничего не установлено — не ошибка")
        } catch {
            check(false, "remove: ничего не установлено — \(error)")
        }
    }

    do {
        let s = Stand("stale")
        check(await s.install("v1") == nil, "stale: v1 поставилась")
        try! fm.removeItem(at: s.bundle)
        s.events = []
        check((try? s.installer.removeStaleAgent(id: appID)) != nil, "removeStaleAgent: прошло")
        check(!fm.fileExists(atPath: s.agent.path), "removeStaleAgent: плиста нет")
        check(s.calls == ["bootout"], "removeStaleAgent: только bootout (\(s.calls))")
        check((try? s.installer.removeStaleAgent(id: appID)) != nil, "removeStaleAgent повторно: не ошибка")
    }

    do {
        let s = Stand("stale-reinstall")
        check(await s.install("v1") == nil, "stale-reinstall: v1 поставилась")
        try! fm.removeItem(at: s.bundle)
        s.events = []
        check(await s.install("v2") == nil, "бандл удалён вручную, плист остался: установка прошла")
        check(s.calls == ["quit", "bootout", "bootstrap", "hello"], "бандл удалён вручную: агент снят перед bootstrap (\(s.calls))")
    }
}

// MARK: - Вход

try! fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
catalogChecks()
agentChecks()
await installChecks()
await updateChecks()
await rollbackChecks()
await entryPointChecks()
chattyProcessCheck()
await removeChecks()
print(failures == 0 ? "КАТАЛОГ И УСТАНОВЩИК: ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
