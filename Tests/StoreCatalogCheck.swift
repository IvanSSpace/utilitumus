import AppKit
import SwiftUI

// Стор и каталог на стенде за экраном. Запуск: Tests/run-store-catalog-check.sh
// Аргументы: рабочая папка, архив утилиты, его sha256, папка для PNG.

let workRoot = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureZip = URL(fileURLWithPath: CommandLine.arguments[2])
let fixtureSHA = CommandLine.arguments[3]
let pngDir = URL(fileURLWithPath: CommandLine.arguments[4])
nonisolated(unsafe) let fm = FileManager.default

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

struct Boom: Error {}

final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    func count(_ item: String) -> Int { lock.lock(); defer { lock.unlock() }; return items.filter { $0 == item }.count }
    func clear() { lock.lock(); items = []; lock.unlock() }
}

/// Что сейчас отвечают подставные каталог, загрузка и связь.
final class Stage: @unchecked Sendable {
    enum CatalogMode { case down, hang, empty, app(version: String) }
    enum VerifyMode { case ok, foreign }
    private let lock = NSLock()
    private var _catalog = CatalogMode.down
    private var _downloadFails = true
    private var _reply: LinkStatus?
    private var _verify = VerifyMode.ok
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var catalog: CatalogMode { get { locked { _catalog } } set { locked { _catalog = newValue } } }
    var downloadFails: Bool { get { locked { _downloadFails } } set { locked { _downloadFails = newValue } } }
    var reply: LinkStatus? { get { locked { _reply } } set { locked { _reply = newValue } } }
    var verify: VerifyMode { get { locked { _verify } } set { locked { _verify = newValue } } }
}

let journal = Journal()
let stage = Stage()
let paths = SatellitePaths(appsDir: workRoot.appendingPathComponent("Apps"),
                           agentsDir: workRoot.appendingPathComponent("Agents"))
let bundleURL = paths.appsDir.appendingPathComponent("Awake.app")

func catalogData(version: String) -> Data {
    let app: [String: Any] = ["id": "awake", "version": version, "minHub": "0.6.0",
                              "url": "https://example.com/Awake.zip", "sha256": fixtureSHA, "sizeMB": 2]
    return try! JSONSerialization.data(withJSONObject: ["schema": 1, "apps": [app]])
}

