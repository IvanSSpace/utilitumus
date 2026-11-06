import SwiftUI
import AppKit

struct ModuleDetail: View {
    let module: Module
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        if modules.isExternal(module) {
            switch module {
            case .awake: RemoteAwakePage()
            case .sound: RemoteSoundPage()
            case .mouse: RemoteMousePage()
            case .mixer: RemoteMixerPage()
            case .browser: RemoteBrowserPage()
            case .fans: RemoteFansPage()
            case .voice: RemoteVoicePage()
            default: SatellitePage(module: module)
            }
        } else {
            ModuleScreen(module: module) {
                switch module {
                case .sound: SoundView()
                case .fans: FansView()
                case .load: LoadScreen()
                case .stash: StashView()
                case .mixer: MixerView()
                case .mouse: MouseView()
                case .browser: BrowserView()
                case .voice: VoiceView()
                case .clipboard: ClipboardView()
                case .keyboard: KeyboardView()
                case .awake: AwakeView(model: AwakeController.shared)
                }
            }
        }
    }
}

struct MainView: View {
    @AppStorage("SelectedModule") private var selection: Module = .sound
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var whatsNew = WhatsNew.shared
    @Environment(\.dsTheme) private var theme
    @AppStorage(DS.sidebarHiddenKey) private var sidebarHidden = false
    /// «О проекте» — не модуль, поэтому отдельный флаг; не сохраняем, окно открывается на модуле.
    @State private var showAbout = false
    /// Дашборд — стартовая страница, пока его строка в панели включена; иначе открываем модуль. Не сохраняем.
    @State private var showDashboard = DS.dashboardInSidebar
    /// Стор открывается сразу при запуске с `-OpenStore YES` (для снимков).
    @State private var showStore = UserDefaults.standard.bool(forKey: "OpenStore")
    /// Скрытый модуль, открытый со страницы «О проекте»: показываем один раз,
    /// состояние не меняем, в панели его по-прежнему нет.
    @State private var peeked: Module?
    /// Приветствие поверх окна: один раз (флаг `Welcome.seenKey`), потом открывается Стор.
    @State private var showWelcome = !Welcome.isSeen
    /// Повтор из «О проекте»: по окончании просто закрываем, никуда не переходим.
    @State private var welcomeReplay = false
    /// Режим страниц: «Быстрый» держит экраны в кэше, «Экономный» собирает экран при открытии.
    @AppStorage(PageMode.storageKey) private var pageModeRaw = PageMode.fast.rawValue
    /// Только для «Экономного»: модуль, чей экран сейчас построен. Догоняет `displayed` следующим кадром,
    /// чтобы выделение в боковой панели переключалось сразу, а не ждало 100–200 мс сборки экрана.
    @State private var built: Module?

