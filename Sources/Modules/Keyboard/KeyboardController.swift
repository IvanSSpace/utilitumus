import Foundation
import AppKit
import CoreGraphics

/// Модуль «Клавиатура»: мгновенная смена раскладки по тапу Fn/🌐.
/// Tap только слушает (listenOnly) и ничего не меняет в потоке событий. Он создаётся при включении
/// модуля и снимается при выключении, таймера нет. Висит на главном цикле: TIS можно звать только оттуда.
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

    private var detector: FnTapDetector
    private var picker = LayoutPicker()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    private var started = false

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
        refreshAccess()
        createTap()
    }

    /// Выключение модуля: tap снят, системное действие 🌐 возвращено, если его меняли мы.
    func stop() {
        started = false
        removeTap()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        FnSystemAction.restore()
        refreshSystem()
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
        if detector.handle(fnEvent) { switchLayout() }
    }

    // MARK: Раскладки

    private func switchLayout() {
        let list = InputSources.enabled()
        guard let id = picker.next(in: list.map(\.id)), let target = list.first(where: { $0.id == id }) else { return }
        InputSources.select(target)
        // Имя и память «предыдущей» обновит уведомление системы.
    }

    private func layoutChanged() {
        guard let now = InputSources.current() else { return }
        picker.didChange(to: now.id)
        currentName = now.name
    }
}
