import Combine
import Foundation

// Центр для сквозной проверки: настоящие реестр и установщик, настоящие launchctl, связь и codesign.
// Запуск: Tests/run-hub-e2e.sh. Подпись как у центра, каждый запуск — отдельный процесс центра.
// Аргументы: <папка стенда> <команда> [каталог]. Настройки — suite стенда (`-D KIT_TEST_DEFAULTS`).

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let command = CommandLine.arguments[2]
let catalogFile = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
let appID = "awake"
let label = KitLink.bundleID(appID)
// Агент тоже в папке стенда: упавший тест не оставит плист, который запустится при входе.
let paths = SatellitePaths(appsDir: root.appendingPathComponent("Apps"), agentsDir: root.appendingPathComponent("Agents"))

// Реестр и подписка команды hold живут, пока центр не снимут.
nonisolated(unsafe) var holding: [Any] = []

struct Refused: LocalizedError {
    let errorDescription: String?
}

@MainActor func requestStatus(_ id: String) async throws -> LinkStatus { try await LinkClient(id: id).status() }
@MainActor func requestEnabled(_ id: String, _ on: Bool) async throws { try await LinkClient(id: id).setEnabled(on) }
@MainActor func requestWindow(_ id: String) async throws { try await LinkClient(id: id).openWindow() }
@MainActor func requestQuit(_ id: String, _ reason: LinkQuitReason) async { try? await LinkClient(id: id).quit(reason) }
@MainActor func requestHello(_ id: String) async throws -> LinkHello { try await LinkClient(id: id).hello() }

let installer = SatelliteInstaller(
    paths: paths,
    // Метка настоящая, поэтому launchctl получает только её.
    launchctl: { args in
        guard args.contains(where: { $0.contains(label) }) else { throw Refused(errorDescription: "чужая метка: \(args)") }
        try KitSigning.run("/bin/launchctl", args)
    },
    // Каталог указывает на file://. Скачанное убирает установщик, поэтому копия.
    download: { url in
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    },
    verify: { try KitSigning.verifySignature(of: $0, identifier: $1, strict: true) },
    link: SatelliteLink(
        quit: { await requestQuit($0, $1) },
        hello: { _ = try await requestHello($0) }))

func stateLine(_ entry: SatelliteRegistry.Entry?) -> String {
    [entry?.installedVersion ?? "нет", String(entry?.responding ?? false),
     String(entry?.status?.enabled ?? false), entry?.status?.line ?? "нет"].joined(separator: "|")
}

@MainActor func run() async throws {
    let defaults = Kit.defaults
    // Без флага ModuleOn выглядел бы обновлением со старой версии, и одноразовый сброс выключил бы модули.
    defaults.set(true, forKey: ModuleReset.flagKey)
    let modules = ModuleManager(defaults: defaults)
    let registry = SatelliteRegistry(SatelliteEnvironment(
        paths: paths,
        defaults: defaults,
        installer: installer,
        commands: SatelliteCommands(
            status: { try await requestStatus($0) },
            setEnabled: { try await requestEnabled($0, $1) },
            openWindow: { try await requestWindow($0) }),
        loadCatalog: {
            guard let catalogFile else { return Data(#"{"schema":1,"apps":[]}"#.utf8) }
            return try Data(contentsOf: catalogFile)
        },
        hubVersion: "0.6.0",
        modules: modules))

    switch command {
    case "install":
        await registry.update()
        guard let app = registry.catalogApp(.awake) else { throw Refused(errorDescription: "нет в каталоге") }
        try await registry.install(.awake, app: app)
        print(stateLine(registry.entries[.awake]))
    case "uninstall":
        try await registry.uninstall(.awake)
    case "state":
        await registry.update()
        print(stateLine(registry.entries[.awake]))
    case "hello":
        let hello = try await requestHello(appID)
        print("\(hello.id) \(hello.version) \(hello.protocolVersion)")
    case "enable":
        try await requestEnabled(appID, true)
    case "disable":
        try await requestEnabled(appID, false)
    case "open":
        try await requestWindow(appID)
    case "model-toggle":
        // Как кнопка на вкладке: модель центра, команда у утилиты.
        let model = RemoteAwakeModel(id: appID, canRead: { true })
        await model.read()
        let before = model.isActive
        model.toggle()
        for _ in 0..<60 where model.isActive == before {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print(model.isActive)
    case "hold":
        // Живой центр: пишет каждое изменение, пока его не снимут.
        registry.start()
        await registry.update()
        var seen = ""
        let subscription = registry.$entries.receive(on: DispatchQueue.main).sink { entries in
            let line = stateLine(entries[.awake])
            if line != seen {
                seen = line
                print(line)
                fflush(stdout)
            }
        }
        holding = [subscription, registry]
        return
    default:
        throw Refused(errorDescription: "неизвестная команда \(command)")
    }
    exit(0)
}

Task { @MainActor in
    do {
        try await run()
    } catch {
        print("ОШИБКА: \(error.localizedDescription)")
        exit(1)
    }
}
RunLoop.main.run()
