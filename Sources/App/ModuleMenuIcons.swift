import AppKit
import Combine
import SwiftUI

/// Настройка значков модулей в строке меню со стороны центра. Значок рисует сама утилита, а центр лишь сообщает ей
/// о смене настройки по проверенной связи. У модуля без утилиты значка нет. Общее меню центра остаётся.
/// Сторожей и таймеров нет: пересчёт на смену настроек.
@MainActor
final class ModuleMenuIcons: ObservableObject {
    static let shared = ModuleMenuIcons()

    /// Только явные значения.
    @Published private(set) var settings: [Module: Bool] = [:]
    /// Десятый значок не встал: тихая строка на несколько секунд.
    @Published private(set) var limitNotice: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var started = false
    private let modules: ModuleManager
    private let satellites: SatelliteRegistry
    private let defaults: UserDefaults
    /// Что уходит утилите. Стенд подставляет запись.
    var tellUtility: (Module, Bool) -> Void

    init(modules: ModuleManager = .shared, satellites: SatelliteRegistry = .shared, defaults: UserDefaults = Kit.defaults) {
        self.modules = modules
        self.satellites = satellites
        self.defaults = defaults
        tellUtility = { _, _ in }
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

    /// Открепили, спрятали строку или убрали модуль: настройка снимается, значка утилиты больше нет.
    func clear(_ module: Module) {
        limitNotice = nil
        MenuBarIcon.clear(module, defaults: defaults)
        changed(module, false)
    }

    private func changed(_ module: Module, _ on: Bool) {
        reload()
        // Значок рисует утилита, и ей нужно сказать сейчас. Утилиты нет: новая прочитает ключ при запуске.
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
    }
}

/// Просьба открыть модуль от утилиты через общий домен. Читается при выходе окна вперёд.
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
