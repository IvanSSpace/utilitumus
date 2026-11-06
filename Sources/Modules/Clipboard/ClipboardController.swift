import SwiftUI
import AppKit
import Carbon.HIToolbox

/// «Буфер»: слежение за буфером обмена, пространства, горячая клавиша панели, вставка.
/// Пока модуль выключен, таймера и горячей клавиши нет, ничего не читается.
@MainActor
final class ClipboardController: ObservableObject {
    static let shared = ClipboardController()

    static let defaultKeyCode = UInt32(kVK_ANSI_V)
    static let defaultModifiers = UInt32(cmdKey | shiftKey)

    private enum Key {
        static let keyCode = "Clipboard.HotKeyCode"
        static let modifiers = "Clipboard.HotKeyModifiers"
        static let excluded = "Clipboard.ExcludedApps"
        static let limit = "Clipboard.Limit"
    }

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var spaces: [ClipSpace] = []
    @Published private(set) var keyCode: UInt32
    @Published private(set) var modifiers: UInt32
    @Published private(set) var excludedApps: [String]
    @Published private(set) var limit: Int
    @Published private(set) var hotKeyError: String?
    /// Не вышло получить ключ из Keychain: историю не ведём.
    @Published private(set) var storeError: String?
    /// История работает, но прежний индекс не открылся и отложен в файл.
    @Published private(set) var storeNotice: String?
    @Published private(set) var axTrusted = AXIsProcessTrusted()

    /// Последовательная: снимки приходят в том порядке, в каком буфер менялся.
    private static let readQueue = DispatchQueue(label: "local.utilitumus.clipboard.read", qos: .userInitiated)

    private(set) var store: ClipboardStore?
    private var isRunning = false
    private var timer: Timer?
    private var lastChange = 0
    /// changeCount после нашей собственной записи (вставка из панели): такую запись не запоминаем.
    private var ownChange = -1
    private var frontHistory = ClipFrontHistory()
    private var activationObserver: NSObjectProtocol?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeySuspended = false
    nonisolated fileprivate static let signature: OSType = 0x434C4950  // 'CLIP'

    private init() {
        let d = Kit.defaults
        keyCode = d.object(forKey: Key.keyCode) as? UInt32 ?? Self.defaultKeyCode
        modifiers = d.object(forKey: Key.modifiers) as? UInt32 ?? Self.defaultModifiers
        excludedApps = d.stringArray(forKey: Key.excluded) ?? ClipboardPolicy.defaultExcludedApps
        let saved = d.integer(forKey: Key.limit)
        limit = saved > 0 ? saved : ClipboardPolicy.defaultLimit
    }

