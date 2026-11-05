import Foundation
import AppKit
import CoreGraphics

/// Модуль «Клавиатура»: мгновенная смена раскладки по тапу Fn/🌐.
/// Tap только слушает (listenOnly) и ничего не меняет в потоке событий. Он создаётся при включении
/// модуля и снимается при выключении. Пока модуль включён, раз в 30 с дешёвая проверка, что tap жив;
/// после сна, разблокировки и смены сессии он пересоздаётся. Висит на главном цикле: TIS можно звать только оттуда.
@MainActor
final class KeyboardController: ObservableObject {
    static let shared = KeyboardController()

    @Published var trigger: FnTrigger {
        didSet { UserDefaults.standard.set(trigger.rawValue, forKey: "Keyboard.Trigger"); detector.trigger = trigger }
    }
    @Published var mode: LayoutMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "Keyboard.Mode"); picker.mode = mode }
    }
    @Published private(set) var currentName = "—"
    @Published private(set) var tapActive = false
    @Published private(set) var inputAccess = CGPreflightListenEventAccess()
    /// Значения системных настроек, которые могут сработать вместе с нами. Обновляются по событиям.
    @Published private(set) var systemUsage = FnSystemAction.usage
    @Published private(set) var dictationConflict = FnSystemAction.dictationOnDoubleFn
    /// Приложение, из-за которого включён защищённый ввод и Fn не слышно.
    @Published private(set) var secureInputApp: String?
    /// Последние записи журнала для экрана и их общее число.
    @Published private(set) var logTail: [KeyboardLog.Entry] = []
    @Published private(set) var logCount = 0
    /// Итог последнего нажатия «Починить».
    @Published private(set) var repairResult: String?

    private var detector: FnTapDetector
    private var picker = LayoutPicker()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var started = false
    private var tapObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var healthTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        let trigger = FnTrigger(rawValue: defaults.string(forKey: "Keyboard.Trigger") ?? "") ?? .onRelease
        let mode = LayoutMode(rawValue: defaults.string(forKey: "Keyboard.Mode") ?? "") ?? .lastTwo
        self.trigger = trigger
        self.mode = mode
        detector = FnTapDetector(trigger: trigger)
        picker.mode = mode
    }

    // MARK: Запуск и остановка

    func start() {
        guard !started else { return }
        started = true
        if let now = InputSources.current() {
            picker.didChange(to: now.id)
            currentName = now.name
        }
        // Смену раскладки следим сами: «между двумя последними» должен знать и о смене из меню.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: InputSources.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutChanged() }
        }
        // Защищённый ввод проверяем при смене активного приложения, без таймера.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSecureInput()
                self?.enforceSystemAction()
            }
        }
        observeTapEvents()
        // Пользователь просил отключить системное действие: после перезапуска применяем снова.
        enforceSystemAction()
        refreshAccess()
        refreshSystem()
        createTap()
        note("модуль включён, tap \(port == nil ? "не создан" : "создан")")
    }

    /// Выключение модуля пользователем: tap снят, системное действие 🌐 возвращено, если его меняли мы.
    func stop() {
        teardown()
        FnSystemAction.restore()
        refreshSystem()
    }

    /// Выход из приложения: tap снят, а «отключено» остаётся в системе и применится при следующем запуске.
    func quit() {
        teardown()
    }

    private func teardown() {
        started = false
        removeTap()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        for item in tapObservers { item.center.removeObserver(item.token) }
        tapObservers = []
        healthTimer?.invalidate()
        healthTimer = nil
        secureInputApp = nil
    }

    // MARK: Самовосстановление tap

    /// Сон, разблокировка и возврат сессии могут тихо убить tap: после них создаём его заново.
    private func observeTapEvents() {
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ reason: String) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildTap(reason: reason) }
            }
            tapObservers.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.didWakeNotification, "после пробуждения")
        add(workspace, NSWorkspace.sessionDidBecomeActiveNotification, "сессия снова активна")
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), "после разблокировки")

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTapHealth() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func rebuildTap(reason: String) {
        guard started else { return }
        removeTap()
        refreshAccess()
        if port == nil && inputAccess { createTap() }
        note("tap пересоздан (\(reason)): \(port == nil ? "не удалось" : "ок")")
    }

    /// Ничего не трогаем, пока tap в порядке.
    private func checkTapHealth() {
        enforceSystemAction()
        refreshAccess()
        guard let port else { return }  // нет доступа или не создан: refreshAccess сам создаст, когда можно
        switch TapHealth.check(valid: CFMachPortIsValid(port), enabled: CGEvent.tapIsEnabled(tap: port)) {
        case .ok:
            break
        case .reenable:
            CGEvent.tapEnable(tap: port, enable: true)
            if CGEvent.tapIsEnabled(tap: port) {
                note("tap был выключен, включён снова (проверка)")
            } else {
                rebuildTap(reason: "не включается")
            }
        case .rebuild:
            rebuildTap(reason: "порт недействителен")
        }
    }

    /// Если пользователь просил отключить системное действие (и диктовку на двойном Fn), а система
    /// их вернула, чиним сами. Дёшево: два чтения настроек.
    private func enforceSystemAction() {
        guard started else { return }
        if FnSystemAction.reapplyIfNeeded() {
            note("системное действие 🌐 вернулось — исправлено")
            refreshSystem()
        }
        if FnSystemAction.reapplyDictationIfNeeded() {
            note("диктовка на двойном Fn вернулась — исправлено")
            refreshSystem()
        }
    }

    /// «Починить»: системное действие 0, перезапуск системного переключателя, новый tap, сверка раскладки.
    func repair() {
        guard started else {
            repairResult = "Модуль выключен: сначала включи его"
            return
        }
        FnSystemAction.disable()  // пишет 0, activateSettings -u и перезапуск TextInputSwitcher идут фоном
        rebuildTap(reason: "починка")
        if let now = InputSources.current() {
            picker.didChange(to: now.id)
            currentName = now.name
        }
        refreshSystem()
        let tap = port == nil ? "tap не создан (нет доступа «Мониторинг ввода»?)" : "tap пересоздан"
        repairResult = "Системное действие 🌐 отключено, переключатель macOS перезапущен, \(tap), раскладка «\(currentName)»"
        note("починка: \(repairResult ?? "")")
    }

    /// Снять диктовку с двойного Fn; прежнее состояние вернётся при выключении модуля.
    func disableDictationDoubleFn() {
        FnSystemAction.disableDictation()
        refreshSystem()
        note("диктовка снята с двойного Fn")
    }

    // MARK: Журнал

    private func note(_ text: String) {
        KeyboardLog.shared.add(text)
        logTail = KeyboardLog.shared.recent(8)
        logCount = KeyboardLog.shared.count
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(KeyboardLog.shared.text(), forType: .string)
    }

    // MARK: Доступ и системные настройки

    func refreshAccess() {
        let granted = CGPreflightListenEventAccess()
        if granted != inputAccess { inputAccess = granted }
        // Доступ могли выдать, пока модуль включён: tap создаём, как только можно.
        if started && port == nil && granted { createTap() }
        if let now = InputSources.current(), now.name != currentName { currentName = now.name }
    }

    func requestAccess() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSystem() {
        let usage = FnSystemAction.usage
        if usage != systemUsage { systemUsage = usage }
        let dictation = FnSystemAction.dictationOnDoubleFn
        if dictation != dictationConflict { dictationConflict = dictation }
        refreshSecureInput()
    }

    func refreshSecureInput() {
        let owner = started ? SecureInput.owner() : nil
        if owner != secureInputApp {
            secureInputApp = owner
            note(owner.map { "защищённый ввод в \($0): Fn не слышно" } ?? "защищённый ввод снят")
        }
    }

    /// Записать «ничего не делать» для 🌐 в системе; прежнее значение запомнено для отката.
    func disableSystemAction() {
        FnSystemAction.disable()
        refreshSystem()
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Tap

    private func createTap() {
        guard port == nil else { return }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        var mask: CGEventMask = 0
        for type in types { mask |= CGEventMask(1) << type.rawValue }
        mask |= CGEventMask(1) << 14  // NX_SYSDEFINED: медиа-клавиши, Fn+F-ряд

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyboardController>.fromOpaque(refcon).takeUnretainedValue()
            // Tap стоит на главном цикле, значит колбэк идёт на главном потоке.
            MainActor.assumeIsolated { me.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            tapActive = false
            return
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapActive = true
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        source = nil
        port = nil
        tapActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let fnEvent: FnEvent
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Система выключила tap: включаем обратно.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            note("tap выключен системой (\(type == .tapDisabledByTimeout ? "таймаут" : "ввод")), включён снова")
            return
        case .flagsChanged:
            let flags = event.flags
            if event.getIntegerValueField(.keyboardEventKeycode) == 63 {
                let others = !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
                fnEvent = .fn(down: flags.contains(.maskSecondaryFn), others: others)
            } else {
                fnEvent = .modifier
            }
        case .keyDown:
            fnEvent = .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            fnEvent = .mouseDown
        default:
            // Тип 14: подтип 8 — медиа-клавиши (яркость, громкость, F-ряд); остальные нас не касаются.
            guard type.rawValue == 14, NSEvent(cgEvent: event)?.subtype.rawValue == 8 else { return }
            fnEvent = .sysDefined
        }
        let fire = detector.handle(fnEvent)
        if let cancel = detector.cancelledBy { note("Fn: тап сброшен (\(Self.describe(cancel)))") }
        if fire {
            note("Fn: тап распознан")
            switchLayout()
        }
    }

    /// Только тип события, без кодов клавиш.
    private static func describe(_ event: FnEvent) -> String {
        switch event {
        case .keyDown: return "клавиша"
        case .mouseDown: return "клик мыши"
        case .sysDefined: return "медиа-клавиша"
        case .modifier: return "модификатор"
        case .fn: return "Fn"
        }
    }

    // MARK: Раскладки

    private func switchLayout() {
        // Уведомление о смене могли пропустить (авто-выбор раскладки документа): сверяемся с системой.
        if let now = InputSources.current() { picker.didChange(to: now.id) }
        let list = InputSources.enabled()
        guard let id = picker.next(in: list.map(\.id)), let target = list.first(where: { $0.id == id }) else { return }
        let from = InputSources.current()?.id ?? "?"
        InputSources.select(target)
        // Имя и память «предыдущей» обновит уведомление системы.
        verifySwitch(from: from, to: target.id, retried: false)
    }

    /// Через ~80 мс читаем раскладку: не сменилась — повторяем select один раз, потом пишем в журнал.
    private func verifySwitch(from: String, to id: String, retried: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                let actual = InputSources.current()?.id
                switch SwitchCheck.after(target: id, actual: actual, retried: retried) {
                case .done:
                    self.note("переключено \(from) → \(id): ок\(retried ? " (со 2-й попытки)" : "")")
                case .retry:
                    if let target = InputSources.enabled().first(where: { $0.id == id }) { InputSources.select(target) }
                    self.verifySwitch(from: from, to: id, retried: true)
                case .failed:
                    self.note("переключено \(from) → \(id): не сработало (сейчас \(actual ?? "?"))")
                }
            }
        }
    }

    private func layoutChanged() {
        guard let now = InputSources.current() else { return }
        picker.didChange(to: now.id)
        currentName = now.name
    }
}
