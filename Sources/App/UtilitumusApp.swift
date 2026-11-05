import SwiftUI
import AppKit

/// Модули в боковой панели. Новый модуль = новый case + экран в `ModuleDetail`.
enum Module: String, CaseIterable, Identifiable {
    case sound, load, stash, fans, mixer, mouse, browser, voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Звук"
        case .load: return "Нагрузка"
        case .stash: return "Стеш программ"
        case .fans: return "Вентиляторы"
        case .mixer: return "Микшер"
        case .mouse: return "Мышь"
        case .browser: return "Браузер"
        case .voice: return "Голос"
        }
    }

    var icon: String {
        switch self {
        case .sound: return "mic.fill"
        case .load: return "gauge.with.dots.needle.67percent"
        case .stash: return "square.stack.3d.down.right.fill"
        case .fans: return "fan.fill"
        case .mixer: return "slider.vertical.3"
        case .mouse: return "computermouse"
        case .browser: return "globe"
        case .voice: return "waveform"
        }
    }

    /// Цвет плашки значка: у каждого модуля свой, как в Системных настройках.
    /// Системные цвета адаптируются к светлой и тёмной теме.
    var tint: Color {
        switch self {
        case .sound: return .blue
        case .load: return .orange
        case .stash: return .purple
        case .fans: return .teal
        case .mixer: return .pink
        case .mouse: return Color(nsColor: .systemGray)
        case .browser: return .indigo
        case .voice: return .green
        }
    }

    /// Одна строка о модуле — для списка в настройках.
    var summary: String {
        switch self {
        case .sound: return "Держит основной микрофон по приоритету, не даёт Bluetooth-наушникам стать входом"
        case .load: return "Куда уходит память, сессии Claude Code, фоновые агенты"
        case .stash: return "Закрывает отмеченные программы перед игрой и возвращает их с окнами на места"
        case .fans: return "Режимы Авто, Константа и По датчику, температура процессора и видеокарты"
        case .mixer: return "Громкость каждого приложения отдельно"
        case .mouse: return "Своё направление прокрутки для мыши и плавная прокрутка колеса"
        case .browser: return "Панель выбора браузера у курсора для каждой ссылки и правила «сайт или приложение — браузер»"
        case .voice: return "Голосовой ввод по горячей клавише: надиктовал — текст вставился туда, где курсор. Всё распознаётся на этом Mac"
        }
    }
}

/// Белый значок на цветной скруглённой плашке — один вид везде, где показан модуль.
struct ModuleIconBadge: View {
    let module: Module
    var size: CGFloat = 22
    @Environment(\.dsTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(theme.badge(module).gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: module.icon)
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

struct ModuleDetail: View {
    let module: Module

    var body: some View {
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
    /// Дашборд — страница по умолчанию при запуске; не сохраняем, как и «О проекте».
    @State private var showDashboard = true
    /// Скрытый модуль, открытый со страницы «О проекте»: показываем один раз,
    /// состояние не меняем, в панели его по-прежнему нет.
    @State private var peeked: Module?
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
        let onDashboard = showDashboard && !showAbout
        let detail = displayed == nil ? nil : (built ?? displayed)
        let pageKey: PageKey = showAbout ? .about : (showDashboard ? .dashboard : (displayed.map { .module($0) } ?? .empty))
        ZStack {
            DSBackground(module: tintModule, neutral: onDashboard)
            HStack(spacing: 0) {
                if !sidebarHidden {
                    DSSidebar(current: current, showDashboard: $showDashboard, showAbout: $showAbout,
                              peeked: $peeked, selection: $selection)
                        .frame(width: DS.sidebarWidth)
                        .background(theme.sidebar)
                }
                Group {
                    if fast {
                        // Живой кэш: каждая страница в своём NSHostingView, скрытые сняты с иерархии
                        // (не считаются и не влияют на размер окна). Окружение через границу хостинга не
                        // проходит, поэтому тема и акцент задаются на корне каждой страницы.
                        PageStack(target: pageKey, animated: true) { key, active in
                            AnyView(page(key)
                                .environment(\.pageActive, active)
                                .environment(\.dsTint, theme.accent(tintModule))
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
            Button("") { peeked = nil; showAbout = false; showDashboard = true }
                .keyboardShortcut("0", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        }
        .overlay(alignment: .topLeading) { DSSidebarToggle(hidden: $sidebarHidden) }
        .environment(\.dsTint, theme.accent(tintModule))
        .ignoresSafeArea()
        .sheet(item: $modules.infoModule) { ModuleInfoSheet(module: $0).dsThemed() }
        .sheet(isPresented: $whatsNew.isShown) { WhatsNewSheet().dsThemed() }
        // Настройки модулей — лист поверх окна, а не отдельное окно: настроил, закрыл и сразу в приложении.
        .sheet(isPresented: $modules.settingsShown) { SettingsView().dsThemed() }
        .onAppear { whatsNew.showIfUpdated() }
        .onChange(of: displayed) {
            DispatchQueue.main.async { built = displayed }
        }
        // Скрытый модуль из списка «Скрытые» открывают поверх дашборда.
        .onChange(of: peeked) { if peeked != nil { showDashboard = false } }
        // Минимальный размер окна задаёт `WindowMinSize`: `.frame(minWidth:)` на корне заставлял
        // NSHostingView перемерять всё дерево при каждом изменении.
        .background(WindowMinSize(width: 840, height: 540))
        .onChange(of: modules.hidden) {
            if let resolved = modules.resolve(selection), resolved != selection { selection = resolved }
            // Разовый показ имеет смысл только пока модуль скрыт: вернули в панель — сбрасываем.
            if let peeked, !modules.isHidden(peeked) { self.peeked = nil }
        }
    }

    private func economyKey(showAbout: Bool, detail: Module?) -> PageKey {
        showAbout ? .about : (showDashboard ? .dashboard : (detail.map { .module($0) } ?? .empty))
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
        MicGuardMigration.run()
        DockMode.start()
        ModuleManager.shared.startEnabled()
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
        // Помощник ссылок лежит внутри приложения: регистрируем, чтобы macOS знала его как браузер
        // (после обновления путь тот же, но регистрация освежается).
        LSRegisterURL(BrowserHelper.appURL as CFURL, true)
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

/// Точка входа. Стиль окна задаётся сценой `App` и на лету не меняется, поэтому интерфейс
/// выбирается при запуске (`UIStyle.launched`): запускаем одно из двух приложений-сцен.
/// Смену в настройках применяет перезапуск.
@main
enum Launcher {
    @MainActor
    static func main() {
        switch UIStyle.launched {
        case .new: UtilitumusApp.main()
        case .classic: ClassicApp.main()
        }
    }
}

/// Новый интерфейс.
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
