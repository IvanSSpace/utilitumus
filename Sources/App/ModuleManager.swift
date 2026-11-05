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
/// «Установлен» (включён) и «скрыт из панели» — независимы. Установленный модуль работает; скрытый
/// работает так же, но его строки нет в панели (он в подвале «Скрытые»). Выключенный модуль считается
/// не установленным: в панели его нет, он только в Сторе. Открытый в панели модуль, который выключили
/// тумблером на его странице, остаётся до ухода со страницы. На новой установке всё выключено.
@MainActor
final class ModuleManager: ObservableObject {
    /// Все модули в порядке боковой панели и настроек.
    @Published private(set) var order: [Module]
    @Published private(set) var enabled: Set<Module>
    @Published private(set) var hidden: Set<Module>
    /// Модули, которые ведёт отдельная утилита: встроенный код не работает, страница и строка панели остаются.
    @Published private(set) var external: Set<Module>
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
    private static let uninstallSplitKey = "ModulesV3"
    static func onKey(_ module: Module) -> String { "ModuleOn.\(module.rawValue)" }
    private static func hiddenKey(_ module: Module) -> String { "ModuleHidden.\(module.rawValue)" }

    init(defaults: UserDefaults = .standard, hooks: @escaping (Module) -> ModuleHooks) {
        self.defaults = defaults
        self.hooks = hooks
        // Слепок до миграций: они сами пишут `ModulesV2`, и по нему новую установку было бы не отличить.
        let resetPlan = ModuleReset.plan(snapshot: defaults.dictionaryRepresentation(),
                                         moduleIDs: Module.allCases.map(\.rawValue))
        if defaults.object(forKey: Self.migratedKey) == nil {
            Self.migrate(defaults)
            defaults.set(true, forKey: Self.migratedKey)
        }
        if defaults.object(forKey: Self.uninstallSplitKey) == nil {
            Self.splitUninstallFromHidden(defaults)
            defaults.set(true, forKey: Self.uninstallSplitKey)
        }
        // После миграций (иначе они вернули бы старые состояния) и до чтения `enabled`: ничего лишнего не стартует.
        if let resetPlan {
            for (key, value) in resetPlan.writes { defaults.set(value, forKey: key) }
            // «Клавиатура» при выходе не возвращала 🌐; без этого после сброса Fn не менял бы язык вообще.
            if resetPlan.restoresSystemFn { FnSystemAction.restore() }
        }
        order = Self.normalizedOrder(defaults.stringArray(forKey: Self.orderKey) ?? [])
        enabled = Set(Module.allCases.filter { defaults.bool(forKey: Self.onKey($0)) })
        hidden = Set(Module.allCases.filter { defaults.bool(forKey: Self.hiddenKey($0)) })
        // Сразу из настроек: ответа утилиты и каталога при запуске ещё нет, а двойной работы быть не должно и на миг.
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
    /// Работает ли встроенный код: контроллеры модуля можно трогать только тогда.
    func runsBuiltIn(_ module: Module) -> Bool { enabled.contains(module) && !external.contains(module) }
    func isHidden(_ module: Module) -> Bool { hidden.contains(module) }

    /// Модули в порядке панели без скрытых; выключенные тоже тут (панель сама оставляет только установленные
    /// и открытый сейчас). Нужно для перетаскивания: переставляются места, занятые видимыми.
    var shownModules: [Module] { order.filter { !hidden.contains($0) } }

    /// «Установлен» = включён или ведётся утилитой. Скрытие на это не влияет.
    func isInstalled(_ module: Module) -> Bool { isOn(module) }

    /// Установленные модули в порядке панели, скрытые тоже.
    var installedModules: [Module] { order.filter(isInstalled) }

    /// Есть ли строка модуля в боковой панели: установлен и не скрыт.
    func isInPanel(_ module: Module) -> Bool { isInstalled(module) && !hidden.contains(module) }

    /// Модули, у которых есть строка в панели, в порядке панели.
    var panelModules: [Module] { order.filter(isInPanel) }

    /// Первый модуль панели так, как их показывает панель: по вкладкам, внутри вкладки по порядку.
    var firstInPanel: Module? {
        let inPanel = panelModules
        return ModuleCategory.all.lazy.compactMap { category in inPanel.first { $0.category == category } }.first
    }

    /// Скрытые модули в порядке панели — для списка «Скрытые» внизу боковой панели. Только установленные.
    var hiddenModules: [Module] { order.filter { hidden.contains($0) && isInstalled($0) } }

    func setOn(_ module: Module, _ on: Bool) {
        defaults.set(on, forKey: Self.onKey(module))
        if on { enabled.insert(module) } else { enabled.remove(module) }
        if isActive { sync(module) }
    }

    /// Модуль ведёт утилита: встроенный останавливается и не стартует. `ModuleOn` не меняется: снимут
    /// утилиту — встроенный вернётся таким, каким был.
    func setExternal(_ module: Module, _ isExternal: Bool) {
        guard isExternal != external.contains(module) else { return }
        if isExternal { external.insert(module) } else { external.remove(module) }
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

    /// Выбранный модуль, если он не скрыт (выключенный остаётся, пока страница открыта);
    /// иначе первый модуль панели; иначе nil.
    func resolve(_ selection: Module) -> Module? {
        hidden.contains(selection) ? firstInPanel : selection
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
        let wanted = runsBuiltIn(module)
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
