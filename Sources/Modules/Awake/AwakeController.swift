import Foundation
import IOKit.pwr_mgt

/// На сколько включать «Не спать».
enum AwakeDuration: Int, CaseIterable {
    case forever = 0, hour1 = 3600, hour2 = 7200, hour4 = 14400

    var title: String {
        switch self {
        case .forever: return "Пока не выключу"
        case .hour1: return "1 ч"
        case .hour2: return "2 ч"
        case .hour4: return "4 ч"
        }
    }
}

/// «Не спать»: держит assertion в IOKit, пока активно. Модуль включён ≠ активно:
/// включённый модуль только доступен, assertion появляется после кнопки.
@MainActor
final class AwakeController: ObservableObject {
    static let shared = AwakeController()

    @Published private(set) var isActive = false
    /// Когда assertion снимется сам; nil — «пока не выключу».
    @Published private(set) var endDate: Date?
    @Published var keepDisplay: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplay, forKey: Self.displayKey)
            if isActive { applyAssertions() }
        }
    }
    @Published var duration: AwakeDuration {
        didSet { UserDefaults.standard.set(duration.rawValue, forKey: Self.durationKey) }
    }

    private static let displayKey = "AwakeKeepDisplay"
    private static let durationKey = "AwakeDuration"
    /// Имя в `pmset -g assertions`. Латиница: с кириллицей pmset показывает пустое имя.
    private static let reason = "Utilitumus: Keep Awake" as CFString

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: DispatchSourceTimer?

    private init() {
        let defaults = UserDefaults.standard
        keepDisplay = defaults.bool(forKey: Self.displayKey)
        duration = AwakeDuration(rawValue: defaults.integer(forKey: Self.durationKey)) ?? .forever
    }

    /// Хук модуля: включили модуль — ничего не держим, пока не нажата кнопка.
    func start() {}
    /// Выключили модуль или вышли из приложения — assertion обязательно снимается.
    func stop() { deactivate() }

    func toggle() { isActive ? deactivate() : activate() }

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

    /// «1 ч 23 мин» / «12 мин» / «меньше минуты».
    static func remainingText(until end: Date, now: Date = Date()) -> String {
        let minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "меньше минуты" }
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }
}