@MainActor func makeEnvironment() -> SatelliteEnvironment {
    let installer = SatelliteInstaller(
        paths: paths,
        launchctl: { journal.add("launchctl \($0[0])") },
        download: { _ in
            journal.add("download")
            if stage.downloadFails { throw URLError(.notConnectedToInternet) }
            let copy = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            try fm.copyItem(at: fixtureZip, to: copy)
            return copy
        },
        verify: { _, _ in
            journal.add("verify")
            // Настоящий текст отказа: codesign с требованием, которому неподписанный архив не отвечает.
            if stage.verify == .foreign {
                try KitSigning.verifySignature(of: fixtureZip, identifier: "local.utilitumus.test.nobody", strict: false)
            }
        },
        link: SatelliteLink(quit: { _, _ in journal.add("quit") }, hello: { _ in }))
    return SatelliteEnvironment(
        paths: paths,
        defaults: Kit.defaults,
        installer: installer,
        commands: SatelliteCommands(
            status: { _ in
                journal.add("status")
                guard let reply = stage.reply else { throw LinkError.timeout }
                return reply
            },
            setEnabled: { _, on in journal.add("setEnabled \(on)") },
            openWindow: { _ in journal.add("openWindow") }),
        loadCatalog: {
            switch stage.catalog {
            case .down: throw URLError(.notConnectedToInternet)
            case .hang:
                try await Task.sleep(for: .seconds(60))
                throw URLError(.timedOut)
            case .empty: return Data(#"{"schema":1,"apps":[]}"#.utf8)
            case .app(let version): return catalogData(version: version)
            }
        },
        hubVersion: "0.6.0",
        modules: ModuleManager.shared)
}

// MARK: - Снимки

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// Окно только за экраном: x: -10000, без активации, сразу убирается.
@MainActor func snapshot<V: View>(_ name: String, width: CGFloat = 980, height: CGFloat = 680, _ view: V) async {
    let root = ZStack {
        DSBackground(module: .awake, neutral: true)
        view
    }
    .environment(\.moduleControls, DSModuleControls.forEnvironment)
    .dsThemed()
    .frame(width: width, height: height)
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    await pause(0.4)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: pngDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    window.contentView = nil
    print("png  \(name)")
}

/// Стор рядом с боковой панелью: на снимке видна и сама панель.
struct StoreWithSidebar: View {
    @State private var dashboard = false
    @State private var store = true
    @State private var about = false
    @State private var peeked: Module?
    @State private var selection = Module.awake

    var body: some View {
        HStack(spacing: 0) {
            DSSidebar(current: nil, showDashboard: $dashboard, showStore: $store, showAbout: $about,
                      peeked: $peeked, selection: $selection)
                .frame(width: DS.sidebarWidth)
            StoreView()
        }
    }
}

@MainActor func waitIdle(_ store: StoreModel) async {
    for _ in 0..<200 {
        if case .installing = store.state(.awake) {
            await pause(0.02)
        } else {
            return
        }
    }
    check(false, "установка не закончилась за 4 с")
}

func hasCyrillic(_ text: String) -> Bool { text.range(of: "[а-яА-Я]", options: .regularExpression) != nil }

// MARK: - Сценарии

@MainActor func messageChecks() {
    let rollback = StoreModel.failureMessage(
        SatelliteInstallError.rollbackFailed(cause: "LinkError error 0", problems: ["problem"]), fallback: "запасное")
    check(hasCyrillic(rollback) && !rollback.contains("LinkError") && !rollback.contains("problem"),
          "сбой отката: короткий русский текст без сырой причины («\(rollback)»)")
    for error in [LinkError.timeout, LinkError.rejected, LinkError.incompatible(2)] {
        let text = StoreModel.failureMessage(error, fallback: "запасное")
        check(hasCyrillic(text) && !text.contains("LinkError") && text != "запасное", "LinkError: русский текст («\(text)»)")
    }
    let checksum = StoreModel.failureMessage(SatelliteInstallError.checksum, fallback: "запасное")
    check(checksum == SatelliteInstallError.checksum.errorDescription, "ошибки установщика показываются как есть")
    let offline = StoreModel.failureMessage(URLError(.notConnectedToInternet), fallback: "запасное")
    check(hasCyrillic(offline) && offline != "запасное", "нет сети: русский текст («\(offline)»)")
    check(StoreModel.failureMessage(NSError(domain: "x", code: 1), fallback: "запасное") == "запасное",
          "неизвестная ошибка: запасной текст вместо системного")

    // Настоящий текст системной программы: так launchctl отказывает в bootstrap.
    do {
        try KitSigning.run("/bin/sh", ["-c", "echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5"])
        check(false, "команда с кодом 5 должна упасть")
    } catch {
        let text = StoreModel.failureMessage(error, fallback: "Не удалось установить модуль")
        check(text == "Не удалось установить модуль", "отказ системной программы: без английского («\(text)»)")
        check(error.localizedDescription.contains("Bootstrap failed"), "сырой текст остаётся для журнала")
    }
    let own = StoreModel.failureMessage(KitSigning.Failure("Скачанное повреждено"), fallback: "запасное")
    check(own == "Скачанное повреждено", "свой русский текст показывается как есть")
    do {
        try KitSigning.verifySignature(of: fixtureZip, identifier: "local.utilitumus.test.nobody", strict: false)
        check(false, "неподписанный архив должен быть отвергнут")
    } catch {
        let text = StoreModel.failureMessage(error, fallback: "запасное")
        check(text == "Подпись Awake.zip не от автора Utilitumus", "отказ по подписи: коротко («\(text)»)")
        check(!StoreModel.offersBuiltIn(error), "отказ по подписи: встроенный не предлагается")
    }

    let offers: [(Error, String)] = [
        (URLError(.notConnectedToInternet), "нет сети"),
        (URLError(.timedOut), "сеть зависла"),
        (SatelliteInstallError.server(404), "сервер ответил 404"),
        (CocoaError(.fileWriteNoPermission), "нет прав на запись"),
        (POSIXError(.EACCES), "EACCES"),
        (POSIXError(.EPERM), "EPERM"),
    ]
    for (error, name) in offers { check(StoreModel.offersBuiltIn(error), "\(name): предлагается встроенный") }
    let noOffers: [(Error, String)] = [
        (SatelliteInstallError.checksum, "контрольная сумма"),
        (SatelliteInstallError.archive("x"), "плохой архив"),
        (SatelliteInstallError.rollbackFailed(cause: "x", problems: []), "сорвался откат"),
        (KitSigning.Failure("Подпись x не от автора"), "подпись"),
        (LinkError.timeout, "модуль не ответил"),
        (CocoaError(.fileNoSuchFile), "нет файла"),
    ]
    for (error, name) in noOffers { check(!StoreModel.offersBuiltIn(error), "\(name): встроенный не предлагается") }
    let denied = StoreModel.failureMessage(CocoaError(.fileWriteNoPermission), fallback: "запасное")
    check(hasCyrillic(denied) && denied != "запасное", "нет прав: русский текст («\(denied)»)")
    let refused = StoreModel.failureMessage(SatelliteInstallError.server(503), fallback: "запасное")
    check(refused.contains("503"), "сервер отказал: код виден («\(refused)»)")
}

@MainActor func catalogDownScenario(_ store: StoreModel, _ registry: SatelliteRegistry, _ modules: ModuleManager) async {
    await registry.update()
    check(Module.allCases.allSatisfy { store.state($0) == .available }, "каталог недоступен: все модули с «＋»")
    check(Set(ModuleCategory.all.flatMap(\.modules)) == Set(Module.allCases), "витрина перечисляет все модули")
    await snapshot("store-catalog-down", StoreWithSidebar())

    store.install(.awake)
    check(modules.isOn(.awake) && !modules.isExternal(.awake), "каталог недоступен: install(.awake) ставит встроенный")
    check(store.state(.awake) == .installed, "каталог недоступен: плитка «Установлен»")
    check(journal.count("download") == 0, "каталог недоступен: установщик не вызван")
    store.remove(.awake)
    check(store.state(.awake) == .available && !modules.isOn(.awake), "встроенный удаляется как раньше")
    check(registry.busy.isEmpty, "встроенный не занимает очередь установщика")

    stage.catalog = .hang
    registry.refresh()
    await pause(0.05)
    store.install(.awake)
    check(modules.isOn(.awake), "зависшая сеть не мешает поставить встроенный")
    store.remove(.awake)

    // Пустой каталог, как в выпуске 0.6.0 до первой утилиты: Стор идёт теми же путями, что и в 0.5.3.
    stage.catalog = .empty
    await registry.update()
    check(Module.allCases.allSatisfy { registry.catalogApp($0) == nil && !registry.hasBundle($0) }, "пустой каталог: записей нет")
    check(Module.allCases.allSatisfy { store.state($0) == .available }, "пустой каталог: все модули с «＋»")
    for module in [Module.awake, .clipboard] {
        store.install(module)
        check(modules.isOn(module) && !modules.isExternal(module) && store.state(module) == .installed, "пустой каталог: \(module.rawValue) ставится встроенным")
        store.remove(module)
        check(store.state(module) == .available && !modules.isOn(module), "пустой каталог: \(module.rawValue) удаляется как раньше")
    }
    check(journal.count("download") == 0 && store.failure == nil && registry.busy.isEmpty, "пустой каталог: установщика и ошибок нет")
    check(Kit.defaults.object(forKey: "App.awake.Enabled") == nil, "пустой каталог: ключей утилиты нет")
    stage.catalog = .down
}

@MainActor func installFailureScenario(_ store: StoreModel, _ registry: SatelliteRegistry, _ modules: ModuleManager) async {
    stage.catalog = .app(version: "1.0.0")
    await registry.update()
    check(registry.catalogApp(.awake) != nil, "каталог с awake прочитан")

    store.install(.clipboard)
    check(modules.isOn(.clipboard) && !registry.busy.contains(.clipboard) && journal.count("download") == 0,
          "модуль без записи в каталоге ставится как раньше")
    store.remove(.clipboard)

    store.install(.awake)
    check(store.state(.awake) != .available, "каталог с awake: пока идёт установка, «＋» нет")
    await waitIdle(store)
    check(journal.count("download") == 1, "каталог с awake: install идёт через установщик")
    check(store.state(.awake) == .available, "после ошибки установщика плитка снова «＋»")
    check(!modules.isOn(.awake) && !modules.isExternal(.awake), "после ошибки установщика модуль не включён")
    check(store.failure?.module == .awake && hasCyrillic(store.failure?.message ?? ""),
          "ошибка видна («\(store.failure?.message ?? "нет")»)")
    check(store.failure?.offersBuiltIn == true, "сеть: ошибка предлагает встроенный")
    await snapshot("store-install-failed", StoreWithSidebar())
    store.open(.awake)
    await pause(0.3)
    await snapshot("store-detail-failed", StoreView())
    store.close()

    let downloads = journal.count("download")
    store.installBuiltIn(.awake)
    check(modules.isOn(.awake) && !modules.isExternal(.awake), "предложенный встроенный включён")
    check(store.failure == nil && store.state(.awake) == .installed, "ошибки больше нет, плитка «Установлен»")
    check(journal.count("download") == downloads && registry.busy.isEmpty, "встроенный не идёт через установщик")
    await registry.update()
    check(modules.isOn(.awake) && !modules.isExternal(.awake), "опрос оставляет встроенный: бандла нет")
    store.remove(.awake)
    check(store.state(.awake) == .available, "встроенный снова удаляется как раньше")

    // Настоящий отказ файловой системы: папка приложений без права записи.
    stage.downloadFails = false
    try! fm.createDirectory(at: paths.appsDir, withIntermediateDirectories: true)
    try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.appsDir.path)
    store.install(.awake)
    await waitIdle(store)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.appsDir.path)
    check(store.failure?.offersBuiltIn == true, "нет прав на папку: ошибка предлагает встроенный («\(store.failure?.message ?? "нет")»)")
    check(!fm.fileExists(atPath: bundleURL.path) && !modules.isOn(.awake), "нет прав на папку: модуль не появился")

    // Подпись: архив тот же, отказ настоящий, встроенный здесь не лекарство.
    stage.verify = .foreign
    store.install(.awake)
    await waitIdle(store)
    check(store.failure?.message.contains("не от автора") == true, "чужая подпись: причина видна («\(store.failure?.message ?? "нет")»)")
    check(store.failure?.offersBuiltIn == false, "чужая подпись: встроенный не предлагается")
    check(!modules.isOn(.awake) && !fm.fileExists(atPath: bundleURL.path), "чужая подпись: ничего не поставлено")
    await snapshot("store-install-foreign", StoreWithSidebar())
    stage.verify = .ok
    stage.downloadFails = true
    store.dismissFailure()
}

