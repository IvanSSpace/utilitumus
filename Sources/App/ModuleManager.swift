import Foundation

/// Как запустить и остановить фоновую часть модуля. Оба вызова идемпотентны.
struct ModuleHooks {
    let start: @MainActor () -> Void
    let stop: @MainActor () -> Void
    /// Выход из приложения. Если не задан, вызывается `stop`; нужен тем, кому при выходе
    /// возвращать нельзя то, что они настроили в системе (модуль «Клавиатура»).
    var quit: (@MainActor () -> Void)? = nil
}

/// Порядок модулей, включён ли каждый и виден ли в боковой панели; запуск/остановка их фоновых частей.
///
/// «Включён» и «в панели» — независимы: выключенный модуль виден (серым) и открывается — на его
/// экране описание и кнопка «Включить»; скрытый может работать в фоне. На новой установке всё
/// выключено: модуль начинает что-то делать, только когда его включили.
@MainActor
final class ModuleManager: ObservableObject {
    /// Все модули в порядке боковой панели и настроек.
    @Published private(set) var order: [Module]
    @Published private(set) var enabled: Set<Module>
    @Published private(set) var hidden: Set<Module>
    /// Открытая страница «Об инструменте» (кнопка (i) или «Подробнее»).
    @Published var infoModule: Module?
    /// Открыт лист «Модули» (настройки) поверх главного окна.
    @Published var settingsShown = false

    private let defaults: UserDefaults
    private let hooks: (Module) -> ModuleHooks
    /// Модули, у которых сейчас вызван start без парного stop.
    private var running: Set<Module> = []
    /// Пока приложение не запустило модули (или уже гасит их), переключение
    /// только меняет настройку и ничего не стартует.
    private var isActive = false

    private static let orderKey = "ModuleOrder"
    private static let migratedKey = "ModulesV2"
    static func onKey(_ module: Module) -> String { "ModuleOn.\(module.rawValue)" }
    private static func hiddenKey(_ module: Module) -> String { "ModuleHidden.\(module.rawValue)" }

    init(defaults: UserDefaults = .standard, hooks: @escaping (Module) -> ModuleHooks) {
        self.defaults = defaults
        self.hooks = hooks
        if defaults.object(forKey: Self.migratedKey) == nil {
            Self.migrate(defaults)
            defaults.set(true, forKey: Self.migratedKey)
        }
        order = Self.normalizedOrder(defaults.stringArray(forKey: Self.orderKey) ?? [])
        enabled = Set(Module.allCases.filter { defaults.bool(forKey: Self.onKey($0)) })
        hidden = Set(Module.allCases.filter { defaults.bool(forKey: Self.hiddenKey($0)) })
    }

    // MARK: Переход со старого формата

    /// Признаки того, что приложение уже запускали до этой версии.
    private static let existingInstallPrefixes = [
        "ModuleOrder", "ModuleState.", "ModuleEnabled.", "SelectedModule", "FanConfigs", "MicGuard",
        "UtilitumusKnown", "UtilitumusPrimary", "Stash", "Mixer", "GameMode", "LoadTab", "LoadViewMode",
    ]

    /// Раньше модуль по умолчанию работал, а состояние было одно из трёх: показан / скрыт (работает) /
    /// выключен (и не виден). У тех, кто уже пользуется, всё остаётся как было — пишем это явно.
    /// Новая установка ничего не пишет: все модули выключены и видны. Модули, добавленные в будущих
    /// версиях, без ключа — тоже выключены, пока их не включат.
    private static func migrate(_ defaults: UserDefaults) {
        let keys = defaults.dictionaryRepresentation().keys
        guard keys.contains(where: { key in existingInstallPrefixes.contains { key.hasPrefix($0) } }) else { return }
        for module in Module.allCases {
            let old: String
            if let raw = defaults.string(forKey: "ModuleState.\(module.rawValue)") {
                old = raw
            } else if defaults.object(forKey: "ModuleEnabled.\(module.rawValue)") as? Bool == false {
                old = "disabled"
            } else {
                old = "shown"
            }
            defaults.set(old != "disabled", forKey: onKey(module))
            defaults.set(old != "shown", forKey: hiddenKey(module))
        }
    }

