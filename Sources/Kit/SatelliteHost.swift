import AppKit
import Combine
import SwiftUI

/// launchd придерживает перезапуск процесса, прожившего меньше 10 с: столько копия может не отвечать.
private let forwardRetryWindow: TimeInterval = 12

/// Точка входа утилиты: `SatelliteMain.run(МойМодуль())` в `main.swift`. Работает только копия, запущенная launchd:
/// запуск из Finder просит её показать окно и выходит.
enum SatelliteMain {
    @MainActor private static var delegate: SatelliteAppDelegate?

    @MainActor static func run(_ module: SatelliteModule) {
        let host = SatelliteHost(module)
        #if KIT_DEV_ALONE
        // Дев-копия одна на свои настройки и ни с кем не связана: пересылать окно некому. Отказ без подставного дома здесь.
        _ = Kit.defaults
        let app = NSApplication.shared
        app.setActivationPolicy(Kit.standWindowHidden ? .accessory : .regular)
        #else
        if host.currentMode() == .forwardAndExit { host.forwardOpenWindowAndExit() }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        #endif
        delegate = SatelliteAppDelegate(host)
        app.delegate = delegate
        app.run()
    }
}

private final class SatelliteAppDelegate: NSObject, NSApplicationDelegate {
    private let host: SatelliteHost
    init(_ host: SatelliteHost) { self.host = host }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { host.run() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { host.terminating() }
    }

    #if KIT_DEV_ALONE
    /// Значка в строке меню и центра нет: окно не открыть заново, закрыли его — значит, закончили.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    #endif
}

#if KIT_TEST_DEFAULTS
/// Система возвращает окно с заголовком на экран: стенду нужно, чтобы оно осталось за ним.
private final class SatelliteWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#else
private typealias SatelliteWindow = NSWindow
#endif

/// Всё в утилите, кроме самого модуля: роль, связь, значок, окно, статус, обновление.
@MainActor
final class SatelliteHost: ObservableObject, LinkHandler {
    let module: SatelliteModule
    @Published private(set) var mode: SatelliteRole.Mode = .active
    @Published private(set) var enabled = false

    private var id: String { LinkIdentity.id(module.linkName) }
    private var label: String { LinkIdentity.label(module.linkName) }
    private var title: String { module.module.title }

    private var server: LinkServer?
    private var window: NSWindow?
    private var statusItem: MenuBarIconItem?
    /// Что показывает переключатель «Значок в строке меню»: явное «да» (пока ключа нет, он выключен).
    @Published private(set) var menuIconOn = false
    @Published private(set) var menuIconNotice: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var runningApps: NSKeyValueObservation?
    private var hubRunning = false
    /// Между `start` и остановкой.
    private var working = false
    private var quitting = false
    private var screenLeased = false
    private var windowOpen = false
    private var screenForwarded = false
    private var announcedStatus: LinkStatus?

    /// Склейка: подписчикам не чаще 4 раз в секунду, последнее изменение не теряется.
    private lazy var statePing = LinkThrottle(interval: 0.25) { [weak self] in
        self?.server?.pingState()
        self?.statusPing.fire()
    }
    /// Уведомление видно всем, поэтому только при смене самого статуса и не чаще раза в секунду.
    private lazy var statusPing = LinkThrottle(interval: 1) { [weak self] in self?.announceStatus() }

    init(_ module: SatelliteModule) {
        self.module = module
    }

    func currentMode() -> SatelliteRole.Mode {
        #if KIT_DEV_ALONE
        // Запускает человек из терминала, launchd о копии не знает.
        let launchedByLaunchd = true
        #else
        let launchedByLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
        #endif
        return SatelliteRole.decide(
            launchedByLaunchd: launchedByLaunchd,
            hubRunning: SatelliteHub.isRunning,
            hubVersion: SatelliteHub.version,
            hubModuleOn: Kit.defaults.bool(forKey: SatelliteRole.hubModuleOnKey(id)),
            handedOver: Kit.defaults.bool(forKey: SatelliteRole.handedOverKey(id)))
    }

