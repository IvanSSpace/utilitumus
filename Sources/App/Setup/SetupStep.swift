import SwiftUI
import AVFoundation
import ApplicationServices
import Combine

/// Шаг настройки модуля: что нужно дать или сделать, чтобы он заработал. По шагам рисуются чек-лист,
/// плашка на экране модуля, «Понадобится» у выключенного модуля и «Разрешения» в подробностях Стора.
struct SetupStep: Identifiable {
    enum Kind {
        /// Разрешение, которое даёт человек: панель настроек или системный запрос.
        case permission
        /// Системная настройка (или загрузка), которую делаем мы сами по кнопке «Сделать».
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
    /// Проверка вживую: опрашивает систему на месте.
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
    /// Шаги из статуса утилиты, если она знает о модуле больше, чем центр: её ведёт утилита, или она стоит и отвечает
    /// (чек-лист до передачи, Q1). nil — шаги встроенного модуля. Ведомый модуль без ответа — пустой список: что в нём
    /// сделано, неизвестно, а вкладка и карточка скажут «не отвечает». Встроенные шаги вместо этого показали бы
    /// разрешения центра как разрешения утилиты.
    @MainActor var utilitySetupSteps: [SetupStep]? {
        let registry = SatelliteRegistry.shared
        let status = registry.entries[self]?.status
        if let status {
            return status.setupSteps.map { SetupStep($0, module: self, registry: registry) }
        }
        return ModuleManager.shared.isExternal(self) ? [] : nil
    }
}

// MARK: - Шаги по модулям

extension SetupStep {
    /// «Универсальный доступ»: у «Стеша», «Мыши», «Голоса» и «Буфера» один пункт, запрос — свой у каждого контроллера.
    @MainActor static func accessibility(id: String, why: String, required: Bool = true,
                                         request: @escaping @MainActor () -> Void) -> SetupStep {
        SetupStep(id: id, title: "Универсальный доступ", why: why, kind: .permission, icon: "lock.shield.fill",
                  required: required, isDone: { Kit.accessTrusted() }, perform: request)
    }

    /// Браузер по умолчанию — наш помощник ссылок.
    @MainActor static func isDefaultBrowser() -> Bool {
        guard let probe = URL(string: "https://example.com"),
              let url = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: url)?.bundleIdentifier == BrowserHelper.bundleID
    }

    /// Системный обработчик для обеих схем; macOS покажет своё подтверждение.
    @MainActor static func makeDefaultBrowser() {
        let appURL = BrowserHelper.appURL
        LSRegisterURL(appURL as CFURL, true)
        Task {
            for scheme in ["http", "https"] {
                try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
            }
        }
    }
}

extension KeyboardFeature {
    /// Шаги настройки фишки. «Раскладке для каждого приложения» разрешения не нужны.
    @MainActor var setupSteps: [SetupStep] {
        switch self {
        case .fnLanguage:
            return [
                // Tap только слушает, поэтому нужен именно «Мониторинг ввода».
                SetupStep(id: "keyboard.input", title: "Мониторинг ввода",
                          why: "Чтобы заметить тап по Fn/🌐; ничего не записывается",
                          kind: .permission, icon: "keyboard.fill",
                          isDone: { CGPreflightListenEventAccess() },
                          perform: { KeyboardController.shared.requestAccess() }),
                SetupStep(id: "keyboard.globe", title: "Отключить системное действие 🌐",
                          why: "Иначе macOS тоже переключит язык, и он сменится дважды",
                          kind: .system, icon: "globe", buttonTitle: "Сделать",
                          isDone: { FnSystemAction.usage == 0 },
                          perform: { KeyboardController.shared.disableSystemAction() }),
                SetupStep(id: "keyboard.dictation", title: "Убрать диктовку с двойного Fn",
                          why: "Иначе двойной тап Fn вызовет диктовку. Если macOS спросит «Включить диктовку?» — нажми «Не сейчас»",
                          kind: .recommendation, icon: "mic.slash.fill", buttonTitle: "Сделать", required: false,
                          isDone: { !FnSystemAction.dictationOnDoubleFn },
                          perform: { KeyboardController.shared.disableDictationDoubleFn() }),
            ]
        case .perAppLayout, .capsLock:
            return []
        }
    }
}

