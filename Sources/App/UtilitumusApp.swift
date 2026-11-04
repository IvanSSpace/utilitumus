import SwiftUI
import AppKit

/// Модули в боковой панели. Новый модуль = новый case + экран в `ModuleDetail`.
enum Module: String, CaseIterable, Identifiable {
    case sound, load, stash, fans, mixer, mouse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Звук"
        case .load: return "Нагрузка"
        case .stash: return "Стеш программ"
        case .fans: return "Вентиляторы"
        case .mixer: return "Микшер"
        case .mouse: return "Мышь"
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
        }
    }

    var isReady: Bool { true }

    /// Что модуль будет делать — показывается на заглушке, пока он не готов.
    var plannedSummary: String {
        switch self {
        case .sound: return ""
        case .load: return ""
        case .stash: return ""
        case .fans: return ""
        case .mixer: return ""
        case .mouse: return ""
        }
    }
}

/// Белый значок на цветной скруглённой плашке — один вид везде, где показан модуль.
struct ModuleIconBadge: View {
    let module: Module
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(module.tint.gradient)
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
        switch module {
        case .sound:
            SoundView()
        case .fans:
            FansView()
        case .load:
            LoadScreen()
        case .stash:
            StashView()
        case .mixer:
            MixerView()
        case .mouse:
            MouseView()
        }
    }
}

struct MainView: View {
    @AppStorage("SelectedModule") private var selection: Module = .sound
    @ObservedObject private var modules = ModuleManager.shared
    @Environment(\.openSettings) private var openSettings
    /// «О проекте» — не модуль, поэтому отдельный флаг; не сохраняем, окно открывается на модуле.
    @State private var showAbout = false
    /// Скрытый модуль, открытый со страницы «О проекте»: показываем один раз,
    /// состояние не меняем, в панели его по-прежнему нет.
    @State private var peeked: Module?

    var body: some View {
        // Выбранный модуль могли скрыть или выключить: показываем первый из показанных.
        let current = modules.resolve(selection)
        let displayed = peeked ?? current
        NavigationSplitView {
            List(selection: Binding(
                // На странице «О проекте» и при разовом показе скрытого выделение снято.
                get: { showAbout || peeked != nil ? nil : current },
                set: { if let new = $0 { selection = new; peeked = nil; showAbout = false } }
            )) {
                ForEach(modules.shownModules) { module in
                    Label {
                        Text(module.title)
                    } icon: {
                        ModuleIconBadge(module: module, size: 20)
                    }
                        .foregroundStyle(module.isReady ? .primary : .secondary)
                        .tag(module)
                        .contextMenu {
                            Button("Скрыть из панели") { modules.setState(module, .hidden) }
                            Button("Выключить модуль") { modules.setState(module, .disabled) }
                            Divider()
                            Button("Настроить модули…") { openSettings() }
                        }
                }
                .onMove { modules.moveShown(from: $0, to: $1) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { UpdateFooter(showAbout: $showAbout, peeked: $peeked) }
        } detail: {
            if showAbout {
                AboutView { module in
                    if modules.state(of: module) == .shown {
                        selection = module
                        peeked = nil
                    } else {
                        peeked = module
                    }
                    showAbout = false
                }
            } else if let displayed {
                ModuleDetail(module: displayed)
            } else {
                NoShownModules()
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onChange(of: modules.states) {
            if let resolved = modules.resolve(selection), resolved != selection { selection = resolved }
            // Разовый показ имеет смысл только пока модуль скрыт: выключили или показали — сбрасываем.
            if let peeked, modules.state(of: peeked) != .hidden { self.peeked = nil }
        }
    }
}

/// В панели нет ни одного модуля: подсказка и быстрый переход в настройки.
struct NoShownModules: View {
    var body: some View {
        ContentUnavailableView {
            Label("Панель пуста", systemImage: "square.grid.2x2")
        } description: {
            Text("Нет модулей в панели — верни нужные в Настройках")
        } actions: {
            SettingsLink {
                Text("Открыть настройки")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Внизу боковой панели: скрытые модули, «О проекте», версия и, если вышла новая, кнопка установки.
struct UpdateFooter: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject private var modules = ModuleManager.shared
    @Binding var showAbout: Bool
    @Binding var peeked: Module?
    /// Свёрнутость списка помним между запусками: скрытые открывают редко, но привычка остаётся.
    @AppStorage("HiddenModulesExpanded") private var hiddenExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updater.state {
            case let .available(version, _, _):
                Button {
                    updater.install()
                } label: {
                    Label("Обновить до \(version)", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Устанавливаю…").font(.caption)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            case .upToDate:
                Text("Обновлений нет")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            hiddenSection
            // Порядок, скрытие и выключение модулей — в Настройках; без этой строки туда попадали только через Cmd+, или контекстное меню.
            SettingsLink {
                Label("Настроить модули", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.primary)
            Button {
                showAbout = true
            } label: {
                Label("О проекте", systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(showAbout ? Color.accentColor : .primary)
            HStack {
                Text("Версия \(updater.currentVersion)")
                Spacer()
                Button {
                    updater.check()
                } label: {
                    if updater.state == .checking {
                        ProgressView().controlSize(.mini)
                    } else if updater.state == .upToDate {
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderless)
                .help(updater.state == .upToDate ? "Установлена последняя версия" : "Проверить обновления")
                .disabled(updater.state == .checking || updater.state == .installing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

extension UpdateFooter {
    /// «Скрытые · N» над «О проекте»: без скрытых модулей строки нет совсем.
    @ViewBuilder
    var hiddenSection: some View {
        let hidden = modules.hiddenModules
        if !hidden.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { hiddenExpanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    Label("Скрытые · \(hidden.count)", systemImage: "eye.slash")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(hiddenExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)

            if hiddenExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hidden) { module in
                        Button {
                            // Разовый показ: состояние не меняем, выделение в основном списке снимается через peeked.
                            peeked = module
                            showAbout = false
                        } label: {
                            HStack(spacing: 8) {
                                ModuleIconBadge(module: module, size: 18)
                                    .opacity(0.6)
                                Text(module.title)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(peeked == module && !showAbout ? Color.accentColor : .secondary)
                        .contextMenu {
                            Button("Показать в панели") { modules.setState(module, .shown) }
                            Button("Выключить модуль") { modules.setState(module, .disabled) }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MicGuardMigration.run()
        ModuleManager.shared.startEnabled()
        Updater.shared.check(quiet: true)

        // Запуск из LaunchAgent при входе в систему передаёт `--background`:
        // окно закрываем сразу, приложение остаётся в Dock. Не через
        // `.defaultLaunchBehavior(.suppressed)` — с ним клик по иконке в Dock
        // окно уже не открывает.
        if CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async {
                NSApp.windows.forEach { $0.close() }
            }
        }
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

@main
struct UtilitumusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Utilitumus", id: "main") {
            MainView()
        }
        .defaultSize(width: 760, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { Updater.shared.check() }
            }
            // Свой пункт: системный «Settings…» без локализации в Info.plist был бы английским.
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Настройки…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
