import AppKit
import Combine
import SwiftUI

/// Значки модулей в строке меню со стороны центра. Свой значок утилиты рисует она сама (центр лишь сообщает ей
/// о смене настройки по проверенной связи); здесь рисуется значок встроенного модуля. Общее меню центра остаётся.
/// Сторожей и таймеров нет: пересчёт на смену настроек и состава модулей.
@MainActor
final class ModuleMenuIcons: ObservableObject {
    static let shared = ModuleMenuIcons()

    /// Только явные значения.
    @Published private(set) var settings: [Module: Bool] = [:]
    /// Десятый значок не встал: тихая строка на несколько секунд.
    @Published private(set) var limitNotice: String?
    private var items: [Module: MenuBarIconItem] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var started = false
    private let modules: ModuleManager
    private let satellites: SatelliteRegistry
    private let defaults: UserDefaults
    /// Стенд подставляет своё: настоящий значок в строке меню ему не нужен.
    var makeItem: (Module) -> MenuBarIconItem?
    /// Что уходит утилите. Стенд подставляет запись.
    var tellUtility: (Module, Bool) -> Void

    init(modules: ModuleManager = .shared, satellites: SatelliteRegistry = .shared, defaults: UserDefaults = Kit.defaults) {
        self.modules = modules
        self.satellites = satellites
        self.defaults = defaults
        makeItem = { _ in nil }
        tellUtility = { _, _ in }
        makeItem = { [unowned self] in self.liveItem($0) }
        tellUtility = { [unowned self] module, on in
            // Не ответила: ключ уже записан, при запуске утилита его прочитает.
            Task { try? await self.satellites.environment.commands.setMenuIcon(module.rawValue, on) }
        }
        reload()
    }

