import Foundation

/// Как запустить и остановить фоновую часть модуля. Оба вызова идемпотентны.
struct ModuleHooks {
    let start: @MainActor () -> Void
    let stop: @MainActor () -> Void
}

/// Какие модули включены, и запуск/остановка их фоновых частей. Состояние
/// хранится в UserDefaults, по умолчанию включено всё.
@MainActor
final class ModuleManager: ObservableObject {
    @Published private(set) var enabled: Set<Module>

    private let defaults: UserDefaults
    private let hooks: (Module) -> ModuleHooks
    /// Модули, у которых сейчас вызван start без парного stop.
    private var running: Set<Module> = []
    /// Пока приложение не запустило модули (или уже гасит их), переключатели
    /// только меняют настройку и ничего не стартуют.
    private var isActive = false

    init(defaults: UserDefaults = .standard, hooks: @escaping (Module) -> ModuleHooks) {
        self.defaults = defaults
        self.hooks = hooks
        enabled = Set(Module.allCases.filter { Self.stored($0, in: defaults) })
    }

    private static func key(_ module: Module) -> String { "ModuleEnabled.\(module.rawValue)" }

    private static func stored(_ module: Module, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key(module)) as? Bool ?? true
    }

    /// Включённые модули в порядке боковой панели.
    var enabledModules: [Module] { Module.allCases.filter { enabled.contains($0) } }

    func isEnabled(_ module: Module) -> Bool { enabled.contains(module) }

    func setEnabled(_ module: Module, _ on: Bool) {
        defaults.set(on, forKey: Self.key(module))
        if on { enabled.insert(module) } else { enabled.remove(module) }
        if isActive { sync(module) }
    }

    /// Выбранный модуль, если он включён; иначе первый включённый; иначе nil.
    func resolve(_ selection: Module) -> Module? {
        enabled.contains(selection) ? selection : enabledModules.first
    }

    /// Запуск приложения: стартуют только включённые.
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
