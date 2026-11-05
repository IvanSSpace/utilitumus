import SwiftUI

// Стор (прототип): витрина-настройщик. Код модулей уже в приложении, стор лишь «устанавливает» —
// в прототипе это локальное состояние в памяти. Настоящие модули не включаются и не выключаются.

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

/// Что скачивается при установке и куда ложится.
struct StoreDownload {
    let megabytes: Int
    let kind: String
    let path: String
}

// MARK: - Каталог

enum StoreCatalog {
    static func downloads(_ m: Module) -> StoreDownload? {
        m == .voice ? StoreDownload(megabytes: 170, kind: "модель",
                                    path: "~/Library/Application Support/Utilitumus/Voice/") : nil
    }

    static func needs(_ m: Module) -> [StoreNeed] {
        switch m {
        case .fans: return [StoreNeed(permission: .rootHelper, why: "Пароль администратора, один раз: помощник управляет вентиляторами")]
        case .stash: return [StoreNeed(permission: .accessibility, why: "Чтобы вернуть окна программ на места")]
        case .mouse: return [StoreNeed(permission: .accessibility, why: "Чтобы менять направление и плавность прокрутки")]
        case .keyboard: return [StoreNeed(permission: .inputMonitoring, why: "Чтобы заметить тап по Fn; ничего не записывается")]
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
        case .keyboard: return "Смена раскладки по Fn"
        case .awake: return "Mac не засыпает за работой"
        }
    }

    /// Что сотрётся при удалении.
    static func removal(_ m: Module) -> String {
        if let d = downloads(m) { return "Скачанная \(d.kind) (\(d.megabytes) МБ) и настройки модуля" }
        if needs(m).contains(where: { $0.permission == .rootHelper }) { return "Настройки модуля и root-помощник" }
        if m == .clipboard { return "Сохранённая история, пространства и настройки" }
        return "Только настройки модуля, программа остаётся целой"
    }

    /// Короткая подпись размера для плитки и карточки.
    static func sizeText(_ m: Module, short: Bool = false) -> String {
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

enum StoreItemID: Hashable {
    case module(Module)
    case pack(String)
}

enum StoreStage: Int, CaseIterable {
    case download, verify, permissions

    var title: String {
        switch self {
        case .download: return "Скачивание"
        case .verify: return "Проверка подписи"
        case .permissions: return "Разрешения"
        }
    }
}

enum StoreState: Equatable {
    case available
    /// Этап и доля внутри него (0…1).
    case installing(StoreStage, Double)
    case installed
}

enum StoreTab: String, CaseIterable, Hashable {
    case showcase, packs
    var title: String { self == .showcase ? "Витрина" : "Наборы контента" }
}

@MainActor
final class StoreModel: ObservableObject {
    static let shared = StoreModel()

    @Published private(set) var states: [StoreItemID: StoreState] = [:]
    /// Установленное, для чего есть новые ресурсы.
    @Published private(set) var updates: Set<StoreItemID> = []
    @Published var tab: StoreTab = .showcase
    @Published var detail: Module?
    /// Разрешения, выданные до стора: у уже включённых модулей они есть.
    let baseGranted: Set<StorePermission>

    /// Рекомендация дня.
    static let featured: Module = .voice

    /// Во сколько раз замедлить имитацию (для снимков).
    var slowdown = 1.0
    private var tasks: [StoreItemID: Task<Void, Never>] = [:]
    private var before: [StoreItemID: StoreState] = [:]

    init() {
        baseGranted = Set(Module.allCases.filter { ModuleManager.shared.isOn($0) }
            .flatMap { StoreCatalog.needs($0).map(\.permission) })
        // Старт — из реального «включён», дальше состояние живёт только здесь.
        for module in Module.allCases {
            states[.module(module)] = ModuleManager.shared.isOn(module) ? .installed : .available
        }
        if states[.module(.voice)] == .installed {
            updates.insert(.module(.voice))
            states[.pack("v-ru-s")] = .installed
        }
    }

    func state(_ id: StoreItemID) -> StoreState { states[id] ?? .available }
    func state(_ module: Module) -> StoreState { state(.module(module)) }
    func hasUpdate(_ id: StoreItemID) -> Bool { updates.contains(id) }

    // MARK: Окно подробностей

    func open(_ module: Module) {
        withAnimation(.easeInOut(duration: 0.2)) { detail = module }
    }

    func close() {
        withAnimation(.easeInOut(duration: 0.2)) { detail = nil }
    }

    // MARK: Сборка

    /// Модули, которые стоят или ставятся.
    var buildModules: [Module] {
        Module.allCases.filter { m in
            switch state(m) {
            case .available: return false
            default: return true
            }
        }
    }

    var buildMegabytes: Int { buildModules.reduce(0) { $0 + (StoreCatalog.downloads($1)?.megabytes ?? 0) } }

    /// Разрешения сборки, которых до стора не было.
    var newPermissions: [StorePermission] {
        let all = buildModules.flatMap { StoreCatalog.needs($0).map(\.permission) }
        let new = Set(all).subtracting(baseGranted)
        return StorePermission.allCases.filter(new.contains)
    }

    // MARK: Установка (имитация)

    func install(_ id: StoreItemID) {
        let hasDownload: Bool
        let hasPermissions: Bool
        switch id {
        case .module(let m):
            hasDownload = StoreCatalog.downloads(m) != nil
            hasPermissions = !StoreCatalog.needs(m).isEmpty
        case .pack:
            hasDownload = true
            hasPermissions = false
        }
        // Секунды на этап: пустой этап (нечего скачивать, нет разрешений) пролетает быстро.
        let plan: [(StoreStage, Double)] = [(.download, hasDownload ? 1.6 : 0.25),
                                            (.verify, hasDownload ? 0.7 : 0.3),
                                            (.permissions, hasPermissions ? 1.1 : 0.25)]
        run(id, plan: plan)
    }

    /// Обновление ресурсов: только скачивание и проверка подписи.
    func update(_ id: StoreItemID) {
        run(id, plan: [(.download, 1.2), (.verify, 0.6)])
    }

    func cancel(_ id: StoreItemID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = before[id] ?? .available
    }

    func remove(_ id: StoreItemID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = .available
        updates.remove(id)
    }

    private func run(_ id: StoreItemID, plan: [(StoreStage, Double)]) {
        guard tasks[id] == nil else { return }
        before[id] = state(id) == .installed ? .installed : .available
        let slow = slowdown
        tasks[id] = Task { @MainActor [weak self] in
            let steps = 20
            for (stage, seconds) in plan {
                for step in 0...steps {
                    if Task.isCancelled { return }
                    self?.states[id] = .installing(stage, Double(step) / Double(steps))
                    try? await Task.sleep(nanoseconds: UInt64(seconds * slow / Double(steps) * 1e9))
                }
            }
            guard let self, !Task.isCancelled else { return }
            states[id] = .installed
            updates.remove(id)
            tasks[id] = nil
        }
    }
}

extension DSTheme {
    /// Акцент страницы стора: спокойный серо-синий, не цвет рекомендованного модуля.
    func storeTint() -> Color {
        self == .graphite ? Color.accentColor : Color(hue: 0.60, saturation: 0.28, brightness: 0.90)
    }
}
