import SwiftUI
import AppKit

/// Модули в боковой панели. Новый модуль = новый case + экран в `ModuleDetail`.
enum Module: String, CaseIterable, Identifiable {
    case sound, load, stash, fans, mixer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Звук"
        case .load: return "Нагрузка"
        case .stash: return "Стеш программ"
        case .fans: return "Вентиляторы"
        case .mixer: return "Микшер"
        }
    }

    var icon: String {
        switch self {
        case .sound: return "mic.fill"
        case .load: return "gauge.with.dots.needle.67percent"
        case .stash: return "square.stack.3d.down.right.fill"
        case .fans: return "fan.fill"
        case .mixer: return "slider.vertical.3"
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
        }
    }
}

struct MainView: View {
    @AppStorage("SelectedModule") private var selection: Module = .sound
    @ObservedObject private var modules = ModuleManager.shared
    /// «О проекте» — не модуль, поэтому отдельный флаг; не сохраняем, окно открывается на модуле.
    @State private var showAbout = false

    var body: some View {
        // Выбранный модуль могли выключить: показываем первый из включённых.
        let current = modules.resolve(selection)
        NavigationSplitView {
            List(modules.enabledModules, selection: Binding(
                // На странице «О проекте» выделение в списке снято.
                get: { showAbout ? nil : current },
                set: { if let new = $0 { selection = new; showAbout = false } }
            )) { module in
                Label(module.title, systemImage: module.icon)
                    .foregroundStyle(module.isReady ? .primary : .secondary)
                    .tag(module)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { UpdateFooter(showAbout: $showAbout) }
        } detail: {
            if showAbout {
                AboutView { module in
                    selection = module
                    showAbout = false
                }
            } else if let current {
                ModuleDetail(module: current)
            } else {
                AllModulesOff()
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onChange(of: modules.enabled) {
            if let resolved = modules.resolve(selection), resolved != selection { selection = resolved }
        }
    }
}

/// Все модули выключены: подсказка и быстрый переход в настройки.
struct AllModulesOff: View {
    var body: some View {
        ContentUnavailableView {
            Label("Нет включённых модулей",systemImage: "square.grid.2x2")
        } description: {
            Text("Все модули выключены — включи нужные в Настройках")
        } actions: {
            SettingsLink {
                Text("Открыть настройки")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Внизу боковой панели: «О проекте», версия и, если вышла новая, кнопка установки.
struct UpdateFooter: View {
    @ObservedObject var updater = Updater.shared
    @Binding var showAbout: Bool

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
