import SwiftUI
import AVFoundation
import ApplicationServices
import Combine

// Стор: витрина-настройщик. Код модулей уже в приложении, «установлен» = модуль включён (скрыт он из панели
// или нет, не важно). Установка включает модуль, ставит его в панель и качает ресурсы (пока это модель «Голоса»),
// но остаётся в Сторе: настройку и переход в модуль человек выбирает сам.
// Удаление выключает модуль, стирает скачанное и снимает скрытие; настройки модуля остаются.
// «Скрыть из панели» — отдельное действие, на «установлен» не влияет.
// Модуль с записью в каталоге ставится отдельным приложением через `SatelliteRegistry`; плитка та же, разница
// только в том, что делает «＋». Каталог недоступен или записи нет — всё как у встроенного.

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

    /// Выдано ли сейчас: те же проверки, что в `ModuleRequirements`. nil — заранее не проверить (система спросит сама).
    @MainActor var isGranted: Bool? {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .rootHelper: return FanHelperInstaller.shared.status != .notInstalled
        case .systemAudio: return nil
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

/// Что скачивается при установке и куда ложится.
struct StoreDownload {
    let megabytes: Int
    let kind: String
    let path: String
    /// Подпись под размером, например какая именно модель.
    let name: String
    /// Что ещё можно докачать по желанию, уже внутри модуля.
    var optional: String?
}

// MARK: - Каталог

enum StoreCatalog {
    static func megabytes(_ model: VoiceModel) -> Int { Int((Double(model.sizeBytes) / 1_000_000).rounded()) }

    /// Что скачается при установке. У «Голоса» — выбранная модель (по умолчанию GigaAM), размер из `VoiceModels`.
    @MainActor static func downloads(_ m: Module) -> StoreDownload? {
        guard m == .voice else { return nil }
        let model = VoiceModelStore.shared.selected
        let other = VoiceModel.allCases.first { $0 != model }
        return StoreDownload(megabytes: megabytes(model), kind: "модель", path: "~/Library/Application Support/Utilitumus/Voice/Models/",
                             name: model.title,
                             optional: other.map { "\($0.title) — ещё \(megabytes($0)) МБ, по желанию в самом модуле" })
    }

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
        case .sound, .load, .browser, .awake: return []
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
        }
    }

    /// Что сотрётся при удалении: пункты для подтверждения.
    @MainActor static func removal(_ m: Module) -> [String] {
        var items = ["Модуль выключится и пропадёт из боковой панели и из «Скрытых»"]
        if SatelliteRegistry.shared.hasBundle(m) {
            items.append("Приложение \(SatelliteRegistry.bundleName(m)) из папки «Программы/Utilitumus»")
        }
        if m == .voice {
            for model in VoiceModel.allCases where VoiceModelStore.shared.status(model) != .notInstalled {
                items.append("Скачанная модель \(model.title) (\(megabytes(model)) МБ)")
            }
        }
        if needs(m).contains(where: { $0.permission == .rootHelper }) {
            items.append("Root-помощник останется в системе: его убирают вручную")
        }
        return items
    }

    /// Короткая подпись размера для плитки и карточки.
    @MainActor static func sizeText(_ m: Module, short: Bool = false) -> String {
        if short { return downloads(m).map { "+\($0.megabytes) МБ" } ?? "без загрузки" }
        return downloads(m).map { "+\($0.megabytes) МБ \($0.kind)" } ?? "ничего не скачивает"
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
        StoreSoon(id: "agents", title: "Агент-центр", tagline: "Агенты в одном окне",
                  icon: "person.3.fill", categoryID: "ai"),
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
    /// Модуль удалён (из Стора или из боковой панели): в `object` — `Module`. Главное окно уходит с его страницы.
    static let moduleRemoved = Notification.Name("Utilitumus.ModuleRemoved")
}

@MainActor
final class StoreModel: ObservableObject {
    static let shared = StoreModel()

    @Published var tab: StoreTab = .showcase
    @Published var detail: Module?
    /// Категория, которую витрина подсвечивает после перехода из пустой вкладки панели.
    @Published var highlighted: ModuleCategory?
    private var highlightTask: Task<Void, Never>?
    /// Модуль, удаление которого ждёт подтверждения.
    @Published var pendingRemoval: Module?

    /// Короткое подтверждение внизу Стора после установки: на 3–4 с, без перехода.
    @Published private(set) var justInstalled: Module?
    private var toastTask: Task<Void, Never>?

    private let modules = ModuleManager.shared
    private let voice = VoiceModelStore.shared
    let satellites = SatelliteRegistry.shared
    @Published private(set) var failure: StoreFailure?
    /// Идущие установки и удаления: отсюда их отменяет кнопка с процентом. Запись появляется сразу, раньше
    /// старта задачи: иначе «＋» успел бы нажаться дважды.
    @Published private var operations: [Module: Task<Void, Never>] = [:]
    private var subs: [AnyCancellable] = []

