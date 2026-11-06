import Foundation
import AppKit
import CoreGraphics

/// Модуль «Клавиатура» — набор фишек (`KeyboardFeature`). Работают включённые; ресурсы поднимаются только
/// под них: без «Языка по Fn» tap не создаётся, без «Раскладки для каждого приложения» нет слежения за приложениями.
///
/// «Язык по Fn»: tap только слушает (listenOnly) и ничего не меняет в потоке событий. Он создаётся при включении
/// фишки и снимается при выключении. Пока она включена, раз в 30 с дешёвая проверка, что tap жив;
/// после сна, разблокировки и смены сессии он пересоздаётся. Висит на главном цикле: TIS можно звать только оттуда.
///
/// «Раскладка для каждого приложения»: слушает активацию приложений, раскладку каждого помнит по bundle id.
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
    /// Включённые фишки.
    @Published private(set) var features: Set<KeyboardFeature>
    /// Включённые в системе раскладки: для выбора «Новые приложения начинают с».
    @Published private(set) var layouts: [LayoutItem] = []
    /// Раскладка для приложений, которых ещё не видели; nil — «как было».
    @Published var newAppLayout: String? {
        didSet {
            memory.newAppLayout = newAppLayout
            UserDefaults.standard.set(newAppLayout, forKey: Self.newAppKey)
        }
    }
    /// Приложения, где раскладку не трогаем (в порядке добавления).
    @Published private(set) var excludedApps: [String]

    typealias LayoutItem = KeyboardLayoutItem

    private static let savedKey = "Keyboard.AppLayout.Saved"
    private static let excludedKey = "Keyboard.AppLayout.Excluded"
    private static let newAppKey = "Keyboard.AppLayout.NewStart"

    private var detector: FnTapDetector
    private var picker = LayoutPicker()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// Модуль включён.
    private var started = false
    /// Какие фишки сейчас держат ресурсы.
    private var fnRunning = false
    private var appRunning = false
    private var memory: AppLayoutMemory
    /// Приложение на переднем плане, которому приписываются смены раскладки; nil — наше или не знаем.
    private var frontApp: String?
    private var tapObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var healthTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        let trigger = FnTrigger(rawValue: defaults.string(forKey: "Keyboard.Trigger") ?? "") ?? .onRelease
        let mode = LayoutMode(rawValue: defaults.string(forKey: "Keyboard.Mode") ?? "") ?? .lastTwo
        self.trigger = trigger
        self.mode = mode
        features = Set(KeyboardFeature.enabled)
        let excluded = defaults.stringArray(forKey: Self.excludedKey) ?? []
        excludedApps = excluded
        let newApp = defaults.string(forKey: Self.newAppKey)
        newAppLayout = newApp
        memory = AppLayoutMemory(saved: defaults.dictionary(forKey: Self.savedKey) as? [String: String] ?? [:],
                                 excluded: Set(excluded), newAppLayout: newApp)
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
        applyFeatures()
        let names = features.isEmpty ? "ни одной фишки" : KeyboardFeature.enabled.map(\.shortName).joined(separator: ", ")
        note("модуль включён (\(names)), tap \(fnRunning ? (port == nil ? "не создан" : "создан") : "не нужен")")
    }

    /// Выключение модуля пользователем: всё снято, системное действие 🌐 возвращено, если его меняли мы.
    func stop() {
        teardown()
        FnSystemAction.restore()
        refreshSystem()
    }

    /// Выход из приложения: всё снято, а «отключено» остаётся в системе и применится при следующем запуске.
    func quit() {
        teardown()
    }

    private func teardown() {
        started = false
        stopFn(restore: false)
        stopApp()
        syncShared()
    }

    // MARK: Фишки

    func isOn(_ feature: KeyboardFeature) -> Bool { features.contains(feature) }

    /// Переключатель фишки на экране. Поднимает или снимает её ресурсы, если модуль включён.
    func setFeature(_ feature: KeyboardFeature, on: Bool) {
        guard feature.isAvailable, on != features.contains(feature) else { return }
        feature.isOn = on
        features = Set(KeyboardFeature.enabled)
        if started {
            applyFeatures()
            note("фишка «\(feature.title)» \(on ? "включена" : "выключена")")
        }
        // Шаги настройки модуля зависят от включённых фишек.
        AccessState.shared.refresh()
    }

    /// Привести ресурсы в соответствие с включёнными фишками. Идемпотентно.
    private func applyFeatures() {
        guard started else { return }
        let fn = features.contains(.fnLanguage), app = features.contains(.perAppLayout)
        if fn && !fnRunning { startFn() }
        if !fn && fnRunning { stopFn(restore: true) }
        if app && !appRunning { startApp() }
        if !app && appRunning { stopApp() }
        syncShared()
    }

    /// Наблюдатели, общие для фишек: смена раскладки и активация приложения. Нужны, пока работает хоть одна.
    private func syncShared() {
        let need = started && (fnRunning || appRunning)
        if need && observer == nil {
            // Смену раскладки следим сами: «между двумя последними» должен знать и о смене из меню.
            observer = DistributedNotificationCenter.default().addObserver(
                forName: InputSources.changedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutChanged() }
            }
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.appActivated(app) }
            }
        } else if !need {
            if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
            observer = nil
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
            activationObserver = nil
        }
    }

    private func appActivated(_ app: NSRunningApplication?) {
        // Защищённый ввод проверяем при смене активного приложения, без таймера.
        if fnRunning {
            refreshSecureInput()
            enforceSystemAction()
        }
        if appRunning { enterApp(app) }
    }

    private func startFn() {
        fnRunning = true
        observeTapEvents()
        // Пользователь просил отключить системное действие: после перезапуска применяем снова.
        FnSystemAction.migrateKeepOff()
        enforceSystemAction()
        refreshAccess()
        refreshSystem()
        createTap()
    }

    /// `restore` — фишку выключил пользователь: системное действие 🌐 возвращаем, как при выключении модуля.
    private func stopFn(restore: Bool) {
        guard fnRunning else { return }
        fnRunning = false
        removeTap()
        for item in tapObservers { item.center.removeObserver(item.token) }
        tapObservers = []
        healthTimer?.invalidate()
        healthTimer = nil
        secureInputApp = nil
        if restore {
            FnSystemAction.restore()
            refreshSystem()
        }
    }

    // MARK: Раскладка для каждого приложения

    private func startApp() {
        appRunning = true
        enterApp(NSWorkspace.shared.frontmostApplication, restore: false)
    }

    private func stopApp() {
        appRunning = false
        frontApp = nil
    }

    /// Вошли в приложение: вернуть его раскладку. `restore: false` — только запомнить текущую (старт фишки).
    private func enterApp(_ app: NSRunningApplication?, restore: Bool = true) {
        // Наше окно раскладку не меняет и смены в нём ни к какому приложению не приписываем.
        guard let id = app?.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
            frontApp = nil
            return
        }
        frontApp = id
        let list = InputSources.enabled()
        let current = InputSources.current()
        if restore, let wanted = memory.layout(for: id, enabled: list.map(\.id)),
           wanted != current?.id, let target = list.first(where: { $0.id == wanted }) {
            InputSources.select(target)
            // Имя программы в журнал не идёт: иначе он становится историей пользования.
            note("раскладка приложения восстановлена → \(target.name)")
        } else if let current {
            // Нечего возвращать: приложение начинает с текущей раскладки, её и запоминаем.
            rememberLayout(current.id, in: id)
        }
    }

    private func rememberLayout(_ layout: String, in app: String) {
        guard memory.remember(layout: layout, in: app) else { return }
        UserDefaults.standard.set(memory.saved, forKey: Self.savedKey)
    }

    func addExcluded(_ id: String) {
        guard !excludedApps.contains(id) else { return }
        excludedApps.append(id)
        saveExcluded()
    }

    func removeExcluded(_ id: String) {
        excludedApps.removeAll { $0 == id }
        saveExcluded()
    }

    private func saveExcluded() {
        memory.excluded = Set(excludedApps)
        UserDefaults.standard.set(excludedApps, forKey: Self.excludedKey)
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
        guard fnRunning else { return }
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
    /// их вернула (в том числе «OK» в окне «Включить диктовку?»), молча чиним. Дёшево: два чтения
    /// настроек; пока всё на месте, систему не трогаем. Зовётся при активации приложения и раз в 30 с.
    private func enforceSystemAction() {
        guard fnRunning else { return }
        let fixed = FnSystemAction.reapplyAll()
        if fixed.usageFixed {
            note("macOS вернула действие 🌐 (было \(fixed.previousUsage.map(String.init) ?? "нет значения")) — исправлено")
        }
        if fixed.dictationFixed { note("диктовка на двойном Fn вернулась — исправлено") }
        if fixed.any { refreshSystem() }
    }

    /// «Починить»: системное действие 0, перезапуск системного переключателя, новый tap, сверка раскладки.
    func repair() {
        guard fnRunning else {
            repairResult = started ? "Фишка «Язык по Fn» выключена: сначала включи её" : "Модуль выключен: сначала включи его"
            return
        }
        // Если там уже 0, настройки и переключатель macOS не трогаем.
        let changed = FnSystemAction.disable()
        rebuildTap(reason: "починка")
        if let now = InputSources.current() {
            picker.didChange(to: now.id)
            currentName = now.name
        }
        refreshSystem()
        let tap = port == nil ? "tap не создан (нет доступа «Мониторинг ввода»?)" : "tap пересоздан"
        let action = changed ? "Системное действие 🌐 отключено, переключатель macOS перезапущен" : "Системное действие 🌐 уже отключено"
        repairResult = "\(action), \(tap), раскладка «\(currentName)»"
        note("починка: \(repairResult ?? "")")
    }

    /// Снять диктовку с двойного Fn; прежнее состояние вернётся при выключении модуля.
    func disableDictationDoubleFn() {
        FnSystemAction.disableDictation()
        refreshSystem()
        note("диктовка снята с двойного Fn")
    }

    /// Сразу и действие 🌐, и диктовка на двойном Fn: все записи, потом одно применение настроек.
    func disableAllSystemActions() {
        let changed = FnSystemAction.disableAll()
        refreshSystem()
        note(changed ? "системное действие 🌐 и диктовка отключены" : "системное действие 🌐 и диктовка уже отключены")
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
        if fnRunning && port == nil && granted { createTap() }
        if let now = InputSources.current(), now.name != currentName { currentName = now.name }
        let list = InputSources.enabled().map { LayoutItem(id: $0.id, name: $0.name) }
        if list != layouts { layouts = list }
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
        let owner = fnRunning ? SecureInput.owner() : nil
        if owner != secureInputApp {
            secureInputApp = owner
            note(owner == nil ? "защищённый ввод снят" : "защищённый ввод включён: Fn не слышно")
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
                guard let self, self.fnRunning else { return }
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
        // Смену в приложении (наша, системная или из меню) запоминаем за ним.
        if appRunning, let frontApp { rememberLayout(now.id, in: frontApp) }
    }
}
