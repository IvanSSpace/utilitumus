import Foundation
import AppKit
import ApplicationServices

/// Модуль «Мышь»: держит tap на прокрутку, пока он нужен. Если все настройки
/// «как у системы» или нет доступа, tap не существует вовсе.
@MainActor
final class MouseController: MouseModel {
    static let shared = MouseController()

    @Published var settings: MouseSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            engine.settings = settings
            reconcile()
        }
    }
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    /// Tap создан и включён.
    @Published private(set) var tapActive = false

    private let engine = MouseScrollEngine()
    private let tap: MouseScrollTap
    private var started = false
    private var poll: Timer?

    init() {
        let loaded = MouseSettings.load()
        settings = loaded
        engine.settings = loaded
        tap = MouseScrollTap(engine: engine)
    }

    func start() {
        guard !started else { return }
        started = true
        // Доступ дают в Системных настройках, а tap могла выключить система:
        // раз в пару секунд проверяем и то и другое.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    /// Выключение модуля: tap снят полностью, анимация оборвана.
    func stop() {
        started = false
        poll?.invalidate()
        poll = nil
        tap.stop()
        tapActive = false
    }

    func refreshAccess() {
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted { axTrusted = trusted }
    }

    func requestAccess() {
        #if KIT_TEST_DEFAULTS
        // Стенд не показывает системный запрос и не открывает настройки.
        testAccessRequests += 1
        #else
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    #if KIT_TEST_DEFAULTS
    private(set) var testAccessRequests = 0

    /// Стенд ставит состояние для снимка: без настоящего tap и прав.
    func testPin(axTrusted: Bool, tapActive: Bool) {
        self.axTrusted = axTrusted
        self.tapActive = tapActive
    }
    #endif

    private func reconcile() {
        guard started else { return }
        refreshAccess()
        let wanted = settings.needsTap && axTrusted
        if tap.isRunning && (!wanted || !tap.isEnabled) {
            // Не нужен, права отозвали или система выключила и не включила обратно.
            tap.stop()
        }
        if wanted && !tap.isRunning { _ = tap.start() }
        let active = tap.isRunning && tap.isEnabled
        if active != tapActive { tapActive = active }
    }
}
