import SwiftUI
import Combine

// Стор: витрина утилит. Каждый модуль ставится отдельным приложением через `SatelliteRegistry`, «установлен» = утилита
// есть (скрыта её строка из панели или нет, не важно). Установка остаётся в Сторе: настройку и переход в модуль
// человек выбирает сам. Каталог недоступен или записи нет: поставить нечего, отказ виден внизу Стора.
// Удаление убирает утилиту, стирает скачанное и снимает скрытие; настройки модуля остаются.
// «Скрыть из панели» — отдельное действие, на «установлен» не влияет.

// MARK: - Разрешения

enum StorePermission: String, CaseIterable {
    case accessibility, microphone, inputMonitoring, rootHelper, systemAudio

    var title: String {
        switch self {
        case .accessibility: return "Универсальный доступ"
        case .microphone: return "Микрофон"
        case .inputMonitoring: return "Мониторинг ввода"
        case .rootHelper: return "Root-помощник"
        case .systemAudio: return "Запись системного звука"
        }
    }

    var icon: String {
        switch self {
        case .accessibility: return "lock.shield.fill"
        case .microphone: return "mic.fill"
        case .inputMonitoring: return "keyboard.fill"
        case .rootHelper: return "key.fill"
        case .systemAudio: return "waveform.badge.mic"
        }
    }
}

/// Разрешение модуля и зачем оно нужно.
struct StoreNeed: Identifiable {
    let permission: StorePermission
    let why: String
    var id: String { permission.rawValue }
}

// MARK: - Каталог

enum StoreCatalog {
    static func megabytes(_ model: VoiceModel) -> Int { Int((Double(model.sizeBytes) / 1_000_000).rounded()) }

    static func needs(_ m: Module) -> [StoreNeed] {
        switch m {
        case .fans: return [StoreNeed(permission: .rootHelper, why: "Пароль администратора, один раз: помощник управляет вентиляторами")]
        case .stash: return [StoreNeed(permission: .accessibility, why: "Чтобы вернуть окна программ на места")]
        case .mouse: return [StoreNeed(permission: .accessibility, why: "Чтобы менять направление и плавность прокрутки")]
        case .keyboard: return [StoreNeed(permission: .inputMonitoring, why: "Для фишки «Язык по Fn»: чтобы заметить тап; ничего не записывается")]
        case .mixer: return [StoreNeed(permission: .systemAudio, why: "Система спросит при первом звуке")]
        case .clipboard: return [StoreNeed(permission: .accessibility, why: "Чтобы выбранная запись вставлялась сама")]
        case .voice: return [StoreNeed(permission: .microphone, why: "Чтобы слышать тебя; звук остаётся на этом Mac"),
                             StoreNeed(permission: .accessibility, why: "Чтобы текст вставлялся сам, иначе останется нажать ⌘V")]
        case .sound, .load, .browser, .awake, .bots: return []
        }
    }

    /// Одна короткая строка для плитки: помещается в одну строку без обрезания.
    static func line(_ m: Module) -> String {
        switch m {
        case .sound: return "Возвращает выбранный звук"
        case .load: return "Что ест память и процессор"
        case .stash: return "Чистит Mac перед игрой"
        case .fans: return "Обороты вентиляторов Mac"
        case .mixer: return "Громкость по программам"
        case .mouse: return "Своя прокрутка для мыши"
        case .browser: return "Браузер на каждую ссылку"
        case .voice: return "Диктовка в любое поле"
        case .clipboard: return "История буфера обмена"
        case .keyboard: return "Фишки для клавиатуры и языка"
        case .awake: return "Mac не засыпает за работой"
        case .bots: return "Боты одним списком"
        }
    }

    /// Что сотрётся при удалении: пункты для подтверждения.
    @MainActor static func removal(_ m: Module) -> [String] {
        var items = ["Модуль выключится и пропадёт из боковой панели и из «Скрытых»"]
        if SatelliteRegistry.shared.hasBundle(m) {
            items.append("Приложение \(SatelliteRegistry.bundleName(m)) из папки «Программы/Utilitumus»")
        }
        if m == .voice {
            // С диска, а не из статусов стора: их мог изменить процесс утилиты.
            for model in VoiceModel.allCases where VoiceModelFiles.isInstalled(model) {
                items.append("Скачанная модель \(model.title) (\(megabytes(model)) МБ)")
            }
        }
        if needs(m).contains(where: { $0.permission == .rootHelper }) {
            items.append("Root-помощник останется в системе: его убирают вручную")
        }
        return items
    }
}

/// Модуль, которого ещё нет: в витрине серая плитка «Скоро».
struct StoreSoon: Identifiable {
    let id: String
    let title: String
    let tagline: String
    let icon: String
    let categoryID: String

