import AppKit
import Combine
import SwiftUI

/// Сборка со швом работает под тестовой меткой launchd и своим id: настоящие имена ей не нужны.
/// Исключение — `KIT_TEST_REAL_ID`: сквозной проверке нужен плист, который пишет настоящий установщик.
enum AwakeIdentity {
    #if KIT_TEST_DEFAULTS && !KIT_TEST_REAL_ID
    static let id = "test.awake"
    static let label = "local.utilitumus.test.awake"
    #else
    static let id = Module.awake.rawValue
    static let label = KitLink.bundleID(id)
    #endif
}

/// Подключается к своему сервису, просит показать окно и выходит. Не вышло — всё равно выходит:
/// второй работающей копии быть не должно.
@MainActor func forwardOpenWindowAndExit() -> Never {
    let client = LinkClient(id: AwakeIdentity.id)
    Task { @MainActor in
        do {
            try await client.openWindow()
        } catch {
            fputs("Не спать: работающая копия не ответила: \(error)\n", stderr)
        }
        exit(0)
    }
    dispatchMain()
}

#if KIT_TEST_DEFAULTS
/// Система возвращает окно с заголовком на экран: стенду нужно, чтобы оно осталось за ним.
private final class AwakeWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#else
private typealias AwakeWindow = NSWindow
#endif

@MainActor
final class AwakeSatellite: ObservableObject, LinkHandler {
    static let shared = AwakeSatellite()

    @Published private(set) var mode: SatelliteRole.Mode = .active
    @Published private(set) var enabled = false

    private let controller = AwakeController.shared
    private var server: LinkServer?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    var canStart: Bool { mode == .active && enabled }

    static func currentMode() -> SatelliteRole.Mode {
        SatelliteRole.decide(
            launchedByLaunchd: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == AwakeIdentity.label,
            hubRunning: SatelliteHub.isRunning,
            hubVersion: SatelliteHub.version,
            hubModuleOn: Kit.defaults.bool(forKey: SatelliteRole.hubModuleOnKey(AwakeIdentity.id)),
            handedOver: Kit.defaults.bool(forKey: SatelliteRole.handedOverKey(AwakeIdentity.id)))
    }

    func run() {
        #if !KIT_TEST_DEFAULTS
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: Module.awake.icon, accessibilityDescription: Module.awake.title)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
        #endif
        refresh()