    func start() {
        guard !started else { return }
        started = true
        // `didChangeNotification` — только об этом процессе.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
            .store(in: &subscriptions)
        // Утилита сменила значок у себя (меню или окно) и сообщила статус: ключ записан другим процессом.
        satellites.statusPinged
            .sink { [weak self] _ in
                self?.defaults.synchronize()
                self?.reload()
            }
            .store(in: &subscriptions)
        modules.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reconcile() } }
            .store(in: &subscriptions)
        reconcile()
    }

    func isOn(_ module: Module) -> Bool { MenuBarIcon.switchOn(settings[module]) }

    /// Закреплённых сейчас девять: новый значок встать не может, в каком бы окне его ни включали.
    var isFull: Bool {
        settings.filter { $0.value && modules.isInstalled($0.key) }.count >= MenuBarIcon.maxPins
    }

    /// Явный выбор: переключатель значка, «Скрыть значок». `false` остаётся и при закрытом центре.
    func set(_ module: Module, _ on: Bool) {
        if on, !isOn(module), isFull {
            limitNotice = MenuBarIcon.limitNotice
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.limitNotice = nil
            }
            return
        }
        limitNotice = nil
        MenuBarIcon.set(on, module, defaults: defaults)
        changed(module, on)
    }

    /// Открепили, спрятали строку или убрали модуль: настройка снимается, запасной значок утилиты без центра остаётся.
    func clear(_ module: Module) {
        limitNotice = nil
        MenuBarIcon.clear(module, defaults: defaults)
        changed(module, false)
    }

    private func changed(_ module: Module, _ on: Bool) {
        reload()
        // Модуль ведёт утилита: значок рисует она, и ей нужно сказать сейчас. Встроенный рисует центр.
        // Старая утилита такого вызова не знает: значок появится после её обновления, об этом говорит `notice`.
        guard modules.isExternal(module), !satellites.isOutdated(module) else { return }
        // Утилита читает ключ из другого процесса, как только получит вызов.
        defaults.synchronize()
        tellUtility(module, on)
    }

    /// Закреплённые модули, чья утилита значка не нарисует, пока её не обновят.
    var waitingForUpdate: [Module] {
        modules.order.filter { settings[$0] == true && modules.isExternal($0) && satellites.isOutdated($0) }
    }

    /// Тихая строка под плитками и в настройках.
    var notice: String? {
        let waiting = waitingForUpdate.map { "«\($0.title)»" }
        let update = waiting.isEmpty ? nil : waiting.count == 1
            ? "Значок \(waiting[0]) появится после обновления этого модуля"
            : "Значки \(waiting.joined(separator: ", ")) появятся после обновления этих модулей"
        let lines = [limitNotice, update].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func reload() {
        var fresh: [Module: Bool] = [:]
        for module in Module.allCases { if let value = MenuBarIcon.setting(module, defaults: defaults) { fresh[module] = value } }
        if fresh != settings { settings = fresh }
        reconcile()
    }

    /// Кто какие значки должен иметь сейчас.
    func reconcile() {
        let wanted = self.wanted
        for module in Module.allCases {
            if wanted.contains(module), items[module] == nil, let item = makeItem(module) {
                items[module] = item
            } else if !wanted.contains(module), let item = items.removeValue(forKey: module) {
                item.remove()
            }
        }
    }

    /// Значки встроенных модулей, нужные сейчас.
    var wanted: Set<Module> {
        Set(ModuleScope.shown(Module.allCases).filter {
            MenuBarIcon.hubShows(setting: settings[$0], external: modules.isExternal($0), moduleOn: modules.isOn($0))
        })
    }

    /// Модули, чей значок сейчас рисует центр.
    var drawn: Set<Module> { Set(items.keys) }

    private func liveItem(_ module: Module) -> MenuBarIconItem? {
        #if KIT_TEST_DEFAULTS
        return nil
        #else
        MenuBarIconItem(
            module: module,
            content: {
                // Карточка дашборда: та же строка и то же быстрое действие, что и там.
                let state = DashboardLive.snapshot(module)
                let actions = state.actionTitle.map { [LinkQuickAction(title: $0, icon: state.actionIcon, action: Data())] } ?? []
                return .init(status: state.text, actions: actions)
            },
            perform: { _ in
                DashboardLive.perform(module) { confirmation in
                    let confirm = LinkConfirm(title: confirmation.title, message: confirmation.message, button: confirmation.button)
                    if MenuBarIconItem.confirmed(confirm) { confirmation.run() }
                }
            },
            open: { Self.open(module) },
            hide: { [weak self] in self?.set(module, false) })
        #endif
    }

    /// Окно центра вперёд и страница модуля.
    static func open(_ module: Module) {
        MenuBarIcon.requestOpen(module, hub: Bundle.main.bundleURL)
        DockMode.bringToFront()
        HubNavigation.consume()
    }
}

/// Просьба открыть модуль: своя (из значка) или от утилиты через общий домен. Читается при выходе окна вперёд.
@MainActor
enum HubNavigation {
    static func consume() {
        guard let module = MenuBarIcon.takeOpenRequest() else { return }
        NotificationCenter.default.post(name: .storeOpenModule, object: module)
    }
}

/// Тихая строка о значках: упёрлись в предел, значок ждёт обновления утилиты. Пусто, пока говорить не о чем.
struct MenuIconNotice: View {
    @ObservedObject private var icons = ModuleMenuIcons.shared
    @ObservedObject private var satellites = SatelliteRegistry.shared

    var body: some View {
        if let notice = icons.notice {
            Text(notice)
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// «Значки в строке меню»: у каждого модуля свой переключатель.
struct MenuIconsSection: View {
    @ObservedObject private var icons = ModuleMenuIcons.shared
    @ObservedObject private var modules = ModuleManager.shared

    var body: some View {
        if !modules.order.isEmpty {
            DSSection("Значки в строке меню") {
                ForEach(modules.order) { module in
                    DSRow(icon: module.icon, title: module.title, iconTint: module.tint) {
                        DSToggle("Значок «\(module.title)» в строке меню",
                                 isOn: Binding(get: { icons.isOn(module) }, set: { icons.set(module, $0) }))
                            .disabled(icons.isFull && !icons.isOn(module))
                    }
                }
                MenuIconNotice()
            }
        }
    }
}
