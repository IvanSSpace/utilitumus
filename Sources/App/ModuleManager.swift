import Foundation

/// Как запустить и остановить фоновую часть модуля. Оба вызова идемпотентны.
struct ModuleHooks {
    let start: @MainActor () -> Void
    let stop: @MainActor () -> Void
}

/// Состояние модуля. «Скрыт» и «Выключен» — разные вещи: скрытый не виден в
/// боковой панели, но работает; выключенный остановлен полностью.
enum ModuleState: String, CaseIterable, Identifiable {
    case shown, hidden, disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shown: return "Показан"
        case .hidden: return "Скрыт (работает в фоне)"
        case .disabled: return "Выключен"
        }
    }
}

/// Порядок и состояние модулей, запуск/остановка их фоновых частей. Всё
/// хранится в UserDefaults, по умолчанию все показаны в порядке `Module.allCases`.
@MainActor
final class ModuleManager: ObservableObject {
    /// Все модули в порядке боковой панели и настроек, включая скрытые и выключенные.
    @Published private(set) var order: [Module]
    @Published private(set) var states: [Module: ModuleState]

    private let defaults: UserDefaults
    private let hooks: (Module) -> ModuleHooks
    /// Модули, у которых сейчас вызван start без парного stop.
    private var running: Set<Module> = []
    /// Пока приложение не запустило модули (или уже гасит их), смена состояния
    /// только меняет настройку и ничего не стартует.
    private var isActive = false

    private static let orderKey = "ModuleOrder"

    init(defaults: UserDefaults = .standard, hooks: @escaping (Module) -> ModuleHooks) {
        self.defaults = defaults
        self.hooks = hooks
        order = Self.normalizedOrder(defaults.stringArray(forKey: Self.orderKey) ?? [])
        states = Dictionary(uniqueKeysWithValues: Module.allCases.map { ($0, Self.stored($0, in: defaults)) })
    }

    private static func stateKey(_ module: Module) -> String { "ModuleState.\(module.rawValue)" }
    /// Прежний флаг «включён» — читаем один раз для миграции.
    private static func legacyKey(_ module: Module) -> String { "ModuleEnabled.\(module.rawValue)" }

    private static func stored(_ module: Module, in defaults: UserDefaults) -> ModuleState {
        if let raw = defaults.string(forKey: stateKey(module)), let state = ModuleState(rawValue: raw) {
            return state
        }
        // Раньше модуль был только включён или выключен: выключенный остаётся выключенным.
        if defaults.object(forKey: legacyKey(module)) as? Bool == false { return .disabled }
        return .shown
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

    func state(of module: Module) -> ModuleState { states[module] ?? .shown }

    /// Модули, которые видны в боковой панели, в нужном порядке.
    var shownModules: [Module] { order.filter { state(of: $0) == .shown } }

    /// Скрытые модули в порядке панели — для списка «Скрытые» внизу боковой панели.
    var hiddenModules: [Module] { order.filter { state(of: $0) == .hidden } }

    func setState(_ module: Module, _ state: ModuleState) {
        defaults.set(state.rawValue, forKey: Self.stateKey(module))
        states[module] = state
        if isActive { sync(module) }
    }

    /// Перетаскивание в настройках: там виден весь список.
    func move(from source: IndexSet, to destination: Int) {
        var new = order
        new.moveItems(from: source, to: destination)
        setOrder(new)
    }

    /// Перетаскивание в боковой панели: там только показанные. Скрытые и выключенные
    /// остаются на своих местах, переставляются лишь места, занятые показанными.
    func moveShown(from source: IndexSet, to destination: Int) {
        var shown = shownModules
        shown.moveItems(from: source, to: destination)
        var new = order
        let slots = new.indices.filter { state(of: new[$0]) == .shown }
        for (slot, module) in zip(slots, shown) { new[slot] = module }
        setOrder(new)
    }

    /// Порядок по умолчанию и все модули показаны (выключенные снова запускаются).
    func resetAll() {
        defaults.removeObject(forKey: Self.orderKey)
        order = Module.allCases
        for module in Module.allCases { setState(module, .shown) }
    }

    private func setOrder(_ new: [Module]) {
        guard new != order else { return }
        order = new
        defaults.set(new.map(\.rawValue), forKey: Self.orderKey)
    }

    /// Выбранный модуль, если он показан; иначе первый показанный; иначе nil.
    func resolve(_ selection: Module) -> Module? {
        state(of: selection) == .shown ? selection : shownModules.first
    }

    /// Запуск приложения: стартуют все, кроме выключенных (скрытые работают).
    func startEnabled() {
        isActive = true
        Module.allCases.forEach(sync)
    }

    /// Выход из приложения: остановить всё, что запущено.
    func stopAll() {
        isActive = false
        for module in Module.allCases where running.contains(module) {
            running.remove(module)
            hooks(module).stop()
        }
    }

    /// Работает всё, что не выключено: скрытие на работу не влияет.
    private func sync(_ module: Module) {
        let wanted = state(of: module) != .disabled
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