    var body: some View {
        let fast = (PageMode(rawValue: pageModeRaw) ?? .fast) == .fast
        // Выбранный модуль могли скрыть или выключить: показываем первый из показанных.
        let current = modules.resolve(selection)
        let displayed = peeked ?? current
        // Для фона и акцента на «О проекте» и пустой панели берём последний выбранный модуль.
        let tintModule = displayed ?? selection
        let onStore = showStore && !showAbout
        let pageTint = onStore ? theme.storeTint() : theme.accent(tintModule)
        let onDashboard = showDashboard && !showAbout && !showStore
        let detail = displayed == nil ? nil : (built ?? displayed)
        let pageKey: PageKey = showAbout ? .about : showStore ? .store : (showDashboard ? .dashboard : (displayed.map { .module($0) } ?? .empty))
        ZStack {
            DSBackground(module: tintModule, neutral: onDashboard || onStore)
            HStack(spacing: 0) {
                if !sidebarHidden {
                    DSSidebar(current: current, showDashboard: $showDashboard, showStore: $showStore, showAbout: $showAbout,
                              peeked: $peeked, selection: $selection)
                        // Без собственной заливки и границы: панель лежит прямо на фоне окна,
                        // единственный поднятый элемент — карточка страницы.
                        .frame(width: DS.sidebarWidth)
                }
                Group {
                    if fast {
                        // Живой кэш: каждая страница в своём NSHostingView, скрытые сняты с иерархии
                        // (не считаются и не влияют на размер окна). Окружение через границу хостинга не
                        // проходит, поэтому тема и акцент задаются на корне каждой страницы.
                        PageStack(target: pageKey, animated: true) { key, active in
                            AnyView(page(key)
                                .environment(\.pageActive, active)
                                .environment(\.dsTint, pageTint)
                                .environment(\.moduleControls, DSModuleControls.forEnvironment)
                                .dsThemed()
                                .ignoresSafeArea())
                        }
                    } else {
                        // Экономный режим: страница создаётся при открытии, без перехода. Свой `id`:
                        // состояние (лист «Об инструменте», прокрутка) не переезжает между модулями.
                        page(economyKey(showAbout: showAbout, detail: detail))
                            .id(economyKey(showAbout: showAbout, detail: detail))
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.7))
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
                // Панель скрыта: карточка уходит ниже светофоров и кнопки панели, чтобы не лечь под них.
                .padding(EdgeInsets(top: sidebarHidden ? 44 : 10, leading: sidebarHidden ? 10 : 0, bottom: 10, trailing: 10))
            }
            // ⌘0 — на дашборд. Скрытая кнопка, чтобы сочетание работало и при скрытой панели.
            if DS.dashboardInSidebar {
                Button("") { peeked = nil; showAbout = false; showStore = false; showDashboard = true }
                    .keyboardShortcut("0", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0)
            }
        }
        .overlay(alignment: .topLeading) { DSSidebarToggle(hidden: $sidebarHidden) }
        .overlay {
            if showWelcome {
                WelcomeScene { finishWelcome() }
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Welcome.replay)) { _ in
            welcomeReplay = true
            withAnimation(.easeInOut(duration: 0.35)) { showWelcome = true }
        }
        .environment(\.dsTint, pageTint)
        .environment(\.moduleControls, DSModuleControls.forEnvironment)
        .ignoresSafeArea()
        .sheet(item: $modules.infoModule) { ModuleInfoSheet(module: $0).dsThemed() }
        .sheet(isPresented: $whatsNew.isShown) { WhatsNewSheet().dsThemed() }
        // Настройки модулей — лист поверх окна, а не отдельное окно: настроил, закрыл и сразу в приложении.
        .sheet(isPresented: $modules.settingsShown) { SettingsView().dsThemed() }
        .onAppear {
            whatsNew.showIfUpdated()
            openStartPage()
        }
        // После закрытия любого листа (в том числе alert и confirmationDialog) AppKit отдаёт фокус первой
        // фокусируемой кнопке окна, при включённой клавиатурной навигации это «Версия» в подвале панели, и вокруг
        // неё рисуется рамка. Сбрасываем фокус на следующем витке, но не трогаем поле ввода, если курсор в нём.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            // Второй сброс с задержкой: фокус могут вернуть уже после анимации закрытия листа.
            for delay in [0.0, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if window.firstResponder is NSText { return }
                    window.makeFirstResponder(nil)
                }
            }
        }
        .onChange(of: displayed) {
            DispatchQueue.main.async { built = displayed }
        }
        // Скрытый модуль из списка «Скрытые» открывают поверх дашборда.
        .onChange(of: peeked) { if peeked != nil { showDashboard = false; showStore = false } }
        .onChange(of: showAbout) { if showAbout { showStore = false } }
        .onChange(of: showStore) { if showStore { SatelliteRegistry.shared.refresh() } }
        // Стор просит открыть модуль («Открыть» и «Настроить»): скрытый открывается разовым показом.
        .onReceive(NotificationCenter.default.publisher(for: .storeOpenModule)) { note in
            guard let module = note.object as? Module else { return }
            if modules.isHidden(module) {
                peeked = module
            } else {
                selection = module
                peeked = nil
            }
            showAbout = false
            showStore = false
            showDashboard = false
        }
        // Модуль удалили (из Стора или из панели): если он открыт, уходим на другой.
        .onReceive(NotificationCenter.default.publisher(for: .moduleRemoved)) { note in
            guard let module = note.object as? Module else { return }
            if peeked == module { peeked = nil }
            guard selection == module, !showStore, !showDashboard, !showAbout else { return }
            if let first = modules.firstInPanel { selection = first } else { showStore = true }
        }
        .modifier(StoreRemovalAlert())
        // Минимальный размер окна задаёт `WindowMinSize`: `.frame(minWidth:)` на корне заставлял
        // NSHostingView перемерять всё дерево при каждом изменении.
        .background(WindowMinSize(width: 840, height: 540))
        .onChange(of: modules.hidden) {
            if let resolved = modules.resolve(selection), resolved != selection { selection = resolved }
            // Скрыли последний установленный модуль: открывать больше нечего, идём в Стор.
            if modules.resolve(selection) == nil, !showAbout { showStore = true }
            // Разовый показ имеет смысл только пока модуль скрыт: вернули в панель — сбрасываем.
            if let peeked, !modules.isHidden(peeked) { self.peeked = nil }
        }
    }

    /// Приветствие закончено (или пропущено): запоминаем и открываем Стор.
    private func finishWelcome() {
        if welcomeReplay {
            welcomeReplay = false
            withAnimation(.easeInOut(duration: 0.35)) { showWelcome = false }
            return
        }
        Welcome.markSeen()
        peeked = nil
        showAbout = false
        showDashboard = false
        showStore = true
        withAnimation(.easeInOut(duration: 0.35)) { showWelcome = false }
    }

    /// Стартовая страница: последний выбранный модуль, если он установлен; иначе первый установленный;
    /// если установленных нет — Стор. Дашборд и открытие Стора флагом запуска не трогаем.
    private func openStartPage() {
        guard !showStore, !showDashboard, !modules.isInPanel(selection) else { return }
        if let first = modules.firstInPanel {
            selection = first
        } else {
            showStore = true
        }
    }

    private func economyKey(showAbout: Bool, detail: Module?) -> PageKey {
        showAbout ? .about : showStore ? .store : (showDashboard ? .dashboard : (detail.map { .module($0) } ?? .empty))
    }

    @ViewBuilder
    private func page(_ key: PageKey) -> some View {
        switch key {
        case .about:
            AboutView { module in
                if !modules.isHidden(module) {
                    selection = module
                    peeked = nil
                } else {
                    peeked = module
                }
                self.showAbout = false
                showDashboard = false
            }
            .equatable()
        case .dashboard:
            // `.equatable()`: замыкание не сравнивается, и страница пересчитывалась бы при каждой смене
            // страницы, хотя ничего не изменилось. Захваченное состояние (State, AppStorage) — ссылки.
            DashboardPage { module in
                selection = module
                showDashboard = false
            }
            .equatable()
        case .module(let module):
            ModuleDetail(module: module)
        case .store:
            StoreView()
        case .empty:
            NoShownModules()
        }
    }
}