    static let all = [
        StoreSoon(id: "battery", title: "Батарея 80%", tagline: "Стоп зарядки на 80%",
                  icon: "battery.75percent", categoryID: "background"),
    ]
}

// MARK: - Наборы контента

enum PackGroup: String, CaseIterable, Identifiable {
    case voices, browser, mixer, themes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .voices: return "Голоса"
        case .browser: return "Правила браузера"
        case .mixer: return "Пресеты микшера"
        case .themes: return "Темы"
        }
    }

    var icon: String {
        switch self {
        case .voices: return "waveform"
        case .browser: return "globe"
        case .mixer: return "slider.vertical.3"
        case .themes: return "paintpalette.fill"
        }
    }

    /// Модуль, в чьи цвета красим группу.
    var module: Module {
        switch self {
        case .voices: return .voice
        case .browser: return .browser
        case .mixer: return .mixer
        case .themes: return .sound
        }
    }
}

struct StorePack: Identifiable {
    let id: String
    let group: PackGroup
    let title: String
    let detail: String
    let megabytes: Double

    var sizeText: String { megabytes < 1 ? "\(Int(megabytes * 1000)) КБ" : "\(Int(megabytes)) МБ" }

    static let all = [
        StorePack(id: "v-ru-s", group: .voices, title: "Русский, малая", detail: "быстрая", megabytes: 170),
        StorePack(id: "v-ru-l", group: .voices, title: "Русский, точная", detail: "медленнее", megabytes: 480),
        StorePack(id: "v-en-s", group: .voices, title: "English, малая", detail: "быстрая", megabytes: 120),
        StorePack(id: "b-work", group: .browser, title: "Работа и личное", detail: "12 правил", megabytes: 0.04),
        StorePack(id: "b-mail", group: .browser, title: "Почта и чаты", detail: "8 правил", megabytes: 0.03),
        StorePack(id: "b-soc", group: .browser, title: "Соцсети отдельно", detail: "15 правил", megabytes: 0.06),
        StorePack(id: "m-stream", group: .mixer, title: "Стрим", detail: "игра тише", megabytes: 0.01),
        StorePack(id: "m-call", group: .mixer, title: "Созвон", detail: "музыка тише", megabytes: 0.01),
        StorePack(id: "m-focus", group: .mixer, title: "Фокус", detail: "только работа", megabytes: 0.01),
        StorePack(id: "t-dusk", group: .themes, title: "Закат", detail: "тёплая", megabytes: 0.2),
        StorePack(id: "t-fog", group: .themes, title: "Туман", detail: "холодная", megabytes: 0.2),
        StorePack(id: "t-lime", group: .themes, title: "Лайм", detail: "яркая", megabytes: 0.2),
    ]
}

// MARK: - Состояние установки

enum StoreStage: Int, CaseIterable {
    case download, verify

    var title: String {
        switch self {
        case .download: return "Скачивание"
        case .verify: return "Проверка подписи"
        }
    }
}

enum StoreState: Equatable {
    case available
    /// Идёт скачивание ресурсов: этап и доля внутри него (0…1).
    case installing(StoreStage, Double)
    case installed
}

/// Установка или удаление через установщик сорвались. Висит внизу Стора, пока её не закроют или не начнут новое.
struct StoreFailure: Equatable {
    let module: Module
    let message: String
}

enum StoreTab: String, CaseIterable, Hashable {
    case showcase, packs
    var title: String { self == .showcase ? "Витрина" : "Наборы контента" }
}

extension Notification.Name {
    /// Стор просит главное окно открыть модуль (после установки): в `object` — `Module`.
    static let storeOpenModule = Notification.Name("Utilitumus.StoreOpenModule")
}

@MainActor
final class StoreModel: ObservableObject {
    static let shared = StoreModel()

    @Published var tab: StoreTab = .showcase
    @Published var detail: Module?
    /// Модуль, удаление которого ждёт подтверждения.
    @Published var pendingRemoval: Module?

    /// Короткое подтверждение внизу Стора после установки: на 3–4 с, без перехода.
    @Published private(set) var justInstalled: Module?
    private var toastTask: Task<Void, Never>?

    private let modules = ModuleManager.shared
    let satellites = SatelliteRegistry.shared
    @Published private(set) var failure: StoreFailure?
    /// Идущие установки и удаления: отсюда их отменяет кнопка с процентом. Запись появляется сразу, раньше
    /// старта задачи: иначе «＋» успел бы нажаться дважды.
    @Published private var operations: [Module: Task<Void, Never>] = [:]
    private var subs: [AnyCancellable] = []

    /// Рекомендация дня.
    static let featured: Module = .voice

