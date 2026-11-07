import SwiftUI
import Combine

/// Шаг настройки модуля: что нужно дать или сделать, чтобы он заработал. Шаги описывает утилита в своём статусе, центр
/// по ним рисует чек-лист, плашку на экране модуля, «Понадобится» у выключенного модуля и «Разрешения» в подробностях Стора.
struct SetupStep: Identifiable {
    enum Kind {
        /// Разрешение, которое даёт человек: панель настроек или системный запрос.
        case permission
        /// Системная настройка (или загрузка), которую утилита делает сама по кнопке «Сделать».
        case system
        /// Рекомендация: модуль работает и без неё.
        case recommendation
    }

    enum Status {
        case done
        /// Обязательный шаг не сделан.
        case needed
        /// Необязательный шаг не сделан.
        case optional
        /// Заранее не проверить: система спросит сама (запись звука). В счёт не идёт, пока нет сбоя.
        case onDemand
    }

    let id: String
    let title: String
    /// Одна строка «зачем».
    let why: String
    let kind: Kind
    let icon: String
    var buttonTitle = "Разрешить…"
    /// Без обязательных шагов модуль не работает как надо; необязательные можно пропустить.
    var required = true
    /// Можно ли проверить заранее; нет — шаг «спросит сама», пока не будет сбоя.
    var verifiable = true
    /// Сделан ли шаг: по последнему статусу утилиты.
    let isDone: @MainActor () -> Bool
    let perform: @MainActor () -> Void
    /// Строка вместо «зачем», пока шаг выполняется (скачивание).
    var busy: @MainActor () -> String? = { nil }
    /// Ошибка последней попытки, показывается под строкой.
    var lastError: @MainActor () -> String? = { nil }

    @MainActor var status: Status {
        if isDone() { return verifiable ? .done : .onDemand }
        return required ? .needed : .optional
    }

    /// Шаг, который мы делаем сами, без панелей настроек.
    var isAutomatic: Bool { kind != .permission }
}

/// Сколько шагов выполнено и что осталось.
struct SetupProgress {
    let steps: [SetupStep]
    let statuses: [SetupStep.Status]

    @MainActor init(_ steps: [SetupStep]) {
        self.steps = steps
        statuses = steps.map(\.status)
    }

    private var counted: [(SetupStep, SetupStep.Status)] { Array(zip(steps, statuses)).filter { $0.1 != .onDemand } }
    var total: Int { counted.count }
    var done: Int { counted.filter { $0.1 == .done }.count }
    var requiredMissing: [SetupStep] { counted.filter { $0.1 == .needed }.map(\.0) }
    var requiredDone: Bool { requiredMissing.isEmpty }
    var allDone: Bool { done == total }
}

// MARK: - Шаги утилиты

extension SetupStep {
    /// Шаг, который описала утилита. Рисует центр, а выполняет утилита: macOS покажет её имя в запросе.
    /// Проверить заранее нельзя (`verifiable == false`) — шаг остаётся «спросит сама», готовым он не считается.
    @MainActor init(_ step: LinkSetupStep, module: Module, registry: SatelliteRegistry) {
        let kind: Kind
        switch step.kind {
        case .permission: kind = .permission
        case .system: kind = .system
        case .recommendation: kind = .recommendation
        }
        self.init(id: step.id, title: step.title, why: step.why, kind: kind, icon: step.icon,
                  buttonTitle: step.buttonTitle ?? "Разрешить…", required: step.required,
                  verifiable: step.verifiable,
                  isDone: { step.done },
                  perform: { registry.performSetupStep(module, step.id) },
                  busy: { step.busy },
                  lastError: { step.error ?? registry.stepErrors["\(module.rawValue).\(step.id)"] })
    }
}

extension Module {
    /// Шаги из статуса утилиты. Утилиты нет или она не отвечает — пустой список: что в ней сделано, неизвестно,
    /// а вкладка и карточка скажут об этом сами. Чек-лист бывает и до передачи, если утилита уже стоит и отвечает.
    @MainActor var setupSteps: [SetupStep] {
        if let steps = SetupFlow.overrides[self] { return steps }
        let registry = SatelliteRegistry.shared
        return registry.entries[self]?.status?.setupSteps.map { SetupStep($0, module: self, registry: registry) } ?? []
    }

    @MainActor var setupProgress: SetupProgress { SetupProgress(setupSteps) }

    /// Статус утилиты заново, пока смотрят на чек-лист.
    @MainActor func refreshSetupSources() {
        SatelliteRegistry.shared.refresh(self)
    }
}

// MARK: - Ход настройки

/// Где сейчас показывать чек-лист: открыт принудительно (после установки, «Продолжить» в плашке),
/// отложен на этот запуск («Позже») или плашка скрыта насовсем.
@MainActor
final class SetupFlow: ObservableObject {
    static let shared = SetupFlow()

    /// Подмена шагов для стенда снимков; в приложении пусто.
    static var overrides: [Module: [SetupStep]] = [:]

    @Published private(set) var forced: Set<Module> = []
    @Published private(set) var deferred: Set<Module> = []
    private static let hiddenKey = "Setup.BannerHidden"

    /// Открыть чек-лист модуля поверх его экрана. У модуля без шагов ничего не делает.
    func show(_ module: Module) {
        guard module.setupProgress.total > 0 else { return }
        deferred.remove(module)
        forced.insert(module)
    }

    /// «Готово, можно пользоваться»: к экрану модуля.
    func finish(_ module: Module) { forced.remove(module) }

    /// «Позже»: экран модуля без чек-листа до следующего запуска, остаётся плашка.
    func postpone(_ module: Module) {
        forced.remove(module)
        deferred.insert(module)
    }

    func isBannerHidden(_ module: Module) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []).contains(module.rawValue)
    }

    func hideBanner(_ module: Module) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []
        if !ids.contains(module.rawValue) { ids.append(module.rawValue) }
        UserDefaults.standard.set(ids, forKey: Self.hiddenKey)
        objectWillChange.send()
    }

    /// «Сделать всё автоматически»: все наши шаги, потом панель первого недостающего обязательного разрешения.
    func doAll(_ module: Module) {
        let steps = module.setupSteps
        if module == .keyboard, ModuleManager.shared.isExternal(.keyboard) {
            // 🌐 и диктовка одним проходом утилиты: по шагу на каждое дёргало бы систему дважды,
            // и macOS показывала окно «Включить диктовку?».
            let together = [KeyboardSetupID.globe, KeyboardSetupID.dictation]
            if steps.contains(where: { together.contains($0.id) && $0.isAutomatic && !$0.isDone() }) {
                RemoteKeyboardModel.shared.send(.disableAllSystemActions)
            }
            for step in steps where !together.contains(step.id) && step.isAutomatic && !step.isDone() { step.perform() }
        } else {
            for step in steps where step.isAutomatic && !step.isDone() { step.perform() }
        }
        if let first = steps.first(where: { $0.kind == .permission && $0.status == .needed }) { first.perform() }
        AccessState.shared.refresh()
    }
}