@MainActor func installScenario(_ store: StoreModel, _ registry: SatelliteRegistry, _ modules: ModuleManager) async {
    stage.downloadFails = false
    stage.reply = LinkStatus(enabled: true, line: "Mac не уснёт", needsSetup: 0)
    Kit.defaults.set("значение", forKey: "Awake.Настройка")
    store.install(.awake)
    check(store.failure == nil, "новая установка снимает прежнюю ошибку")
    await waitIdle(store)
    check(store.failure == nil, "установка без ошибки: ошибки нет")
    check(fm.fileExists(atPath: bundleURL.path), "бандл на месте")
    check(journal.count("launchctl bootstrap") == 1, "агент загружен")
    check(modules.isExternal(.awake), "чек-лист сделан: модуль передан утилите")
    check(journal.count("setEnabled true") == 0, "встроенный был выключен: команду включиться утилита не получает")
    check(Kit.defaults.bool(forKey: "App.awake.HandedOver"), "HandedOver в настройках")
    check(Kit.defaults.bool(forKey: "App.awake.Enabled"), "App.awake.Enabled в настройках")
    check(!Kit.defaults.bool(forKey: ModuleManager.onKey(.awake)), "ModuleOn не включён")
    check(store.state(.awake) == .installed, "плитка «Установлен»")
    check(store.justInstalled == .awake, "подтверждение после установки")
    await snapshot("store-installed", StoreWithSidebar())

    let polls = journal.count("status")
    await snapshot("satellite-page", ModuleDetail(module: .awake))
    check(journal.count("status") > polls, "страница утилиты при открытии перечитывает статус")
    stage.reply = LinkStatus(enabled: true, line: "Ждёт доступов", needsSetup: 2)
    await registry.update()
    check(registry.entries[.awake]?.status?.needsSetup == 2, "страница видит чек-лист")
    await snapshot("satellite-page-needs-setup", ModuleDetail(module: .awake))
    stage.reply = nil
    await registry.update()
    check(registry.entries[.awake]?.responding == false && modules.isExternal(.awake), "не отвечает: встроенный не возвращается")
    await snapshot("satellite-page-not-responding", ModuleDetail(module: .awake))
    stage.reply = LinkStatus(enabled: false, line: "Mac засыпает как обычно", needsSetup: 0)
    await registry.update()
    await snapshot("satellite-page-off", ModuleDetail(module: .awake))

    journal.clear()
    registry.openWindow(.awake)
    registry.setEnabled(.awake, true)
    await pause(0.1)
    check(journal.count("openWindow") == 1, "«Открыть окно» уходит утилите")
    check(journal.count("setEnabled true") == 1, "переключатель уходит утилите")

    stage.catalog = .app(version: "2.0.0")
    await registry.update()
    check(store.hasUpdate(.awake), "в каталоге новее: есть обновление")
    check(store.pendingSetup(.awake) == nil, "чек-лист встроенного для утилиты не показывается")
    store.open(.awake)
    await pause(0.3)
    await snapshot("store-detail-update", StoreView())
    store.close()
    // В архиве 1.0.0, в каталоге 2.0.0: установщик отвергает, установленное цело.
    store.downloadResources(.awake)
    await waitIdle(store)
    check(store.failure != nil && modules.isExternal(.awake) && fm.fileExists(atPath: bundleURL.path),
          "неудачное обновление: ошибка видна, установленное цело")
    stage.downloadFails = true
    store.downloadResources(.awake)
    await waitIdle(store)
    check(store.failure?.message.contains("сеть") == true && store.failure?.offersBuiltIn == false,
          "обновление без сети: встроенный не предлагается, рядом с живой утилитой он работал бы дважды")
    stage.downloadFails = false
}

