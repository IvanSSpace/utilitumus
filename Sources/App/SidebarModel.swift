import Combine
import Foundation

/// Связка раскладки панели с настоящими настройками. Своих копий состояния нет: закреплён тот, у кого
/// `MenuBarIcon.<id>` включён, скрыт тот, кого скрыл `ModuleManager`, порядок — общий порядок `ModuleManager`.
@MainActor
final class SidebarModel {
    static let shared = SidebarModel()

    private let modules: ModuleManager
    private let icons: ModuleMenuIcons
    private var installed: Set<Module>
    private var subscription: AnyCancellable?

    init(modules: ModuleManager = .shared, icons: ModuleMenuIcons = .shared) {
        self.modules = modules
        self.icons = icons
        installed = Set(modules.installedModules)
    }

    /// Следит за составом модулей: убранный теряет закрепление, новый встаёт в конец списка.
    func start() {
        guard subscription == nil else { return }
        subscription = modules.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
    }

    /// Раскладка сейчас. `open` — страница, открытая сейчас, даже если модуль выключили на ней.
    func layout(open: Module? = nil) -> SidebarLayout {
        Self.layout(modules: modules, pins: pins, open: open)
    }

    var pins: Set<Module> { Set(Module.allCases.filter { icons.isOn($0) }) }

    static func layout(modules: ModuleManager, pins: Set<Module>, open: Module?) -> SidebarLayout {
        var present = Set(modules.installedModules)
        if let open { present.insert(open) }
        return SidebarLayout.resolve(order: modules.order, present: present, pins: pins, hidden: modules.hidden)
    }

    func reconcile() {
        let now = Set(modules.installedModules)
        defer { installed = now }
        for module in installed.subtracting(now) {
            // Убрали или выключили: закрепление уходит вместе с модулем, вернётся он в список.
            if icons.isOn(module) { icons.set(module, false) }
        }
        let added = now.subtracting(installed)
        guard !added.isEmpty else { return }
        let moved = modules.order.filter { !added.contains($0) } + modules.order.filter { added.contains($0) }
        modules.applyOrder(moved)
    }

    // MARK: Действия

    /// Применить раскладку, в которой `module` переехал в зону `zone` (после `SidebarLayout.move`).
    /// Закрепление и скрытие идут через те же места, что и раньше: значок — `ModuleMenuIcons.set`, скрытие — `ModuleManager`.
    func apply(_ layout: SidebarLayout, moved module: Module) {
        guard let zone = layout.zone(of: module) else { return }
        switch zone {
        case .pinned:
            modules.setHidden(module, false)
            if !icons.isOn(module) { icons.set(module, true) }
        case .list:
            modules.setHidden(module, false)
            if icons.isOn(module) { icons.set(module, false) }
        case .hidden:
            modules.setHidden(module, true)
            if icons.isOn(module) { icons.set(module, false) }
        }
        modules.applyOrder(layout.mergedOrder(modules.order))
    }

    /// Перенос по просьбе меню или клавиатуры: в конец зоны.
    @discardableResult
    func send(_ module: Module, to zone: SidebarLayout.Zone, open: Module? = nil) -> Bool {
        var current = layout(open: open)
        guard current.move(module, to: zone, at: Int.max) else { return false }
        apply(current, moved: module)
        return true
    }

    @discardableResult
    func nudge(_ module: Module, by delta: Int, open: Module? = nil) -> Bool {
        var current = layout(open: open)
        guard current.nudge(module, by: delta) else { return false }
        modules.applyOrder(current.mergedOrder(modules.order))
        return true
    }
}