    func run() {
        #if !KIT_TEST_DEFAULTS
        statusItem = MenuBarIconItem(
            module: module.module,
            content: { [weak self] in
                guard let self else { return .init(status: "", actions: []) }
                return .init(status: self.statusLine(), actions: self.mode == .active && self.enabled ? self.module.quickActions : [])
            },
            perform: { [weak self] quick in _ = self?.module.handle(quick.action) },
            open: { [weak self] in
                guard let self else { return }
                MenuBarIcon.requestOpen(self.module.module, hub: SatelliteHub.bundleURL)
            },
            hide: { [weak self] in self?.setMenuIcon(false) },
            click: { [weak self] in self?.showWindow() })
        #endif
        refresh()

        module.changes.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.statePing.fire()
        }.store(in: &subscriptions)

        // Не didLaunch/didTerminate: о приложениях без Dock (утилита сама такая, центр — при выключенной настройке Dock)
        // они не сообщают, и значок не вернулся бы после выхода центра.
        runningApps = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.hubMayHaveChanged() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CustomPaletteStore.shared.reload() }
        })

        // Дев-копия ни с кем не говорит: служб launchd у неё нет, слушать нечего.
        #if !KIT_DEV_ALONE
        let server = LinkServer(id: id, handler: self)
        server.resume()
        self.server = server
        #endif
        // Центр мог спросить раньше, чем сервис поднялся, и теперь показывает «Не отвечает».
        postStatus()

        #if KIT_TEST_DEFAULTS
        installTestSignals()
        #else
        scheduleUpdateChecks()
        #endif
        #if KIT_DEV_ALONE
        showWindow()
        #endif
    }

    // MARK: - Роль

    /// Роль решается заново: центр мог передать модуль, запуститься или выйти.
    private func refresh() {
        Kit.defaults.synchronize()
        mode = currentMode()
        enabled = SatelliteEnabled.load(id: id, defaults: Kit.defaults)
        applyRole()
        hubRunning = SatelliteHub.isRunning
        applyMenuIcon()
        announceStatus()
    }

    /// Значок по сохранённой настройке: без неё его нет. Читается при запуске и при смене роли.
    private func applyMenuIcon() {
        let setting = MenuBarIcon.setting(module.module)
        let shows = MenuBarIcon.utilityShows(setting: setting, hubRunning: hubRunning, active: mode == .active)
        menuIconOn = MenuBarIcon.switchOn(setting)
        menuIconNotice = nil
        statusItem?.isVisible = shows
        statusItem?.setUsesMenu(MenuBarIcon.utilityUsesMenu(hubRunning: hubRunning))
        #if KIT_TEST_DEFAULTS
        fputs("\(title): значок \(shows ? "виден" : "скрыт")\n", stderr)
        #endif
    }

    /// Из окна утилиты и из «Скрыть значок»: записать и применить сразу. Центр читает ключ из другого процесса,
    /// поэтому сперва `synchronize`, потом сигнал: по нему он перечитает настройку.
    func setMenuIcon(_ on: Bool) {
        if on, !menuIconOn, Module.allCases.filter({ MenuBarIcon.setting($0) == true }).count >= MenuBarIcon.maxPins {
            menuIconNotice = MenuBarIcon.limitNotice
            return
        }
        MenuBarIcon.set(on, module.module)
        Kit.defaults.synchronize()
        applyMenuIcon()
        postStatus()
    }

    /// Пассивная значит остановленная: рядом со встроенным модулем утилита не работает.
    private func applyRole() {
        if mode == .active && enabled {
            if !working {
                working = true
                module.start()
            }
        } else {
            let wasWorking = working
            working = false
            syncScreen()
            if SatelliteRole.mustRelease(mode: mode, enabled: enabled, hubVersion: SatelliteHub.version) {
                module.stop()
            } else if wasWorking {
                module.enterPassive()
            }
        }
        syncScreen()
    }

    private func hubMayHaveChanged() {
        if SatelliteHub.isRunning != hubRunning { refresh() }
    }

    func setEnabled(_ on: Bool) {
        Kit.defaults.set(on, forKey: SatelliteEnabled.key(id))
        refresh()
        postStatus()
    }

    func statusLine() -> String {
        if case .passive(let reason) = mode { return module.statusLine(passiveReason: reason) }
        return module.statusLine(passiveReason: nil)
    }

    private func announceStatus() {
        guard linkStatus() != announcedStatus else { return }
        postStatus()
    }

    private func postStatus() {
        announcedStatus = linkStatus()
        KitLink.postStatusChanged(id)
    }

    fileprivate func terminating() {
        guard !quitting else { return }
        quitting = true
        working = false
        module.stopForUpdate()
    }

    // MARK: - Экран открыт

    private func syncScreen() {
        let want = working && (screenLeased || windowOpen)
        guard want != screenForwarded else { return }
        screenForwarded = want
        module.screenOpen(want)
    }

    func linkScreenOpen(_ open: Bool) {
        screenLeased = open
        syncScreen()
    }

    func linkWatcherLost() {
        postStatus()
    }

    // MARK: - LinkHandler

    func linkHello() -> LinkHello {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return LinkHello(id: id, version: version, protocolVersion: KitLink.protocolVersion,
                         oldestProtocolVersion: KitLink.oldestProtocolVersion)
    }

    func linkStatus() -> LinkStatus {
        let steps = module.setupSteps
        return LinkStatus(enabled: enabled, line: statusLine(), needsSetup: steps.filter { $0.required && !$0.done }.count,
                          attention: module.attention, quickActions: module.quickActions, setupSteps: steps)
    }

    func linkModuleState() -> Data { module.state() }
    func linkModuleAction(_ action: Data) -> Data { module.handle(action) }

    /// Только шаги, которые модуль сам объявил.
    func linkPerformSetupStep(_ id: String) -> Data {
        guard module.setupSteps.contains(where: { $0.id == id }) else {
            return LinkWire.encoded(LinkReply(state: linkStatus(), error: "Такого шага нет"))
        }
        let error = module.performSetupStep(id)
        let status = linkStatus()
        announceStatus()
        return LinkWire.encoded(LinkReply(state: status, error: error))
    }

    func linkSetEnabled(_ enabled: Bool) { setEnabled(enabled) }
    /// Только служба центра: у копии из Finder такого вызова в интерфейсе нет. Настройку центр уже записал или снял,
    /// сама команда значения не несёт: снятый ключ словом `false` не передать.
    func linkSetMenuIcon(_ on: Bool) {
        Kit.defaults.synchronize()
        applyMenuIcon()
    }
    func linkOpenWindow() { showWindow() }

    func linkQuit(_ reason: LinkQuitReason) {
        // Центр получил ответ раньше и уже снимает агента: SIGTERM от launchd оборвал бы возврат настроек
        // посередине. Выходим сами, сразу после остановки модуля.
        signal(SIGTERM, SIG_IGN)
        quitting = true
        working = false
        switch reason {
        case .update: module.stopForUpdate()
        case .uninstall: module.stopForUninstall()
        }
        NSApp.terminate(nil)
    }

    // MARK: - Окно

    private func showWindow() {
        CustomPaletteStore.shared.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        #if KIT_TEST_DEFAULTS
        // Стенд: окно не показывается пользователю, картинку снимает cacheDisplay.
        if Kit.standWindowHidden {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: -10000, y: 0))
            window.orderBack(nil)
        } else {
            bringToFront(window)
        }
        #else
        bringToFront(window)
        #endif
        windowOpen = true
        syncScreen()
        let frame = window.frame
        fputs("\(title): окно показано \(Int(frame.width))x\(Int(frame.height)) x=\(Int(frame.minX))\n", stderr)
    }

    /// Активацию система может не дать: окно всё равно должно выйти вперёд.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let size = module.windowSize
        let window = SatelliteWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SatelliteWindowRoot(host: self))
        // Размер окна задан здесь: иначе зона заголовка прибавилась бы к нему сверху.
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        // Один раз: при следующих показах окно остаётся там, куда его поставили.
        window.center()
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowOpen = false
                self?.syncScreen()
            }
        })
        return window
    }

    // MARK: - Копия из Finder

    /// Подключается к своему сервису, просит показать окно и выходит. Копия не ответила за всё окно ожидания —
    /// говорит об этом и тоже выходит: второй работающей копии быть не должно.
    fileprivate func forwardOpenWindowAndExit() -> Never {
        let id = id, title = title
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(forwardRetryWindow)
            var failure: Error?
            repeat {
                do {
                    try await LinkSelfClient.openWindow(id: id)
                    exit(0)
                } catch {
                    failure = error
                    try? await Task.sleep(for: .seconds(0.5))
                }
            } while Date() < deadline
            fputs("\(title): работающая копия не ответила: \(String(describing: failure))\n", stderr)
            Self.showForwardFailure(title)
            exit(1)
        }
        dispatchMain()
    }

    private static func showForwardFailure(_ title: String) {
        #if KIT_TEST_DEFAULTS
        // Стенд: видимых окон нет.
        fputs("\(title): окно об ошибке запуска\n", stderr)
        #else
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "«\(title)» не запускается"
        alert.informativeText = "Его фоновая часть не ответила. Поставь приложение заново: в Сторе Utilitumus или через install.sh."
        alert.runModal()
        #endif
    }

    // MARK: - Обновления без центра

    #if !KIT_TEST_DEFAULTS
    private var restartPending = false

    private func scheduleUpdateChecks() {
        // Обновляется только по кнопке в центре: ни таймера, ни обращения к каталогу.
        guard SatelliteSelfUpdate.mayUpdateItself(id: id) else { return }
        // Часовой таймер и дата в настройках: Mac спит, а сутки всё равно считаются по календарю.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdate() }
        }
        Task { await checkForUpdate() }
    }

    private func checkForUpdate() async {
        // Перезапуск снял бы то, что пользователь сам включил.
        guard module.mayRestart else { return }
        if restartPending { return restart() }
        guard !SatelliteHub.isRunning else { return }
        let key = "App.\(id).LastUpdateCheck"
        if let last = Kit.defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86400 { return }
        var stopped = false
        do {
            let (data, _) = try await URLSession.shared.data(from: SatelliteCatalog.url)
            let catalog = try SatelliteCatalog.decode(data)
            // Только после удачного чтения: Mac без сети проверит снова через час, а не через сутки.
            Kit.defaults.set(Date(), forKey: key)
            guard let app = SatelliteSelfUpdate.newer(in: catalog, id: id, than: linkHello().version) else { return }
            try await SatelliteSelfUpdate.install(app, target: Bundle.main.bundleURL) {
                stopped = true
                self.working = false
                self.syncScreen()
                self.module.stopForUpdate()
            }
            restartPending = true
            if module.mayRestart { restart() }
        } catch {
            fputs("\(title): обновление не вышло: \(error.localizedDescription)\n", stderr)
            if stopped { applyRole() }
        }
    }

    private func restart() {
        do {
            try KitSigning.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        } catch {
            fputs("\(title): перезапуск не вышел: \(error.localizedDescription)\n", stderr)
        }
    }
    #endif

    // MARK: - Шов для стенда

    #if KIT_TEST_DEFAULTS
    private var testSignals: [DispatchSourceSignal] = []

    /// USR1 — команда модуля, USR2 — снимок окна в файл из `Test.PNGPath`.
    private func installTestSignals() {
        for (number, action) in [(SIGUSR1, { [weak self] in self?.module.standCommand() }),
                                 (SIGUSR2, { [weak self] in self?.writeWindowPNG() })] as [(Int32, @MainActor () -> Void)] {
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
private struct SatelliteWindowRoot: View {
    @ObservedObject var host: SatelliteHost

    var body: some View {
        VStack(spacing: 0) {
            host.module.windowRoot()
            Text(host.statusLine())
                .font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .background(SatelliteBackground(module: host.module.module))
        .environment(\.moduleControls) { _ in AnyView(SatelliteControls(host: host)) }
        .dsThemed()
    }
}

private struct SatelliteBackground: View {
    let module: Module
    @Environment(\.dsTheme) private var theme
    var body: some View {
        LinearGradient(colors: theme.background(module), startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Переключатели `App.<id>.Enabled` и `MenuBarIcon.<id>`.
private struct SatelliteControls: View {
    @ObservedObject var host: SatelliteHost
    var body: some View {
        HStack(spacing: 10) {
            if let notice = host.menuIconNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            DSMenuIconSwitch(isOn: Binding(get: { host.menuIconOn }, set: { host.setMenuIcon($0) }))
            HStack(spacing: 7) {
                Text(host.enabled ? "Включён" : "Выключен")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(host.enabled ? 0.85 : 0.5))
                DSToggle("Модуль включён", isOn: Binding(get: { host.enabled }, set: { host.setEnabled($0) }))
            }
        }
    }
}
