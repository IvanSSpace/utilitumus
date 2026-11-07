import Foundation

extension Notification.Name {
    /// Модуль удалили (из Стора, из панели или саму утилиту руками): окно уходит с его страницы. В `object` — `Module`.
    static let moduleRemoved = Notification.Name("Utilitumus.ModuleRemoved")
}

/// Порядок модулей, включён ли каждый и виден ли в боковой панели. Работают утилиты, центр показывает их экраны.
///
/// «Установлен» (включён) и «скрыт из панели» — независимы. Установленный модуль работает; скрытый
/// работает так же, но его строки нет в панели (он в подвале «Скрытые»). Выключенный модуль считается
/// не установленным: в панели его нет, он только в Сторе. Открытый в панели модуль, который выключили
/// тумблером на его странице, остаётся до ухода со страницы. На новой установке всё выключено.
@MainActor
final class ModuleManager: ObservableObject {
    /// Настоящий порядок всех модулей: его читают и пишут настройки, показывают через `order`.
    @Published private var fullOrder: [Module]
    /// Модули в порядке боковой панели и настроек. Все, кроме дев-сборки с набором (`ModuleScope`).
    var order: [Module] { ModuleScope.shown(fullOrder) }
    @Published private(set) var enabled: Set<Module>
    @Published private(set) var hidden: Set<Module>
    /// Модули, которые ведёт отдельная утилита.
    @Published private(set) var external: Set<Module>
    /// Открытая страница «Об инструменте» (кнопка (i) или «Подробнее»).
    @Published var infoModule: Module?
    /// Открыт лист «Модули» (настройки) поверх главного окна.
    @Published var settingsShown = false

    private let defaults: UserDefaults
    /// Сброс при первом запуске коснулся модулей, которых ведёт утилита: реестр выключит их у утилиты при первом ответе.
    private var utilityResets: Set<Module> = []

    private static let orderKey = "ModuleOrder"
    private static let migratedKey = "ModulesV2"
    private static let uninstallSplitKey = "ModulesV3"
    static func onKey(_ module: Module) -> String { "ModuleOn.\(module.rawValue)" }
    private static func hiddenKey(_ module: Module) -> String { "ModuleHidden.\(module.rawValue)" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Слепок до миграций: они сами пишут `ModulesV2`, и по нему новую установку было бы не отличить.
        let resetPlan = ModuleReset.plan(snapshot: defaults.dictionaryRepresentation(),
                                         moduleIDs: Module.allCases.map(\.rawValue),
                                         handedOver: { defaults.bool(forKey: ModuleHandover.handedOverKey($0)) })
        if defaults.object(forKey: Self.migratedKey) == nil {
            Self.migrate(defaults)
            defaults.set(true, forKey: Self.migratedKey)
        }
        if defaults.object(forKey: Self.uninstallSplitKey) == nil {
            Self.splitUninstallFromHidden(defaults)
            defaults.set(true, forKey: Self.uninstallSplitKey)
        }
        // После миграций (иначе они вернули бы старые состояния) и до чтения `enabled`.
        if let resetPlan {
            for (key, value) in resetPlan.writes { defaults.set(value, forKey: key) }
            // «Клавиатура» при выходе не возвращала 🌐; без этого после сброса Fn не менял бы язык вообще.
            if resetPlan.restoresSystemFn { FnSystemAction.restore() }
            utilityResets = Set(resetPlan.askUtility.compactMap(Module.init(rawValue:)))
        }
        fullOrder = Self.normalizedOrder(defaults.stringArray(forKey: Self.orderKey) ?? [])
        enabled = Set(Module.allCases.filter { defaults.bool(forKey: Self.onKey($0)) })
        hidden = Set(Module.allCases.filter { defaults.bool(forKey: Self.hiddenKey($0)) })
        // Сразу из настроек: ответа утилиты и каталога при запуске ещё нет, а её страница нужна с первого кадра.
        external = Set(Module.allCases.filter { defaults.bool(forKey: ModuleHandover.handedOverKey($0.rawValue)) })
    }

    // MARK: Переход со старого формата