@MainActor func removeScenario(_ store: StoreModel, _ registry: SatelliteRegistry, _ modules: ModuleManager) async {
    stage.catalog = .app(version: "1.0.0")
    await registry.update()
    let removed = Box()
    let observer = NotificationCenter.default.addObserver(forName: .moduleRemoved, object: nil, queue: .main) { _ in removed.value = true }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.requestRemoval(.awake)
    store.remove(.awake)
    await waitIdle(store)
    await pause(0.05)
    check(journal.count("quit") >= 1, "«Удалить»: через установщик")
    check(!fm.fileExists(atPath: bundleURL.path), "«Удалить»: бандла нет")
    check(!Kit.defaults.bool(forKey: "App.awake.HandedOver"), "«Удалить»: передача сброшена")
    check(!modules.isOn(.awake) && !modules.isExternal(.awake), "«Удалить»: модуль не установлен")
    check(store.state(.awake) == .available, "«Удалить»: плитка снова «＋»")
    check(removed.value, "«Удалить»: главное окно уходит со страницы")
    check(Kit.defaults.string(forKey: "Awake.Настройка") == "значение", "«Удалить»: настройки остаются")

    // Выключили перед удалением, потом снова «＋»: включённым становится с установки, а не командой.
    Kit.defaults.set(false, forKey: "App.awake.Enabled")
    store.install(.awake)
    await waitIdle(store)
    check(store.failure == nil && fm.fileExists(atPath: bundleURL.path), "повторная установка прошла")
    check(Kit.defaults.object(forKey: "App.awake.Enabled") as? Bool == true, "«＋» значит «включить» и при повторной установке")
    store.remove(.awake)
    await waitIdle(store)
}

final class Box: @unchecked Sendable { var value = false }

@MainActor func runAll() async {
    // До первого обращения к общим объектам: иначе реестр заговорил бы с настоящими путями.
    SatelliteRegistry.standEnvironment = makeEnvironment()
    let registry = SatelliteRegistry.shared
    let store = StoreModel.shared
    let modules = ModuleManager.shared
    check(registry === store.satellites, "Стор работает с подставным реестром")
    messageChecks()
    await catalogDownScenario(store, registry, modules)
    await installFailureScenario(store, registry, modules)
    await installScenario(store, registry, modules)
    await removeScenario(store, registry, modules)
    print(failures == 0 ? "Все проверки прошли" : "Провалов: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

try! fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
UserDefaults.standard.set(true, forKey: ModuleReset.flagKey)
Task { @MainActor in await runAll() }
app.run()
