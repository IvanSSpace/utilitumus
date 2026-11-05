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
    /// Значок вкладки в боковой панели и секции дашборда.
    let icon: String
    /// Показывать ли у модулей категории в панели вторую строку — живой статус.
    let showsStatus: Bool
    /// Средний оттенок гаммы (0…1).
    let hue: Double
    /// Разброс оттенков между соседними модулями категории.
    let spread: Double
    let modules: [Module]

    static let all: [ModuleCategory] = [
        ModuleCategory(id: "background", title: "Фоном",
                       subtitle: "Настроил и забыл — работает само",
                       icon: "moon.zzz.fill", showsStatus: true,
                       hue: 0.55, spread: 0.03, modules: [.sound, .mouse, .fans, .browser, .keyboard]),
        ModuleCategory(id: "handy", title: "Под рукой",
                       subtitle: "Пользуешься каждый день",
                       icon: "hand.point.up.fill", showsStatus: false,
                       hue: 0.80, spread: 0.06, modules: [.stash, .voice, .clipboard, .mixer]),
        ModuleCategory(id: "ai", title: "С ИИ",
                       subtitle: "Когда агенты съедают память",
                       icon: "sparkles", showsStatus: false,
                       hue: 0.11, spread: 0.03, modules: [.load]),
    ]

    /// Оттенок модуля внутри гаммы категории.
    func hue(of module: Module) -> Double {
        guard let index = modules.firstIndex(of: module) else { return hue }
        let value = hue + (Double(index) - Double(modules.count - 1) / 2) * spread
        return value - value.rounded(.down)
    }

    /// Категория и оттенок каждого модуля считаются один раз: их спрашивают из каждого `body`.
    fileprivate static let byModule: [Module: ModuleCategory] = {
        var result: [Module: ModuleCategory] = [:]
        for module in Module.allCases {
            result[module] = all.first { $0.modules.contains(module) } ?? all[all.count - 1]
        }
        return result
    }()

    fileprivate static let hueByModule: [Module: Double] = {
        var result: [Module: Double] = [:]
        for module in Module.allCases { result[module] = (byModule[module] ?? all[all.count - 1]).hue(of: module) }
        return result
    }()
}

extension Module {
    var category: ModuleCategory { ModuleCategory.byModule[self] ?? ModuleCategory.all[ModuleCategory.all.count - 1] }

    /// Оттенок модуля (0…1) из кеша.
    var categoryHue: Double { ModuleCategory.hueByModule[self] ?? category.hue }
}