    var hotKeyLabel: String { VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers) }

    // MARK: Запуск и остановка

    func start() {
        guard !isRunning else { return }
        isRunning = true
        openStore()
        lastChange = NSPasteboard.general.changeCount  // что лежало до включения — не берём
        frontHistory = ClipFrontHistory(current: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { ClipboardController.shared.frontHistory.activated(id) }
        }
        // Опрос changeCount — одно целое число; чтение содержимого только когда оно поменялось.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardController.shared.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        installHandler()
        registerHotKey()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        unregisterHotKey()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        ClipboardPanelHost.shared.hide()
    }

    private func openStore() {
        guard store == nil else { return }
        guard let key = try? ClipboardKeychain().key() else {
            storeError = "Не удалось получить ключ из Связки ключей — история не ведётся, старая не тронута"
            return
        }
        let opened = ClipboardStore(directory: ClipboardStore.defaultDirectory, key: key, limit: limit)
        guard opened.isAvailable else {
            storeError = "Не удалось открыть файл истории — история не ведётся, файл не тронут"
            return
        }
        storeError = nil
        storeNotice = opened.setAsideIndex.map { "Старая история не расшифровалась и отложена в файл \($0.lastPathComponent)" }
        attach(opened)
    }

    /// Подключить хранилище. Отдельно от `openStore`, чтобы стенд мог подставить своё, не трогая Keychain и диск.
    func attach(_ store: ClipboardStore) {
        self.store = store
        sync()
    }

    private func sync() {
        items = store?.items ?? []
        spaces = store?.spaces ?? []
    }

    // MARK: Слежение

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        guard count != ownChange, store != nil else { return }
        let front = NSWorkspace.shared.frontmostApplication
        // Из программ-исключений не берём, даже если запись пришла без скрытого типа и программа уже ушла с переднего плана.
        let sources = frontHistory.sources() + [front?.bundleIdentifier].compactMap { $0 }
        if sources.contains(where: excludedApps.contains) { return }
        let sourceID = front?.bundleIdentifier
        let sourceName = front?.localizedName
        // Большое содержимое не должно останавливать главный поток: на нём живёт перехват прокрутки «Мыши».
        Self.readQueue.async {
            guard var snap = ClipboardPasteboard.snapshot(of: NSPasteboard.general, change: count) else { return }
            snap.sourceBundleID = sourceID
            snap.sourceName = sourceName
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClipboardController.shared.finishRead(snap) }
            }
        }
    }

    private func finishRead(_ snap: ClipSnapshot) {
        guard isRunning, let store else { return }
        if store.ingest(snap) { sync() }
    }

    // MARK: Горячая клавиша

    func setHotKey(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        Kit.defaults.set(keyCode, forKey: Key.keyCode)
        Kit.defaults.set(modifiers, forKey: Key.modifiers)
        if isRunning && !hotKeySuspended { registerHotKey() }
    }

    func resetHotKey() { setHotKey(keyCode: Self.defaultKeyCode, modifiers: Self.defaultModifiers) }

    /// На время записи сочетания: иначе текущее сработает вместо записи.
    func suspendHotKey() {
        hotKeySuspended = true
        unregisterHotKey()
    }

    func resumeHotKey() {
        hotKeySuspended = false
        if isRunning { registerHotKey() }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        InstallEventHandler(GetApplicationEventTarget(), clipboardHotKeyCallback, 1, &types, nil, &handlerRef)
    }

    private func registerHotKey() {
        unregisterHotKey()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        hotKeyError = status == noErr ? nil : "Это сочетание занято, выбери другое"
        if status != noErr { hotKeyRef = nil }
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    fileprivate func hotKeyPressed() {
        guard isRunning else { return }
        togglePanel()
    }

    func togglePanel() {
        if store == nil { openStore() }
        ClipboardPanelHost.shared.toggle(controller: self)
    }

    // MARK: Исключения

    func addExcluded(_ bundleID: String) {
        guard !Kit.isOurs(bundleID), !excludedApps.contains(bundleID) else { return }
        excludedApps.append(bundleID)
        Kit.defaults.set(excludedApps, forKey: Key.excluded)
    }

    func removeExcluded(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
        Kit.defaults.set(excludedApps, forKey: Key.excluded)
    }

    // MARK: История и пространства

    func setLimit(_ value: Int) {
        limit = value
        Kit.defaults.set(value, forKey: Key.limit)
        store?.setLimit(value)
        sync()
    }

    func clearHistory() { store?.clearHistory(); sync() }
    func delete(_ id: UUID) { store?.delete(id); sync() }
    func pin(_ id: UUID, to space: UUID?) { store?.pin(id, to: space); sync() }

    func addSpace(name: String, colorID: String) { store?.addSpace(name: name, colorID: colorID); sync() }
    func renameSpace(_ id: UUID, to name: String) { store?.renameSpace(id, to: name); sync() }
    func setColor(_ id: UUID, _ colorID: String) { store?.setColor(id, colorID); sync() }
    func moveSpace(_ id: UUID, by offset: Int) { store?.moveSpace(id, by: offset); sync() }
    func deleteSpace(_ id: UUID) { store?.deleteSpace(id); sync() }

    func imageData(_ item: ClipItem) -> Data? { store?.imageData(item) }

    var historyCount: Int { items.filter { $0.spaceID == nil }.count }

    func refreshPermissions() { axTrusted = AXIsProcessTrusted() }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Вставка

    /// Кладёт запись в буфер и шлёт ⌘V в программу, которая была впереди (панель её не активирует).
    func paste(_ item: ClipItem) {
        guard let store else { return }
        let pasteboard = NSPasteboard.general
        ownChange = ClipboardPasteboard.write(item, imageData: store.imageData(item), to: pasteboard)
        lastChange = ownChange
        store.touch(item.id)
        sync()
        ClipboardPanelHost.shared.hide()
        refreshPermissions()
        guard axTrusted else {
            VoiceHUD.shared.showMessage("Скопировано — вставь ⌘V")
            return
        }
        // Дать панели исчезнуть, чтобы клавиши ушли в нужное окно.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.sendPaste() }
    }

    private static func sendPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Обработчик Carbon: вызывается на главном потоке.
private func clipboardHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                     _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == ClipboardController.signature else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { ClipboardController.shared.hotKeyPressed() }
    }
    return noErr
}