    /// Рекомендация дня.
    static let featured: Module = .voice

    init() {
        // Состояние берём у менеджера модулей и стора моделей: их изменения перерисовывают стор.
        subs.append(modules.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        subs.append(voice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        subs.append(satellites.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    /// «Установлен» = модуль включён.
    func isInstalled(_ module: Module) -> Bool { modules.isInstalled(module) }

    func state(_ module: Module) -> StoreState {
        // Установщик долю не сообщает: только этап.
        if operations[module] != nil { return .installing(.download, 0) }
        if module == .voice {
            switch voice.status(voice.selected) {
            case .downloading(let p): return .installing(.download, p)
            case .verifying: return .installing(.verify, 0)
            default: break
            }
        }
        return isInstalled(module) ? .installed : .available
    }

    /// Установленному модулю не хватает ресурсов: у «Голоса» не скачана модель.
    func hasUpdate(_ module: Module) -> Bool {
        if satellites.hasBundle(module) { return satellites.hasUpdate(module) }
        return module == .voice && isInstalled(.voice) && !VoiceModelStore.isInstalled(voice.selected)
    }

    /// Витрина с подсвеченной на пару секунд категорией.
    func show(category: ModuleCategory) {
        tab = .showcase
        detail = nil
        highlighted = category
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.4)) { self?.highlighted = nil } }
        }
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
        Module.allCases.filter { state($0) != .available }
    }

    /// Сколько реально лежит на диске из скачанного.
    var buildMegabytes: Int {
        buildModules.contains(.voice)
            ? VoiceModel.allCases.filter { VoiceModelStore.isInstalled($0) }.reduce(0) { $0 + StoreCatalog.megabytes($1) } : 0
    }

    /// Доступы установленных модулей, которых ещё нет (системе придётся о них спросить).
    var newPermissions: [StorePermission] {
        // Доступы утилиты выдаются ей, а не центру.
        let all = Set(buildModules.filter { !modules.isExternal($0) }.flatMap { StoreCatalog.needs($0).map(\.permission) })
        return StorePermission.allCases.filter { all.contains($0) && $0.isGranted != true }
    }

    // MARK: Действия

    /// Включить, поставить в панель и скачать ресурсы. Остаёмся в Сторе: плитка станет «Установлен»,
    /// недостающая настройка — в плашке «Настроить», переход в модуль — кнопка «Открыть».
    func install(_ module: Module) {
        if let app = satellites.catalogApp(module) {
            modules.setHidden(module, false)
            runInstall(module, app)
            return
        }
        modules.setHidden(module, false)
        modules.setOn(module, true)
        downloadResources(module)
        showToast(module)
    }

    /// Незавершённая настройка установленного модуля: «Настройка 1 из 3». nil — всё готово или шагов нет.
    func pendingSetup(_ module: Module) -> SetupProgress? {
        // Чек-лист утилиты у неё самой, здесь были бы доступы центра.
        guard isInstalled(module), !modules.isExternal(module) else { return nil }
        let progress = module.setupProgress
        return progress.total > 0 && !progress.allDone ? progress : nil
    }

    /// Открыть чек-лист модуля поверх его экрана.
    func configure(_ module: Module) {
        SetupFlow.shared.show(module)
        openInApp(module)
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

    private func run(_ module: Module, fallback: String, _ work: @escaping () async throws -> Void) {
        guard operations[module] == nil else { return }
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
            return error.errorDescription ?? fallback
        case is LinkError:
            return "Модуль не ответил после запуска, прежняя версия возвращена"
        case is URLError:
            return "Не удалось скачать модуль: проверь сеть"
        default:
            return fallback
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

    /// Скачивание ресурсов модуля; там, где их нет, ничего не делает.
    func downloadResources(_ module: Module) {
        if satellites.hasUpdate(module), let app = satellites.catalogApp(module) {
            runInstall(module, app)
            return
        }
        if module == .voice, !VoiceModelStore.isInstalled(voice.selected) { voice.download(voice.selected) }
    }

    func cancel(_ module: Module) {
        operations[module]?.cancel()
        if module == .voice { voice.cancel(voice.selected) }
    }

    func requestRemoval(_ module: Module) { pendingRemoval = module }

    /// Выключить, стереть скачанное, снять скрытие (иначе модуль висел бы в «Скрытых»). Настройки модуля не трогаем.
    func remove(_ module: Module) {
        guard satellites.hasBundle(module) else {
            removeBuiltIn(module)
            return
        }
        pendingRemoval = nil
        run(module, fallback: "Не удалось удалить модуль") {
            try await self.satellites.uninstall(module)
            self.removeBuiltIn(module)
        }
    }

    private func removeBuiltIn(_ module: Module) {
        modules.setOn(module, false)
        modules.setHidden(module, false)
        if module == .voice {
            for model in VoiceModel.allCases where voice.status(model) != .notInstalled { voice.delete(model) }
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
