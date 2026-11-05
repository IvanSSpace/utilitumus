import SwiftUI
import AppKit

/// «Показывать в Dock»: выключено — приложение живёт только в меню-баре (`.accessory`).
/// Применяется сразу; общее для обоих интерфейсов.
@MainActor
enum DockMode {
    static let storageKey = "ShowInDock"

    /// По умолчанию показываем, как и раньше.
    static var showsInDock: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: storageKey) == nil || defaults.bool(forKey: storageKey)
    }

    private static var observer: NSObjectProtocol?

    /// Запуск: выставить политику и следить за переключателем в настройках.
    static func start() {
        apply()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { apply() } }
    }

    static func apply() {
        let wanted: NSApplication.ActivationPolicy = showsInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // После смены политики macOS отдаёт фокус другому приложению: возвращаем окну.
        NSApp.activate()
    }

    /// Окно из меню-бара: вперёд поверх остальных, даже если приложение без значка в Dock.
    static func bringToFront() {
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

/// Значок в меню-баре: окно, переключатели модулей, быстрые действия, «Что нового», «Выйти».
struct AppMenuBarScene: Scene {
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var satellites = SatelliteRegistry.shared
    @ObservedObject private var fans = FanController.shared
    @ObservedObject private var stash = StashStore.shared
    @ObservedObject private var awake = AwakeController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Utilitumus", systemImage: "slider.horizontal.3") {
            Button("Открыть Utilitumus") { show() }

            Section("Модули") {
                ForEach(modules.order) { module in
                    Toggle(module.title, isOn: Binding(
                        get: { modules.isExternal(module) ? satellites.isEnabled(module) : modules.isOn(module) },
                        set: {
                            if modules.isExternal(module) { satellites.setEnabled(module, $0) } else { modules.setOn(module, $0) }
                        }))
                }
            }

            // Быстрые действия ведут встроенные контроллеры: пока модуль у утилиты, их трогать нельзя.
            if modules.runsBuiltIn(.fans) {
                Section("Вентиляторы") {
                    Toggle("Полная мощность", isOn: $fans.fullPower)
                    Button("Все в режим «Авто»") { fans.setAllAuto() }
                }
            }

            if modules.runsBuiltIn(.awake) {
                Toggle("Не спать", isOn: Binding(
                    get: { awake.isActive }, set: { $0 ? awake.activate() : awake.deactivate() }))
            }

            if modules.runsBuiltIn(.stash) {
                Section("Стеш программ") {
                    Button("Спрятать выбранные") {
                        Task {
                            stash.refresh()
                            await stash.stashSelected()
                        }
                    }
                    Button("Вернуть\(stash.stashed.isEmpty ? "" : " (\(stash.stashed.count))")") {
                        Task { await stash.restore() }
                    }
                    .disabled(stash.stashed.isEmpty)
                }
            }

            Divider()
            Button("Что нового…") {
                show()
                WhatsNew.shared.isShown = true
            }
            Button("Выйти из Utilitumus") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func show() {
        openWindow(id: "main")
        DockMode.bringToFront()
    }
}

/// Настройка «Показывать в Dock».
struct DockSection: View {
    @AppStorage(DockMode.storageKey) private var showInDock = true

    var body: some View {
        DSSection("Приложение") {
            DSRow(icon: "dock.rectangle", title: "Показывать в Dock",
                  subtitle: "Выключено — Utilitumus живёт в меню-баре, окно открывается оттуда") {
                DSToggle("Показывать в Dock", isOn: $showInDock)
            }
        }
    }
}