    /// Сохранённый порядок: неизвестные id (модуль убрали) и повторы отбрасываются,
    /// модули, которых в нём нет (новые версии), добавляются в конец.
    static func normalizedOrder(_ stored: [String]) -> [Module] {
        var result: [Module] = []
        for raw in stored {
            if let module = Module(rawValue: raw), !result.contains(module) { result.append(module) }
        }
        return result + Module.allCases.filter { !result.contains($0) }
    }

    // MARK: Состояние

    func isOn(_ module: Module) -> Bool { enabled.contains(module) }
    func isHidden(_ module: Module) -> Bool { hidden.contains(module) }

    /// Модули в боковой панели (включённые и выключенные), в нужном порядке.
    var shownModules: [Module] { order.filter { !hidden.contains($0) } }

    /// Скрытые модули в порядке панели — для списка «Скрытые» внизу боковой панели.
    var hiddenModules: [Module] { order.filter { hidden.contains($0) } }

    func setOn(_ module: Module, _ on: Bool) {
        defaults.set(on, forKey: Self.onKey(module))
        if on { enabled.insert(module) } else { enabled.remove(module) }
        if isActive { sync(module) }
    }

    func setHidden(_ module: Module, _ isHidden: Bool) {
        defaults.set(isHidden, forKey: Self.hiddenKey(module))
        if isHidden { hidden.insert(module) } else { hidden.remove(module) }
    }

    /// Перетаскивание в боковой панели: там только видимые. Скрытые остаются на своих местах,
    /// переставляются лишь места, занятые видимыми.
    func moveShown(from source: IndexSet, to destination: Int) {
        var shown = shownModules
        shown.moveItems(from: source, to: destination)
        var new = order
        let slots = new.indices.filter { !hidden.contains(new[$0]) }
        for (slot, module) in zip(slots, shown) { new[slot] = module }
        setOrder(new)
    }

    /// Порядок по умолчанию и все модули в панели. Включённость не трогаем.
    func resetAll() {
        defaults.removeObject(forKey: Self.orderKey)
        order = Module.allCases
        for module in Module.allCases { setHidden(module, false) }
    }

    private func setOrder(_ new: [Module]) {
        guard new != order else { return }
        order = new
        defaults.set(new.map(\.rawValue), forKey: Self.orderKey)
    }

    /// Выбранный модуль, если он в панели; иначе первый в панели; иначе nil.
    func resolve(_ selection: Module) -> Module? {
        hidden.contains(selection) ? shownModules.first : selection
    }

    /// Запуск приложения: стартуют включённые (скрытые тоже работают).
    func startEnabled() {
        isActive = true
        Module.allCases.forEach(sync)
    }

    /// Выход из приложения: остановить всё, что запущено.
    func stopAll() {
        isActive = false
        for module in Module.allCases where running.contains(module) {
            running.remove(module)
            let hook = hooks(module)
            (hook.quit ?? hook.stop)()
        }
    }

    private func sync(_ module: Module) {
        let wanted = enabled.contains(module)
        guard wanted != running.contains(module) else { return }
        if wanted {
            running.insert(module)
            hooks(module).start()
        } else {
            running.remove(module)
            hooks(module).stop()
        }
    }
}

private extension Array {
    /// Как `move(fromOffsets:toOffset:)` из SwiftUI, но без зависимости от него.
    mutating func moveItems(from source: IndexSet, to destination: Int) {
        let moving = source.map { self[$0] }
        let shift = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { remove(at: index) }
        insert(contentsOf: moving, at: destination - shift)
    }
}