    /// Признаки того, что приложение уже запускали до этой версии.
    private static let existingInstallPrefixes = ModuleReset.legacyPrefixes

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

    /// Раньше «удалить» в Сторе выключало модуль и прятало его. Теперь это разные вещи, а «скрытый» значит
    /// «установлен»: у выключенных снимаем скрытие, иначе они висели бы в «Скрытых».
    private static func splitUninstallFromHidden(_ defaults: UserDefaults) {
        for module in Module.allCases where !defaults.bool(forKey: onKey(module)) && defaults.bool(forKey: hiddenKey(module)) {
            defaults.set(false, forKey: hiddenKey(module))
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

    func isOn(_ module: Module) -> Bool { enabled.contains(module) || external.contains(module) }
    func isExternal(_ module: Module) -> Bool { external.contains(module) }
    /// Модуль включён, а утилита его не ведёт: её надо поставить, а пока окно показывает `ModuleMissingPage`.
    func wantsUtility(_ module: Module) -> Bool { enabled.contains(module) && !external.contains(module) }
    func isHidden(_ module: Module) -> Bool { hidden.contains(module) }

    /// «Установлен» = включён или ведётся утилитой. Скрытие на это не влияет.
    func isInstalled(_ module: Module) -> Bool { isOn(module) }

    /// Установленные модули в порядке панели, скрытые тоже.
    var installedModules: [Module] { order.filter(isInstalled) }

    /// Есть ли строка модуля в боковой панели: установлен и не скрыт.
    func isInPanel(_ module: Module) -> Bool { ModuleScope.shows(module) && isInstalled(module) && !hidden.contains(module) }

    /// Модули, у которых есть строка в панели, в порядке панели.
    var panelModules: [Module] { order.filter(isInPanel) }

    /// Первый модуль панели: сначала закреплённые, потом список, как их показывает панель.
    var firstInPanel: Module? {
        let layout = SidebarModel.layout(modules: self, pins: SidebarModel.shared.pins, open: nil)
        return (layout.pinned + layout.list).first
    }

    /// Скрытые модули в порядке панели — для списка «Скрытые» внизу боковой панели. Только установленные.
    var hiddenModules: [Module] { order.filter { hidden.contains($0) && isInstalled($0) } }

    func setOn(_ module: Module, _ on: Bool) {
        defaults.set(on, forKey: Self.onKey(module))
        if on { enabled.insert(module) } else { enabled.remove(module) }
    }

    /// Один раз на модуль: сброс просит утилиту выключиться, а не трогает её настройки сам.
    func takeUtilityReset(_ module: Module) -> Bool {
        utilityResets.remove(module) != nil
    }

    func setExternal(_ module: Module, _ isExternal: Bool) {
        guard isExternal != external.contains(module) else { return }
        if isExternal { external.insert(module) } else { external.remove(module) }
    }

    func setHidden(_ module: Module, _ isHidden: Bool) {
        defaults.set(isHidden, forKey: Self.hiddenKey(module))
        if isHidden { hidden.insert(module) } else { hidden.remove(module) }
    }

    /// Порядок по умолчанию и все модули в панели. Включённость не трогаем.
    func resetAll() {
        defaults.removeObject(forKey: Self.orderKey)
        fullOrder = Module.allCases
        for module in Module.allCases { setHidden(module, false) }
    }

    /// Новый общий порядок (перетаскивание в панели). Лишние и повторы отбрасываются, недостающие идут в конец.
    func applyOrder(_ new: [Module]) {
        setOrder(Self.normalizedOrder(ModuleScope.merged(new, into: fullOrder).map(\.rawValue)))
    }

    private func setOrder(_ new: [Module]) {
        guard new != fullOrder else { return }
        fullOrder = new
        defaults.set(new.map(\.rawValue), forKey: Self.orderKey)
    }

    /// Выбранный модуль, если он не скрыт (выключенный остаётся, пока страница открыта);
    /// иначе первый модуль панели; иначе nil.
    func resolve(_ selection: Module) -> Module? {
        hidden.contains(selection) || !ModuleScope.shows(selection) ? firstInPanel : selection
    }
}
