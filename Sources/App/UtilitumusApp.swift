import SwiftUI
import AppKit

/// Модули в боковой панели. Новый модуль = новый case + экран в `ModuleDetail`.
enum Module: String, CaseIterable, Identifiable {
    case sound, load, stash, fans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Звук"
        case .load: return "Нагрузка"
        case .stash: return "Стеш программ"
        case .fans: return "Вентиляторы"
        }
    }

    var icon: String {
        switch self {
        case .sound: return "mic.fill"
        case .load: return "gauge.with.dots.needle.67percent"
        case .stash: return "square.stack.3d.down.right.fill"
        case .fans: return "fan.fill"
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
            LoadView()
        case .stash:
            StashView()
        }
    }
}

struct MainView: View {
    @AppStorage("SelectedModule") private var selection: Module = .sound

    var body: some View {
        NavigationSplitView {
            List(Module.allCases, selection: Binding(
                get: { selection },
                set: { if let new = $0 { selection = new } }
            )) { module in
                Label(module.title, systemImage: module.icon)
                    .foregroundStyle(module.isReady ? .primary : .secondary)
                    .tag(module)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { UpdateFooter() }
        } detail: {
            ModuleDetail(module: selection)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// Внизу боковой панели: версия и, если вышла новая, кнопка установки.
struct UpdateFooter: View {
    @ObservedObject var updater = Updater.shared

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
        AudioMonitor.shared.start()
        FanController.shared.start()
        LambscapePanel.shared.start()
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
            FanController.shared.restoreAutoBlocking()
            LambscapePanel.shared.stop()
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
        }
    }
}
