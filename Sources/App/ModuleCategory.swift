import Foundation

/// Группы модулей в боковой панели и в «О проекте».
///
/// Вся схема — таблица `ModuleCategory.all`: порядок групп, названия, подписи, цвет и состав.
/// Поменять разбиение = поправить эту таблицу, больше нигде ничего не менять.
/// Оттенок модуля считается сам: соседи в гамме категории с шагом `spread`, по порядку в `modules`.
/// Модуль, которого нет в таблице, попадает в последнюю группу.
struct ModuleCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    /// Средний оттенок гаммы (0…1).
    let hue: Double
    /// Разброс оттенков между соседними модулями категории.
    let spread: Double
    let modules: [Module]

    static let all: [ModuleCategory] = [
        ModuleCategory(id: "fixes", title: "Исправления MacBook",
                       subtitle: "То, что в macOS должно быть, но его нет",
                       hue: 0.54, spread: 0.055, modules: [.sound, .fans, .mixer, .mouse]),
        ModuleCategory(id: "tricks", title: "Утилиты с фишками",
                       subtitle: "Мелочи, которые экономят время каждый день",
                       hue: 0.81, spread: 0.08, modules: [.stash, .browser, .voice]),
        ModuleCategory(id: "ai", title: "Для работы с ИИ",
                       subtitle: "Когда агенты съедают память",
                       hue: 0.08, spread: 0.03, modules: [.load]),
    ]

    /// Оттенок модуля внутри гаммы категории.
    func hue(of module: Module) -> Double {
        guard let index = modules.firstIndex(of: module) else { return hue }
        let value = hue + (Double(index) - Double(modules.count - 1) / 2) * spread
        return value - value.rounded(.down)
    }
}

extension Module {
    var category: ModuleCategory {
        ModuleCategory.all.first { $0.modules.contains(self) } ?? ModuleCategory.all[ModuleCategory.all.count - 1]
    }
}
