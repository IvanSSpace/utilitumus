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

/// launchd придерживает перезапуск процесса, прожившего меньше 10 с: столько копия может не отвечать.
private let forwardRetryWindow: TimeInterval = 12

/// Подключается к своему сервису, просит показать окно и выходит. Копия не ответила за всё окно ожидания —
/// говорит об этом и тоже выходит: второй работающей копии быть не должно.
@MainActor func forwardOpenWindowAndExit() -> Never {
    Task { @MainActor in
        let deadline = Date().addingTimeInterval(forwardRetryWindow)
        var failure: Error?
        repeat {
            do {
                try await LinkClient(id: AwakeIdentity.id).openWindow()
                exit(0)
            } catch {
                failure = error
                try? await Task.sleep(for: .seconds(0.5))
            }
        } while Date() < deadline
        fputs("Не спать: работающая копия не ответила: \(String(describing: failure))\n", stderr)
        showForwardFailure()
        exit(1)
    }
    dispatchMain()
}

@MainActor private func showForwardFailure() {
    #if KIT_TEST_DEFAULTS
    // Стенд: видимых окон нет.
    fputs("Не спать: окно об ошибке запуска\n", stderr)
    #else
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "«Не спать» не запускается"
    alert.informativeText = "Его фоновая часть не ответила. Поставь приложение заново: в Сторе Utilitumus или через install.sh."
    alert.runModal()
    #endif
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
    private var runningApps: NSKeyValueObservation?
    private var hubRunning = false

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

        // Не didLaunch/didTerminate: о приложениях без Dock (утилита сама такая, центр — при выключенной настройке Dock)
        // они не сообщают, и значок не вернулся бы после выхода центра.
        runningApps = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
            Task { @MainActor in AwakeSatellite.shared.hubMayHaveChanged() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CustomPaletteStore.shared.reload() }
        })

        let server = LinkServer(id: AwakeIdentity.id, handler: self,
                                peerIdentifiers: [Kit.hubBundleID, KitLink.bundleID(AwakeIdentity.id)])
        server.resume()
        self.server = server
        // Центр мог спросить раньше, чем сервис поднялся, и теперь показывает «Не отвечает».
        KitLink.postStatusChanged(AwakeIdentity.id)

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
        if SatelliteRole.mustRelease(mode: mode, enabled: enabled) { controller.stop() }
        hubRunning = SatelliteHub.isRunning
        statusItem?.isVisible = !hubRunning
        #if KIT_TEST_DEFAULTS
        fputs("Не спать: значок \(hubRunning ? "скрыт" : "виден")\n", stderr)
        #endif
        if statusLine() != before { KitLink.postStatusChanged(AwakeIdentity.id) }
    }

    private func hubMayHaveChanged() {
        if SatelliteHub.isRunning != hubRunning { refresh() }
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

    /// Без остатка времени: центр перечитывает строку редко, и «ещё 2 ч» застывало бы у него на экране.
    func statusLine() -> String {
        if controller.isActive { return "Mac не уснёт" }
        if case .passive(let reason) = mode { return reason }
        return "Mac засыпает как обычно"
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
        // Активацию система может не дать: окно всё равно должно выйти вперёд.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
        // Один раз: при следующих показах окно остаётся там, куда его поставили.
        window.center()
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
        do {
            let (data, _) = try await URLSession.shared.data(from: SatelliteCatalog.url)
            let catalog = try SatelliteCatalog.decode(data)
            // Только после удачного чтения: Mac без сети проверит снова через час, а не через сутки.
            Kit.defaults.set(Date(), forKey: key)
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
            Text(satellite.statusLine())
                .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
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
