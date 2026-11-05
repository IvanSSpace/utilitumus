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
    enum CatalogMode { case down, hang, app(version: String) }
    private let lock = NSLock()
    private var _catalog = CatalogMode.down
    private var _downloadFails = true
    private var _reply: LinkStatus?
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var catalog: CatalogMode { get { locked { _catalog } } set { locked { _catalog = newValue } } }
    var downloadFails: Bool { get { locked { _downloadFails } } set { locked { _downloadFails = newValue } } }
    var reply: LinkStatus? { get { locked { _reply } } set { locked { _reply = newValue } } }
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
        verify: { _, _ in journal.add("verify") },
        link: SatelliteLink(quit: { _ in journal.add("quit") }, hello: { _ in }))
    return SatelliteEnvironment(
        paths: paths,
        defaults: Kit.defaults,
        installer: installer,
        commands: SatelliteCommands(
            status: { _ in
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

/// Стор рядом с боковой панелью: на снимке видны и вкладки категорий.
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
    await snapshot("store-install-failed", StoreWithSidebar())
    store.open(.awake)
    await pause(0.3)
    await snapshot("store-detail-failed", StoreView())
    store.close()
}

@MainActor func installScenario(_ store: StoreModel, _ registry: SatelliteRegistry, _ modules: ModuleManager) async {
    stage.downloadFails = false
    stage.reply = LinkStatus(enabled: true, line: "Mac не уснёт · ещё 1 ч", needsSetup: 0)
    Kit.defaults.set("значение", forKey: "Awake.Настройка")
    store.install(.awake)
    check(store.failure == nil, "новая установка снимает прежнюю ошибку")
    await waitIdle(store)
    check(store.failure == nil, "установка без ошибки: ошибки нет")
    check(fm.fileExists(atPath: bundleURL.path), "бандл на месте")
    check(journal.count("launchctl bootstrap") == 1, "агент загружен")
    check(modules.isExternal(.awake), "чек-лист сделан: модуль передан утилите")
    check(journal.count("setEnabled true") == 1, "утилите сказано включиться")
    check(Kit.defaults.bool(forKey: "App.awake.HandedOver"), "HandedOver в настройках")
    check(Kit.defaults.bool(forKey: "App.awake.Enabled"), "App.awake.Enabled в настройках")
    check(!Kit.defaults.bool(forKey: ModuleManager.onKey(.awake)), "ModuleOn не включён")
    check(store.state(.awake) == .installed, "плитка «Установлен»")
    check(store.justInstalled == .awake, "подтверждение после установки")
    await snapshot("store-installed", StoreWithSidebar())

    await snapshot("satellite-page", ModuleDetail(module: .awake))
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