extension Module {
    /// Шаги настройки по порядку: сначала разрешения, потом наши системные настройки, потом рекомендации.
    @MainActor var setupSteps: [SetupStep] {
        if let steps = SetupFlow.overrides[self] { return steps }
        if let steps = utilitySetupSteps { return steps }
        switch self {
        case .sound, .load, .awake:
            return []
        case .fans:
            return [SetupStep(
                id: "fans.helper", title: "Помощник для вентиляторов", why: "Пароль администратора, один раз",
                kind: .permission, icon: "key.fill", buttonTitle: "Дать доступ…",
                // Устаревший помощник команд не получает, но обновляется плашкой на экране модуля: без этого шага экран открыт.
                isDone: { FanHelperInstaller.shared.status != .notInstalled },
                perform: { FanHelperInstaller.shared.install() },
                lastError: { FanHelperInstaller.shared.lastError })]
        case .stash:
            return [.accessibility(id: "stash.ax", why: "Чтобы вернуть окна на места",
                                   request: { StashStore.shared.requestAccess() })]
        case .mouse:
            return [.accessibility(id: "mouse.ax", why: "Чтобы менять направление и плавность прокрутки",
                                   request: { MouseController.shared.requestAccess() })]
        case .keyboard:
            // Шаги модуля — шаги включённых фишек.
            return KeyboardFeature.allCases.filter { KeyboardController.shared.isOn($0) }.flatMap(\.setupSteps)
        case .mixer:
            return [SetupStep(
                id: "mixer.capture", title: "Запись системного звука", why: "Система спросит при первом звуке",
                kind: .permission, icon: "waveform.badge.mic", buttonTitle: "Открыть настройки…", verifiable: false,
                isDone: { !MixerController.shared.permissionProblem },
                perform: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                })]
        case .clipboard:
            return [.accessibility(id: "clipboard.ax", why: "Чтобы выбранная запись вставлялась сама, иначе останется нажать ⌘V",
                                   required: false, request: { ClipboardController.shared.requestAccessibility() })]
        case .browser:
            return [SetupStep(
                id: "browser.default", title: "Браузер по умолчанию",
                why: "Чтобы ссылки шли через выбор браузера; macOS попросит подтвердить",
                kind: .permission, icon: "globe", buttonTitle: "Сделать основным",
                isDone: { SetupStep.isDefaultBrowser() },
                perform: { SetupStep.makeDefaultBrowser() })]
        case .voice:
            return [
                SetupStep(id: "voice.mic", title: "Микрофон", why: "Чтобы слышать тебя; звук остаётся на этом Mac",
                          kind: .permission, icon: "mic.fill",
                          isDone: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
                          perform: { VoiceController.shared.requestMic() }),
                Self.voiceModelStep,
                .accessibility(id: "voice.ax", why: "Чтобы текст вставлялся сам, иначе останется нажать ⌘V",
                               required: false, request: { VoiceController.shared.requestAccessibility() }),
            ]
        }
    }

    @MainActor private static var voiceModelStep: SetupStep {
        let store = VoiceModelStore.shared
        let size = StoreCatalog.megabytes(store.selected)
        return SetupStep(
            id: "voice.model", title: "Модель распознавания скачана",
            why: "Речь распознаётся на этом Mac, нужна модель (\(store.selected.title), \(size) МБ)",
            kind: .system, icon: "arrow.down.circle.fill", buttonTitle: "Скачать",
            isDone: { VoiceModel.allCases.contains { store.status($0) == .installed } },
            perform: { store.download(store.selected) },
            busy: {
                switch store.status(store.selected) {
                case .downloading(let p): return "Скачивается… \(Int(p * 100)) %"
                case .verifying: return "Проверяю подпись…"
                default: return nil
                }
            },
            lastError: {
                if case .failed(let message) = store.status(store.selected) { return message }
                return nil
            })
    }

    @MainActor var setupProgress: SetupProgress { SetupProgress(setupSteps) }

    /// Живое обновление того, что кешируют контроллеры, пока смотрят на чек-лист.
    @MainActor func refreshSetupSources() {
        if utilitySetupSteps != nil {
            SatelliteRegistry.shared.refresh(self)
            return
        }
        switch self {
        case .fans: FanHelperInstaller.shared.refresh()
        case .keyboard:
            KeyboardController.shared.refreshAccess()
            KeyboardController.shared.refreshSystem()
        case .voice: VoiceController.shared.refreshPermissions()
        default: break
        }
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
            // Тот же один проход, что у встроенного: два шага по отдельности дёрнули бы настройки дважды.
            let together = [KeyboardSetupID.globe, KeyboardSetupID.dictation]
            if steps.contains(where: { together.contains($0.id) && $0.isAutomatic && !$0.isDone() }) {
                RemoteKeyboardModel.shared.send(.disableAllSystemActions)
            }
            for step in steps where !together.contains(step.id) && step.isAutomatic && !step.isDone() { step.perform() }
        } else if module == .keyboard, module.utilitySetupSteps == nil, KeyboardController.shared.isOn(.fnLanguage) {
            // 🌐 и диктовка — одной записью и одним применением: по шагу на каждое дёргало систему
            // дважды, и macOS показывала окно «Включить диктовку?».
            KeyboardController.shared.disableAllSystemActions()
        } else {
            for step in steps where step.isAutomatic && !step.isDone() { step.perform() }
        }
        if let first = steps.first(where: { $0.kind == .permission && $0.status == .needed }) { first.perform() }
        AccessState.shared.refresh()
    }
}