/// В панели нет ни одного модуля: подсказка и быстрый переход в настройки.
struct NoShownModules: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").font(.system(size: 34)).foregroundStyle(.white.opacity(0.4))
            Text("Панель пуста").font(.title3.weight(.semibold))
            Text("Нет модулей в панели — верни нужные в Настройках")
                .foregroundStyle(.white.opacity(0.55))
            DSButton("Открыть настройки", style: .primary) { ModuleManager.shared.settingsShown = true }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardController.onFeaturesChanged = { AccessState.shared.refresh() }
        MicGuardMigration.run()
        DockMode.start()
        ModuleManager.shared.startEnabled()
        SatelliteRegistry.shared.start()
        // Чтобы вкладка с первого открытия показывала настоящее состояние, а не сохранённые настройки.
        RemoteModules.external(ModuleManager.shared).forEach { $0.1.refresh() }
        Updater.shared.check(quiet: true)
        // Без значка в Dock окно при обычном запуске должно появиться впереди.
        if !DockMode.showsInDock, !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async { DockMode.bringToFront() }
        }

        // Запуск из LaunchAgent при входе в систему передаёт `--background`:
        // окно закрываем сразу, приложение остаётся в Dock. Не через
        // `.defaultLaunchBehavior(.suppressed)` — с ним клик по иконке в Dock
        // окно уже не открывает.
        if CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async {
                NSApp.windows.forEach { $0.close() }
            }
        }
        // Помощник ссылок лежит внутри приложения и внутри утилиты: регистрируем обе копии, чтобы macOS знала их как
        // браузер. Только регистрация, обработчиком их делает человек.
        let links = BrowserLinkHandler.live
        for copy in BrowserHelper.knownCopies() { links.register(copy) }
        links.noteDefault()
        BrowserOrphanOffer.present(links)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            ModuleManager.shared.stopAll()
        }
    }

    /// Окно закрыли — модули (держать микрофон и т.п.) продолжают работать.
    /// Выход только через Cmd+Q / меню.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Точка входа.
@main
struct UtilitumusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @SceneBuilder var body: some Scene {
        Window("Utilitumus", id: "main") {
            MainView().dsThemed()
        }
        // Без заголовка окна: содержимое уходит под светофоры, кнопки модуля — в шапке страницы.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)
        .commands {
            AppCommands()
            CommandGroup(after: .sidebar) {
                SidebarCommand()
            }
        }
        AppMenuBarScene()
    }
}

/// Меню приложения, общее для обоих интерфейсов.
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appInfo) {
            Button("Проверить обновления…") { Updater.shared.check() }
            Button("Что нового…") { WhatsNew.shared.isShown = true }
        }
        // Свой пункт: системный «Settings…» без локализации в Info.plist был бы английским.
        CommandGroup(replacing: .appSettings) {
            SettingsCommand()
        }
    }
}

/// ⌃⌘S — скрыть или показать боковую панель (то же делает кнопка в шапке окна).
private struct SidebarCommand: View {
    @AppStorage(DS.sidebarHiddenKey) private var hidden = false

    var body: some View {
        Button(hidden ? "Показать боковую панель" : "Скрыть боковую панель") {
            hidden.toggle()
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

/// Cmd+, — лист настроек в главном окне; если окно закрыто, сначала открываем его.
struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Настройки…") {
            openWindow(id: "main")
            ModuleManager.shared.settingsShown = true
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