    init() {
        // Состояние берём у менеджера модулей и утилиты «Голоса»: их изменения перерисовывают стор.
        subs.append(modules.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        subs.append(RemoteVoiceModel.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        if modules.isExternal(.voice) { RemoteVoiceModel.shared.refresh() }
        subs.append(satellites.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    /// «Установлен» = утилита есть. Включённый модуль без неё только ждёт установки: его ставит тот же «＋».
    func isInstalled(_ module: Module) -> Bool { modules.isExternal(module) || satellites.hasBundle(module) }

    func state(_ module: Module) -> StoreState {
        // Установщик долю не сообщает: только этап. Не установленный может ставить и переход при запуске: «＋» там молчал бы.
        if operations[module] != nil || (!isInstalled(module) && satellites.busy.contains(module)) { return .installing(.download, 0) }
        // Модели скачивает утилита, Стор только показывает ход.
        if module == .voice, modules.isExternal(.voice) {
            let voice = RemoteVoiceModel.shared
            switch voice.status(voice.selected) {
            case .downloading(let p): return .installing(.download, p)
            case .verifying: return .installing(.verify, 0)
            default: break
            }
        }
        return isInstalled(module) ? .installed : .available
    }

    func hasUpdate(_ module: Module) -> Bool { satellites.hasUpdate(module) }

    /// Что изменилось в версии, которая ждёт установки.
    func updateNotes(_ module: Module) -> [String] {
        guard satellites.hasUpdate(module) else { return [] }
        return satellites.catalogApp(module)?.notes ?? []
    }

    // MARK: Окно подробностей

    func open(_ module: Module) {
        withAnimation(.easeInOut(duration: 0.2)) { detail = module }
    }

    func close() {
        withAnimation(.easeInOut(duration: 0.2)) { detail = nil }
    }

    // MARK: Сборка

    /// Установленные и ставящиеся модули.
    var buildModules: [Module] {
        ModuleScope.shown(Module.allCases).filter { state($0) != .available }
    }

    /// Сколько реально лежит на диске из скачанного.
    var buildMegabytes: Int {
        buildModules.contains(.voice)
            ? VoiceModel.allCases.filter { VoiceModelFiles.isInstalled($0) }.reduce(0) { $0 + StoreCatalog.megabytes($1) } : 0
    }

    // MARK: Действия

    /// Поставить утилиту и показать строку в панели. Остаёмся в Сторе: плитка станет «Установлен»,
    /// переход в модуль — кнопка «Открыть». Записи в каталоге нет: ничего не меняем, говорим почему.
    func install(_ module: Module) {
        guard let app = satellites.catalogApp(module) else {
            failure = StoreFailure(module: module, message: unavailableMessage(module))
            // «Попробуй ещё раз» должно быть правдой: сеть могла вернуться, а опрос идёт только при открытии Стора.
            satellites.refresh()
            return
        }
        modules.setHidden(module, false)
        runInstall(module, app)
    }

    private func unavailableMessage(_ module: Module) -> String {
        if let held = satellites.heldByHub[module] { return "Сначала обнови Utilitumus: нужна версия \(held.minHub) или новее" }
        return satellites.catalogFailed ? "Каталог недоступен: проверь сеть и попробуй ещё раз" : "Этой утилиты пока нет в каталоге"
    }

    /// Перейти в модуль в главном окне.
    func openInApp(_ module: Module) {
        close()
        NotificationCenter.default.post(name: .storeOpenModule, object: module)
    }

    func isHidden(_ module: Module) -> Bool { modules.isHidden(module) }

    /// «Показать в панели» у установленного скрытого модуля.
    func showInPanel(_ module: Module) { modules.setHidden(module, false) }

    private func runInstall(_ module: Module, _ app: CatalogApp) {
        run(module, fallback: "Не удалось установить модуль") {
            try await self.satellites.install(module, app: app)
            self.showToast(module)
        }
    }

    /// Идёт ли над модулем операция: своя, из очереди обновлений или переход на утилиту при запуске центра.
    func isOperating(_ module: Module) -> Bool { operations[module] != nil || satellites.busy.contains(module) }

    /// Обновление из очереди: та же запись в `operations`, что у кнопки, поэтому плитка видит ход и может отменить,
    /// а удаление и второе обновление не начнутся. Итог возвращается очереди, внизу Стора ничего не всплывает.
    func updateFromQueue(_ module: Module, app: CatalogApp,
                         checkStaged: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }) async -> Error? {
        guard !isOperating(module) else { return URLError(.cancelled) }
        return await withCheckedContinuation { done in
            operations[module] = Task {
                var failure: Error?
                do {
                    try await satellites.install(module, app: app, checkStaged: checkStaged)
                } catch {
                    NSLog("Utilitumus: обновление модуля %@: %@", module.rawValue, String(describing: error))
                    failure = error
                }
                operations[module] = nil
                done.resume(returning: failure)
            }
        }
    }

    private func run(_ module: Module, fallback: String, _ work: @escaping () async throws -> Void) {
        // Реестр молча вышел бы из занятого модуля, а дальше здесь шла бы «удача»: удаление стёрло бы модели.
        guard !isOperating(module) else { return }
        failure = nil
        operations[module] = Task {
            do {
                try await work()
            } catch {
                show(error, module: module, fallback: fallback)
            }
            operations[module] = nil
        }
    }

    private func show(_ error: Error, module: Module, fallback: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        NSLog("Utilitumus: модуль %@: %@", module.rawValue, String(describing: error))
        failure = StoreFailure(module: module, message: Self.failureMessage(error, fallback: fallback))
    }

    func dismissFailure() { failure = nil }

    /// `localizedDescription` здесь не годится: у `LinkError` он системный и английский, и он же лежит
    /// в `rollbackFailed.cause`. Сырое остаётся в журнале.
    static func failureMessage(_ error: Error, fallback: String) -> String {
        switch error {
        case SatelliteInstallError.rollbackFailed:
            return "Не получилось, и прежнее состояние вернуть не удалось. Поставь модуль заново"
        case let error as SatelliteInstallError:
            return error.errorDescription ?? fallback
        case let error as KitSigning.Failure:
            return error.userMessage ?? fallback
        case is LinkError:
            return "Модуль не ответил после запуска, прежняя версия возвращена"
        case is URLError:
            return "Не удалось скачать модуль: проверь сеть"
        case _ where isPermissionFailure(error):
            return "Нет прав на запись в папку «Программы»"
        default:
            return fallback
        }
    }

    private static func isPermissionFailure(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain: return [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code)
        case NSPOSIXErrorDomain: return [Int(EACCES), Int(EPERM)].contains(error.code)
        default: return false
        }
    }

    private func showToast(_ module: Module) {
        withAnimation(.easeInOut(duration: 0.2)) { justInstalled = module }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.2)) { self?.justInstalled = nil } }
        }
    }

    /// Кнопка «Обновить».
    func update(_ module: Module) {
        guard satellites.hasUpdate(module), let app = satellites.catalogApp(module) else { return }
        runInstall(module, app)
    }

    func cancel(_ module: Module) {
        operations[module]?.cancel()
        if module == .voice, modules.isExternal(.voice) { RemoteVoiceModel.shared.cancel(RemoteVoiceModel.shared.selected) }
    }

    /// Выход из центра: всё, что идёт через установщик. Отмена после остановки утилиты возвращает прежнюю версию (откат).
    func cancelOperations() {
        operations.values.forEach { $0.cancel() }
    }

    func requestRemoval(_ module: Module) { pendingRemoval = module }

    /// Убрать утилиту, стереть скачанное, снять скрытие (иначе модуль висел бы в «Скрытых»). Настройки модуля не трогаем.
    /// Утилиты нет у включённого модуля, который ждёт установки: тогда уходит только его строка.
    func remove(_ module: Module) {
        pendingRemoval = nil
        guard !isOperating(module) else {
            failure = StoreFailure(module: module, message: "Модуль сейчас обновляется, удалить можно, когда закончится")
            return
        }
        guard satellites.hasBundle(module) else {
            // До первого опроса бандла ещё не видно, а утилита работает: удаление стёрло бы модели из-под неё.
            guard !modules.isExternal(module) else {
                failure = StoreFailure(module: module, message: "Утилита ещё проверяется, попробуй через секунду")
                return
            }
            finishRemoval(module)
            return
        }
        run(module, fallback: "Не удалось удалить модуль") {
            try await self.satellites.uninstall(module)
            self.finishRemoval(module)
        }
    }

    private func finishRemoval(_ module: Module) {
        modules.setOn(module, false)
        modules.setHidden(module, false)
        if module == .voice {
            // Утилиты к этому часу уже нет, папки моделей удаляет центр сам.
            for model in VoiceModel.allCases where VoiceModelFiles.isInstalled(model) { VoiceModelFiles.delete(model) }
        }
        pendingRemoval = nil
        if justInstalled == module { justInstalled = nil }
        NotificationCenter.default.post(name: .moduleRemoved, object: module)
    }
}

extension DSTheme {
    /// Акцент страницы стора: спокойный серо-синий, не цвет рекомендованного модуля.
    func storeTint() -> Color {
        self == .graphite ? Color.accentColor : Color(hue: 0.60, saturation: 0.28, brightness: 0.90)
    }
}
