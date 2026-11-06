import CryptoKit
import Foundation

// Личность вложенных помощников в установщике центра и в обновлении самой утилиты.
// Запуск: Tests/run-helper-identity-check.sh. В стенде внешняя подпись всех сборок настоящая:
// каждый отказ сперва показывает, что одной её проверки хватило бы для пропуска.

let arguments = CommandLine.arguments
nonisolated(unsafe) let fm = FileManager.default

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func zipURL(_ fixtures: URL, _ name: String) -> URL { fixtures.appendingPathComponent(name + ".zip") }

func catalogApp(_ zip: URL, id: String, version: String) -> CatalogApp {
    let sha = SHA256.hash(data: try! Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
    return CatalogApp(id: id, version: version, minHub: "0.0.0", url: zip, sha256: sha, sizeMB: 1)
}

func errorText(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch {
        return error.localizedDescription
    }
}

struct Target {
    let id: String
    let name: String
    let helperName: String
    /// Что сломано и какие слова ждём в отказе.
    let bad: [(mode: String, expected: String)]
}

let helperCases: [Target] = [
    Target(id: "fans", name: "Fans", helperName: "utilitumus-fan", bad: [
        ("adhoc", "Подпись utilitumus-fan"), ("wrong-id", "Подпись utilitumus-fan"), ("no-runtime", "hardened runtime"),
        ("link", "нет помощника"), ("missing", "нет помощника"), ("no-epoch", "метки выпуска"),
    ]),
    Target(id: "voice", name: "Voice", helperName: "utilitumus-voice", bad: [
        ("adhoc", "Подпись utilitumus-voice"), ("wrong-id", "Подпись utilitumus-voice"), ("no-runtime", "hardened runtime"),
        ("link", "нет помощника"), ("missing", "нет помощника"),
    ]),
    Target(id: "browser", name: "Browser", helperName: "Utilitumus Links.app", bad: [
        ("adhoc", "Подпись Utilitumus Links.app"), ("wrong-id", "Подпись Utilitumus Links.app"), ("no-runtime", "hardened runtime"),
        ("no-epoch", "метки выпуска"), ("missing", "нет помощника"),
    ]),
]

/// Для установленной версии: своя метка внутри бандла и плист агента, launchctl и связь записывают вызовы.
final class Stand {
    let target: Target
    let paths: SatellitePaths
    var launchctlCalls: [[String]] = []
    var quits = 0

    init(_ target: Target, work: URL, tag: String) {
        self.target = target
        let root = work.appendingPathComponent("\(tag)-\(target.id)")
        paths = SatellitePaths(appsDir: root.appendingPathComponent("apps"), agentsDir: root.appendingPathComponent("agents"))
    }

    var bundle: URL { paths.appsDir.appendingPathComponent(target.name + ".app") }
    var agent: URL { paths.agentsDir.appendingPathComponent(KitLink.bundleID(target.id) + ".plist") }
    var marker: URL { bundle.appendingPathComponent("Contents/marker") }
    var version: String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    lazy var installer = SatelliteInstaller(
        paths: paths,
        launchctl: { [unowned self] in self.launchctlCalls.append($0) },
        download: { url in
            let copy = fm.temporaryDirectory.appendingPathComponent("helper-check-\(UUID().uuidString).zip")
            try fm.copyItem(at: url, to: copy)
            return copy
        },
        verify: SatelliteInstaller.liveVerify,
        link: SatelliteLink(quit: { [unowned self] _, _ in self.quits += 1 }, hello: { _ in }, helloWindow: 1))

    func install(_ zip: URL, version: String) async -> String? {
        await errorText { try await self.installer.install(catalogApp(zip, id: self.target.id, version: version), name: self.target.name) }
    }
}

func tableChecks() {
    check(KitSigning.helpers["local.utilitumus.app.fans"] == [KitHelper(path: "Contents/MacOS/utilitumus-fan", identifier: "local.utilitumus.fan")], "таблица: Вентиляторы")
    check(KitSigning.helpers["local.utilitumus.app.voice"] == [KitHelper(path: "Contents/MacOS/utilitumus-voice", identifier: "local.utilitumus.voice")], "таблица: Голос")
    check(KitSigning.helpers["local.utilitumus.app.browser"] == [KitHelper(path: "Contents/Helpers/Utilitumus Links.app", identifier: "local.utilitumus.links")], "таблица: Браузер")
    check(KitSigning.helpers["local.utilitumus.app.awake"] == nil, "таблица: у Не спать помощников нет")
}

func verifyAll(fixtures: URL, work: URL) async {
    tableChecks()
    for target in helperCases {
        let identifier = KitLink.bundleID(target.id)

        // Установщик центра: проверка настоящая, остальное подставное.
        let hub = Stand(target, work: work, tag: "hub")
        let first = await hub.install(zipURL(fixtures, "\(target.id)-v1"), version: "1.0.0")
        check(first == nil && hub.version == "1.0.0", "\(target.id): 1.0.0 с настоящим помощником ставится (\(first ?? "-"))")
        try! "установленная".write(to: hub.marker, atomically: true, encoding: .utf8)
        let agentBefore = try? Data(contentsOf: hub.agent)

        // Самообновление: цель — копия поставленной версии.
        let selfUpdate = Stand(target, work: work, tag: "self")
        try! fm.createDirectory(at: selfUpdate.paths.appsDir, withIntermediateDirectories: true)
        try! fm.copyItem(at: hub.bundle, to: selfUpdate.bundle)

        for (mode, expected) in target.bad {
            let name = "\(target.id) \(mode)"
            // Распаковать нельзя без установщика: внешнюю подпись смотрим на отдельной копии.
            let unpacked = work.appendingPathComponent("unpacked-\(target.id)-\(mode)")
            try! KitSigning.run("/usr/bin/ditto", ["-x", "-k", zipURL(fixtures, "\(target.id)-\(mode)").path, unpacked.path])
            let app = unpacked.appendingPathComponent(target.name + ".app")
            let outer = await errorText { try KitSigning.verifySignature(of: app, identifier: identifier, strict: true) }
            check(outer == nil, "\(name): внешней подписи мало, она проходит (\(outer ?? "-"))")

            hub.launchctlCalls = []
            hub.quits = 0
            let refused = await hub.install(zipURL(fixtures, "\(target.id)-\(mode)"), version: "2.0.0")
            check(refused?.contains(expected) == true, "\(name): установщик отказал: \(refused ?? "прошло")")
            check(hub.version == "1.0.0" && fm.fileExists(atPath: hub.marker.path), "\(name): установленная 1.0.0 не тронута")
            check((try? Data(contentsOf: hub.agent)) == agentBefore && hub.launchctlCalls.isEmpty && hub.quits == 0, "\(name): агент цел, launchctl и quit не вызваны")

            let app2 = catalogApp(zipURL(fixtures, "\(target.id)-\(mode)"), id: target.id, version: "2.0.0")
            let selfRefused = await errorText { try await SatelliteSelfUpdate.install(app2, target: selfUpdate.bundle) }
            check(selfRefused?.contains(expected) == true, "\(name): самообновление отказало: \(selfRefused ?? "прошло")")
            check(selfUpdate.version == "1.0.0" && fm.fileExists(atPath: selfUpdate.marker.path), "\(name): самообновление: 1.0.0 не тронута")
            check((try? fm.contentsOfDirectory(atPath: selfUpdate.paths.appsDir.path)) == [target.name + ".app"], "\(name): самообновление: рядом ничего")
        }

        let good = await hub.install(zipURL(fixtures, "\(target.id)-good"), version: "2.0.0")
        check(good == nil && hub.version == "2.0.0", "\(target.id): хорошая 2.0.0 ставится установщиком (\(good ?? "-"))")
        let goodApp = catalogApp(zipURL(fixtures, "\(target.id)-good"), id: target.id, version: "2.0.0")
        let selfGood = await errorText { try await SatelliteSelfUpdate.install(goodApp, target: selfUpdate.bundle) }
        check(selfGood == nil && selfUpdate.version == "2.0.0", "\(target.id): хорошая 2.0.0 ставится самообновлением (\(selfGood ?? "-"))")
    }
}

switch arguments.dropFirst().first {
case "verify":
    await verifyAll(fixtures: URL(fileURLWithPath: arguments[2]), work: URL(fileURLWithPath: arguments[3]))
    print(failures == 0 ? "проверка в Swift: ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
case "table":
    let prefix = "local.utilitumus.app."
    for (identifier, helpers) in KitSigning.helpers.sorted(by: { $0.key < $1.key }) {
        for helper in helpers { print(identifier.dropFirst(prefix.count), helper.path + "|" + helper.identifier) }
    }
case "epoch":
    print(KitSigning.securityEpoch)
default:
    print("verify <фикстуры> <стенд> | table | epoch")
    exit(64)
}
