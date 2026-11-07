import Foundation
import IOKit.pwr_mgt

/// «Не спать»: держит assertion в IOKit, пока активно. Модуль включён ≠ активно:
/// включённый модуль только доступен, assertion появляется после кнопки.
@MainActor
final class AwakeController: AwakeModel {
    static let shared = AwakeController()

    @Published private(set) var isActive = false
    /// Когда assertion снимется сам; nil — «пока не выключу».
    @Published private(set) var endDate: Date?
    @Published var keepDisplay: Bool {
        didSet {
            Kit.defaults.set(keepDisplay, forKey: Self.displayKey)
            if isActive { applyAssertions() }
        }
    }
    @Published var duration: AwakeDuration {
        didSet { Kit.defaults.set(duration.rawValue, forKey: Self.durationKey) }
    }

    /// Можно ли включить блокировку. Отдельное приложение запрещает это, пока модуль ведёт центр.
    @Published var canStart = true

    static let displayKey = AwakeKeys.display
    static let durationKey = AwakeKeys.duration
    /// Имя в `pmset -g assertions`. Латиница: с кириллицей pmset показывает пустое имя.
    private static let reason = "Utilitumus: Keep Awake" as CFString

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: DispatchSourceTimer?

    private init() {
        let defaults = Kit.defaults
        keepDisplay = defaults.bool(forKey: Self.displayKey)
        duration = AwakeDuration(rawValue: defaults.integer(forKey: Self.durationKey)) ?? .forever
    }

    /// Хук модуля: включили модуль — ничего не держим, пока не нажата кнопка. Настройки читаем заново: пока модуль
    /// стоял, их могла поменять утилита или центр (домен настроек один), а `didSet` записал бы в него старые.
    func start() {
        let defaults = Kit.defaults
        // Запись другого процесса: без этого может прийти значение из кэша.
        defaults.synchronize()
        let display = defaults.bool(forKey: Self.displayKey)
        let saved = AwakeDuration(rawValue: defaults.integer(forKey: Self.durationKey)) ?? .forever
        // Только изменившееся: иначе `didSet` записал бы отсутствующий ключ и разбудил бы всех подписчиков.
        if keepDisplay != display { keepDisplay = display }
        if duration != saved { duration = saved }
    }
    /// Выключили модуль или вышли из приложения — assertion обязательно снимается.
    func stop() { deactivate() }

    func toggle() {
        if isActive { deactivate() } else if canStart { activate() }
    }

    func activate() {
        deactivate()
        applyAssertions()
        guard systemAssertion != 0 else { return }
        isActive = true
        guard duration != .forever else { return }
        endDate = Date().addingTimeInterval(TimeInterval(duration.rawValue))
        // Стенные часы: Mac мог поспать, а срок всё равно идёт.
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(wallDeadline: .now() + TimeInterval(duration.rawValue))
        source.setEventHandler { MainActor.assumeIsolated { AwakeController.shared.deactivate() } }
        source.resume()
        timer = source
    }

    func deactivate() {
        timer?.cancel()
        timer = nil
        endDate = nil
        release(&systemAssertion)
        release(&displayAssertion)
        isActive = false
    }

    /// Системный assertion всегда, экранный — по опции.
    private func applyAssertions() {
        if systemAssertion == 0 {
            systemAssertion = create(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
        }
        if keepDisplay {
            if displayAssertion == 0 {
                displayAssertion = create(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
            }
        } else {
            release(&displayAssertion)
        }
    }

    private func create(_ type: CFString) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.reason, &id)
        return result == kIOReturnSuccess ? id : 0
    }

    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    #if KIT_TEST_DEFAULTS
    /// Стенд ставит состояние для снимка: без настоящего assertion и с заданным сроком.
    func testPin(isActive: Bool, endDate: Date?) {
        self.isActive = isActive
        self.endDate = endDate
    }
    #endif
}
