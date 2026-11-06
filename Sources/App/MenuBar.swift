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
            // Контроллер создаётся только внутри вида, который есть, пока модуль встроенный.
            if modules.runsBuiltIn(.fans) { FansMenuSection() }

            AwakeMenuItem()

            if modules.runsBuiltIn(.stash) { StashMenuSection() }

            // Ведомые модули: быстрые действия приходят в статусе утилиты.
            ForEach(MenuQuickActions.sections(order: modules.order, modules: modules, entries: satellites.entries), id: \.module) { section in
                Section(section.module.title) {
                    ForEach(Array(section.actions.enumerated()), id: \.offset) { _, quick in
                        Button(quick.title) { MenuQuickActions.run(quick, module: section.module) }
                    }
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

/// Быстрые действия ведомых модулей в меню-баре: секция на модуль, кнопка на действие из статуса.
@MainActor
enum MenuQuickActions {
    struct MenuSection: Equatable {
        let module: Module
        let actions: [LinkQuickAction]
    }

    /// Секции в порядке модулей. Выключенного, неотвечающего и без действий в меню нет, как и у встроенного.
    /// Модуль, чьё меню рисует его модель (`menuUsesQuickActions == false`), пропускается.
    static func sections(order: [Module], modules: ModuleManager, entries: [Module: SatelliteRegistry.Entry]) -> [MenuSection] {
        order.compactMap { module in
            guard modules.isExternal(module), let status = entries[module]?.status, status.enabled,
                  !status.quickActions.isEmpty,
                  RemoteModules.model(module)?.menuUsesQuickActions ?? true else { return nil }
            return MenuSection(module: module, actions: status.quickActions)
        }
    }

    /// Действие с вопросом в меню спрашивает окно: в меню-баре своего диалога нет.
    static func run(_ quick: LinkQuickAction, module: Module) {
        guard let confirm = quick.confirm else { return SatelliteRegistry.shared.perform(quick, module: module) }
        let alert = NSAlert()
        alert.messageText = confirm.title
        alert.informativeText = confirm.message
        alert.addButton(withTitle: confirm.button)
        alert.addButton(withTitle: "Отмена")
        DockMode.bringToFront()
        if alert.runModal() == .alertFirstButtonReturn { SatelliteRegistry.shared.perform(quick, module: module) }
    }
}

/// Секции встроенных «Вентиляторов» и «Стеша»: вид существует, только пока модуль встроенный и включён.
private struct FansMenuSection: View {
    @ObservedObject private var fans = FanController.shared

    var body: some View {
        Section("Вентиляторы") {
            Toggle("Полная мощность", isOn: $fans.fullPower)
            Button("Все в режим «Авто»") { fans.setAllAuto() }
        }
    }
}

private struct StashMenuSection: View {
    @ObservedObject private var stash = StashStore.shared

    var body: some View {
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
}

/// Пункт «Не спать» в меню-баре: тот же переключатель, кто бы ни вёл модуль. Выключенного модуля в меню нет.
struct AwakeMenuItem: View {
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var satellites = SatelliteRegistry.shared
    @ObservedObject private var remote = RemoteAwakeModel.shared

    var body: some View {
        if modules.isExternal(.awake) {
            switch remote.screen(satellites) {
            case .module: AwakeMenuToggle(model: remote)
            case .notResponding: Button("Не спать: не отвечает") {}.disabled(true)
            case .off: EmptyView()
            }
        } else if modules.runsBuiltIn(.awake) {
            AwakeMenuToggle(model: AwakeController.shared)
        }
    }
}

struct AwakeMenuToggle<Model: AwakeModel>: View {
    @ObservedObject var model: Model

    var isOn: Binding<Bool> {
        Binding(get: { model.isActive }, set: { if $0 != model.isActive { model.toggle() } })
    }

    var body: some View {
        // Как кнопка на экране модуля.
        Toggle("Не спать", isOn: isOn).disabled(!model.canStart && !model.isActive)
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