        // Publisher срабатывает до записи значения: читать его можно только следующим шагом.
        controller.$isActive.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { _ in KitLink.postStatusChanged(AwakeIdentity.id) }
            .store(in: &subscriptions)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Kit.hubBundleID else { return }
                MainActor.assumeIsolated { AwakeSatellite.shared.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CustomPaletteStore.shared.reload() }
        })

        let server = LinkServer(id: AwakeIdentity.id, handler: self,
                                peerIdentifiers: [Kit.hubBundleID, KitLink.bundleID(AwakeIdentity.id)])
        server.resume()
        self.server = server

        #if KIT_TEST_DEFAULTS
        installTestSignals()
        #else
        scheduleUpdateChecks()
        #endif
    }

    /// Роль решается заново: центр мог передать модуль, запуститься или выйти.
    private func refresh() {
        let before = statusLine()
        Kit.defaults.synchronize()
        mode = Self.currentMode()
        enabled = SatelliteEnabled.load(id: AwakeIdentity.id, defaults: Kit.defaults)
        if !canStart { controller.stop() }
        statusItem?.isVisible = !SatelliteHub.isRunning
        if statusLine() != before { KitLink.postStatusChanged(AwakeIdentity.id) }
    }

    func setEnabled(_ on: Bool) {
        Kit.defaults.set(on, forKey: SatelliteEnabled.key(AwakeIdentity.id))
        refresh()
        KitLink.postStatusChanged(AwakeIdentity.id)
    }

    /// Команда «Не спать»: пока модуль ведёт центр или утилита выключена, блокировку не создаёт.
    func commandKeepAwake() {
        if controller.isActive || canStart { controller.toggle() }
    }

    func statusLine(now: Date = Date()) -> String {
        if case .passive(let reason) = mode { return reason }
        guard controller.isActive else { return "Mac засыпает как обычно" }
        guard let end = controller.endDate else { return "Mac не уснёт" }
        var left = AwakeController.remainingText(until: end, now: now)
        if left.hasSuffix(" 0 мин") { left.removeLast(" 0 мин".count) }
        return "Mac не уснёт · ещё \(left)"
    }

    // MARK: - LinkHandler

    func linkHello() -> LinkHello {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return LinkHello(id: AwakeIdentity.id, version: version, protocolVersion: KitLink.protocolVersion)
    }

    func linkStatus() -> LinkStatus {
        LinkStatus(enabled: enabled, line: statusLine(), needsSetup: 0)
    }

    func linkSetEnabled(_ enabled: Bool) { setEnabled(enabled) }
    func linkOpenWindow() { showWindow() }

    func linkQuit() {
        controller.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Окно

    @objc private func statusItemClicked() { showWindow() }

    private func showWindow() {
        CustomPaletteStore.shared.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        #if KIT_TEST_DEFAULTS
        // Стенд: окно не показывается пользователю, картинку снимает cacheDisplay.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: 0))
        window.orderBack(nil)
        #else
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        #endif
        let frame = window.frame
        fputs("Не спать: окно показано \(Int(frame.width))x\(Int(frame.height)) x=\(Int(frame.minX))\n", stderr)
    }

    private func makeWindow() -> NSWindow {
        let window = AwakeWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                                 styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.title = Module.awake.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AwakeWindowRoot())
        // Размер окна задан здесь: иначе зона заголовка прибавилась бы к нему сверху.
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 480, height: 520))
        return window
    }

    // MARK: - Обновления без центра

    #if !KIT_TEST_DEFAULTS
    private var restartPending = false

    private func scheduleUpdateChecks() {
        // Часовой таймер и дата в настройках: Mac спит, а сутки всё равно считаются по календарю.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await AwakeSatellite.shared.checkForUpdate() }
        }
        Task { await checkForUpdate() }
    }

    private func checkForUpdate() async {
        // Перезапуск снял бы блокировку, которую пользователь сам включил.
        guard !controller.isActive else { return }
        if restartPending { return restart() }
        guard !SatelliteHub.isRunning else { return }
        let key = "App.\(AwakeIdentity.id).LastUpdateCheck"
        if let last = Kit.defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86400 { return }
        Kit.defaults.set(Date(), forKey: key)
        do {
            let (data, _) = try await URLSession.shared.data(from: SatelliteCatalog.url)
            let catalog = try SatelliteCatalog.decode(data)
            guard let app = SatelliteSelfUpdate.newer(in: catalog, id: AwakeIdentity.id, than: linkHello().version) else { return }
            try await SatelliteSelfUpdate.install(app, target: Bundle.main.bundleURL)
            restartPending = true
            if !controller.isActive { restart() }
        } catch {
            fputs("Не спать: обновление не вышло: \(error.localizedDescription)\n", stderr)
        }
    }

    private func restart() {
        do {
            try KitSigning.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(AwakeIdentity.label)"])
        } catch {
            fputs("Не спать: перезапуск не вышел: \(error.localizedDescription)\n", stderr)
        }
    }
    #endif

    // MARK: - Шов для стенда

    #if KIT_TEST_DEFAULTS
    private var testSignals: [DispatchSourceSignal] = []

    /// USR1 — команда «Не спать», USR2 — снимок окна в файл из `Test.PNGPath`.
    private func installTestSignals() {
        for (number, action) in [(SIGUSR1, { AwakeSatellite.shared.commandKeepAwake() }),
                                 (SIGUSR2, { AwakeSatellite.shared.writeWindowPNG() })] as [(Int32, @MainActor () -> Void)] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { action() } }
            source.resume()
            testSignals.append(source)
        }
    }

    private func writeWindowPNG() {
        guard let view = window?.contentView, let path = Kit.defaults.string(forKey: "Test.PNGPath"),
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}

/// Содержимое окна: страница модуля, фон темы и строка статуса.
struct AwakeWindowRoot: View {
    @ObservedObject private var satellite = AwakeSatellite.shared
    @ObservedObject private var controller = AwakeController.shared

    var body: some View {
        VStack(spacing: 0) {
            AwakeView(canStart: satellite.canStart)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(satellite.statusLine(now: context.date))
                    .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .background(AwakeBackground())
        .environment(\.moduleControls) { _ in AnyView(AwakeControls()) }
        .dsThemed()
    }
}

private struct AwakeBackground: View {
    @Environment(\.dsTheme) private var theme
    var body: some View {
        LinearGradient(colors: theme.background(.awake), startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Переключатель `App.awake.Enabled`.
private struct AwakeControls: View {
    @ObservedObject private var satellite = AwakeSatellite.shared
    var body: some View {
        HStack(spacing: 7) {
            Text(satellite.enabled ? "Включён" : "Выключен")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(satellite.enabled ? 0.85 : 0.5))
            DSToggle("Модуль включён", isOn: Binding(get: { satellite.enabled }, set: { satellite.setEnabled($0) }))
        }
    }
}
