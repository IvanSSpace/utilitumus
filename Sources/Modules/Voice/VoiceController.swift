import SwiftUI
import AppKit
import AVFoundation
import Carbon.HIToolbox

/// Голосовой ввод: горячая клавиша, запись, распознавание, вставка текста.
/// Звук и текст нигде не логируются и не пишутся на диск.
@MainActor
final class VoiceController: ObservableObject {
    static let shared = VoiceController()

    enum Mode: String, CaseIterable, Identifiable {
        case toggle
        case hold
        var id: String { rawValue }
        var title: String { self == .toggle ? "Нажал — нажал" : "Пока держу" }
    }

    enum Phase { case idle, recording, transcribing }

    // MARK: Настройки (UserDefaults "Voice.")

    enum Key {
        static let keyCode = "Voice.HotKeyCode"
        static let modifiers = "Voice.HotKeyModifiers"
        static let mode = "Voice.Mode"
        static let mic = "Voice.MicUID"
        static let excluded = "Voice.ExcludedApps"
    }

    @Published private(set) var keyCode: UInt32
    @Published private(set) var modifiers: UInt32
    @Published var mode: Mode {
        didSet { Kit.defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    /// UID микрофона; nil — системный.
    @Published var micUID: String? {
        didSet { Kit.defaults.set(micUID, forKey: Key.mic) }
    }

    /// Bundle id программ, где голос Utilitumus не включается (у них свой ввод).
    @Published private(set) var excludedApps: [String]

    // MARK: Состояние

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var micStatus: AVAuthorizationStatus
    @Published private(set) var axTrusted: Bool
    /// Горячую клавишу не удалось занять (например, её держит другая программа).
    @Published private(set) var hotKeyError: String?

    private var isRunning = false
    private let recorder = VoiceRecorder()
    private var levelTimer: Timer?
    private var recordingStart = Date()
    private var transcribeTask: Task<Void, Never>?

    // Carbon
    private var handlerRef: EventHandlerRef?
    private var mainHotKey: EventHotKeyRef?
    private var escHotKey: EventHotKeyRef?
    private var hotKeySuspended = false
    /// Переднее приложение в списке исключений: клавишу не занимаем, она идёт самому приложению.
    private var frontmostExcluded = false
    private var activationObserver: NSObjectProtocol?
    nonisolated fileprivate static let signature: OSType = 0x564F4943  // 'VOIC'
    private static let mainID: UInt32 = 1
    private static let escID: UInt32 = 2

    private init() {
        let d = Kit.defaults
        keyCode = d.object(forKey: Key.keyCode) as? UInt32 ?? VoiceHotKey.defaultKeyCode
        modifiers = d.object(forKey: Key.modifiers) as? UInt32 ?? VoiceHotKey.defaultModifiers
        mode = d.string(forKey: Key.mode).flatMap(Mode.init(rawValue:)) ?? .toggle
        micUID = d.string(forKey: Key.mic)
        excludedApps = d.stringArray(forKey: Key.excluded) ?? []
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        axTrusted = AXIsProcessTrusted()
    }

    var hotKeyLabel: String { VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers) }

    // MARK: Запуск и остановка модуля

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Один раз за процесс и только пока ничего не качается: хвосты чужой загрузки трогать нельзя.
        VoiceModelStore.shared.cleanLeftoversOnce()
        installHandler()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { VoiceController.shared.updateExclusion() }
        }
        frontmostExcluded = Self.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, in: excludedApps)
        registerMain()
    }

    func stop() {
        endTest()
        guard isRunning else { return }
        isRunning = false
        cancelAll()
        unregisterMain()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        frontmostExcluded = false
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        VoiceHUD.shared.hide()
        Task { await VoiceEngine.shared.shutdown() }
    }

    // MARK: Горячая клавиша

    func setHotKey(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        Kit.defaults.set(keyCode, forKey: Key.keyCode)
        Kit.defaults.set(modifiers, forKey: Key.modifiers)
        if isRunning && !hotKeySuspended { registerMain() }
    }

    func resetHotKey() {
        setHotKey(keyCode: VoiceHotKey.defaultKeyCode, modifiers: VoiceHotKey.defaultModifiers)
    }

    /// На время записи сочетания в настройках: иначе текущее сработает вместо записи.
    func suspendHotKey() {
        hotKeySuspended = true
        unregisterMain()
    }

    func resumeHotKey() {
        hotKeySuspended = false
        if isRunning { registerMain() }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), voiceHotKeyCallback, 2, &types, nil, &handlerRef)
    }

    // MARK: Исключения

    /// Входит ли приложение в список «не включать голос».
    nonisolated static func isExcluded(_ bundleID: String?, in list: [String]) -> Bool {
        guard let bundleID else { return false }
        return list.contains(bundleID)
    }

    func addExcluded(_ bundleID: String) {
        guard !Kit.isOurs(bundleID), !excludedApps.contains(bundleID) else { return }
        excludedApps.append(bundleID)
        persistExcluded()
    }

    func removeExcluded(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
        persistExcluded()
    }

    private func persistExcluded() {
        Kit.defaults.set(excludedApps, forKey: Key.excluded)
        updateExclusion()
    }

    /// Горячая клавиша — Carbon: пока она занята, система не отдаёт её приложению. Поэтому в исключённом
    /// приложении снимаем регистрацию совсем, и клавиша доходит до него как обычная; вышли — занимаем снова.
    private func updateExclusion() {
        guard isRunning else { return }
        frontmostExcluded = Self.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, in: excludedApps)
        if frontmostExcluded {
            cancelAll()
            VoiceHUD.shared.hide()
            unregisterMain()
            hotKeyError = nil
        } else if mainHotKey == nil && !hotKeySuspended {
            registerMain()
        }
    }

    private func registerMain() {
        unregisterMain()
        if frontmostExcluded { return }
        let id = EventHotKeyID(signature: Self.signature, id: Self.mainID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &mainHotKey)
        hotKeyError = status == noErr ? nil : "Это сочетание занято, выбери другое"
        if status != noErr { mainHotKey = nil }
    }

    private func unregisterMain() {
        if let mainHotKey { UnregisterEventHotKey(mainHotKey) }
        mainHotKey = nil
    }

    /// Esc берём только на время записи и распознавания, иначе он пропал бы у всех программ.
    private func registerEsc() {
        guard escHotKey == nil else { return }
        let id = EventHotKeyID(signature: Self.signature, id: Self.escID)
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escHotKey) != noErr {
            escHotKey = nil
        }
    }

    private func unregisterEsc() {
        if let escHotKey { UnregisterEventHotKey(escHotKey) }
        escHotKey = nil
    }

    fileprivate func hotKeyEvent(id: UInt32, pressed: Bool) {
        guard isRunning else { return }
        if id == Self.escID {
            if pressed { cancelAll(); VoiceHUD.shared.hide() }
            return
        }
        guard id == Self.mainID else { return }
        switch mode {
        case .toggle:
            guard pressed else { return }
            if phase == .recording { finishRecording() } else if phase == .idle { beginRecording() }
        case .hold:
            if pressed {
                if phase == .idle { beginRecording() }
            } else if phase == .recording {
                finishRecording()
            }
        }
    }

    // MARK: Запись

    private func beginRecording() {
        refreshPermissions()
        guard anyModelReady != nil else {
            VoiceHUD.shared.showMessage("Скачай модель в «Голосе»", isError: true)
            return
        }
        switch micStatus {
        case .authorized:
            startRecorder()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.refreshPermissions()
                    VoiceHUD.shared.showMessage(granted ? "Микрофон разрешён — нажми ещё раз" : "Нет доступа к микрофону",
                                                isError: !granted)
                }
            }
        default:
            VoiceHUD.shared.showMessage("Нет доступа к микрофону — разреши в «Голосе»", isError: true)
        }
    }

    private func startRecorder() {
        do {
            try recorder.start(deviceUID: micUID)
        } catch {
            _ = recorder.finish()
            VoiceHUD.shared.showMessage("Микрофон не включился", isError: true)
            return
        }
        phase = .recording
        recordingStart = Date()
        registerEsc()
        VoiceHUD.shared.showListening()
        NotificationCenter.default.addObserver(self, selector: #selector(audioConfigChanged),
                                               name: .AVAudioEngineConfigurationChange, object: nil)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    @objc nonisolated private func audioConfigChanged() {
        Task { @MainActor in
            guard self.phase == .recording else { return }
            self.cancelAll()
            VoiceHUD.shared.showMessage("Микрофон изменился — запись отменена", isError: true)
        }
    }

    private func tick() {
        guard phase == .recording else { return }
        // Полоска меньше чем на 2 % не заметна — не будим SwiftUI ради неё.
        let level = recorder.level
        if abs(level - VoiceHUD.shared.model.level) >= 0.02 { VoiceHUD.shared.model.level = level }
        if recorder.count >= VoiceRecorder.maxSamples { finishRecording() }
    }

    private func stopRecorder() -> [Float] {
        levelTimer?.invalidate()
        levelTimer = nil
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        return recorder.finish()
    }

    /// Отмена всего: запись, распознавание. Звук выбрасывается.
    private func cancelAll() {
        if phase == .recording { _ = stopRecorder() }
        transcribeTask?.cancel()
        transcribeTask = nil
        unregisterEsc()
        phase = .idle
    }

    private func finishRecording() {
        let duration = Date().timeIntervalSince(recordingStart)
        var samples = stopRecorder()
        if samples.count > VoiceRecorder.maxSamples { samples.removeLast(samples.count - VoiceRecorder.maxSamples) }
        guard duration > 0.3, samples.count > 4800 else {
            unregisterEsc()
            phase = .idle
            VoiceHUD.shared.showMessage("Слишком коротко", isError: true, seconds: 1.5)
            return
        }
        guard let model = anyModelReady else {
            unregisterEsc()
            phase = .idle
            VoiceHUD.shared.showMessage("Скачай модель в «Голосе»", isError: true)
            return
        }
        phase = .transcribing
        VoiceHUD.shared.showTranscribing()
        transcribeTask = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await VoiceEngine.shared.transcribe(samples, model: model))
            } catch {
                result = .failure(error)
            }
            samples = []
            guard let self, !Task.isCancelled else { return }
            self.transcribeTask = nil
            self.unregisterEsc()
            self.phase = .idle
            switch result {
            case let .success(text):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty {
                    VoiceHUD.shared.showMessage("Ничего не расслышал", isError: true, seconds: 1.8)
                } else {
                    self.insert(clean)
                }
            case let .failure(error):
                VoiceHUD.shared.showMessage(error.localizedDescription, isError: true, seconds: 4)
            }
        }
    }

    /// Выбранная модель, если установлена; иначе любая установленная.
    private var anyModelReady: VoiceModel? {
        let store = VoiceModelStore.shared
        if store.status(store.selected) == .installed { return store.selected }
        return VoiceModel.allCases.first { store.status($0) == .installed }
    }

    // MARK: Режим проверки

    /// Поле «Проверить» во внешнем модуле (решение Q6): пока режим включён, распознанное идёт в состояние для экрана,
    /// а не в переднее приложение. Встроенный экран его не включает: там текст вставляется в поле, как раньше.
    @Published private(set) var test: VoiceTestState?
    private var testUntil = Date.distantPast

    func beginTest(now: Date = Date()) {
        test = VoiceTestState(phrase: nil, serial: test?.serial ?? 0)
        testUntil = now + VoiceTestState.lifetime
    }

    func endTest() {
        if test != nil { test = nil }
    }

    /// Срок на случай, если экран не выключил режим: иначе диктовка навсегда перестала бы доходить до программ.
    var liveTest: VoiceTestState? {
        Date() < testUntil ? test : nil
    }

    /// Забрать текст для экрана, если режим включён. false — вставлять как обычно.
    func captureTestText(_ text: String) -> Bool {
        guard let live = liveTest else {
            endTest()
            return false
        }
        test = VoiceTestState(phrase: String(text.prefix(VoiceTestState.maxPhrase)), serial: live.serial + 1)
        return true
    }

    // MARK: Вставка

    private func insert(_ text: String) {
        if captureTestText(text) {
            VoiceHUD.shared.hide()
            return
        }
        // Диктуют в поле самого Utilitumus (раздел «Проверить»): вставляем напрямую, права не нужны.
        if NSApp.isActive, let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable {
            view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            VoiceHUD.shared.hide()
            return
        }
        let pasteboard = Kit.pasteboard
        guard AXIsProcessTrusted() else {
            axTrusted = false
            pasteboard.clearContents()
            pasteboard.writeObjects([VoicePasteItem.make(text)])
            VoiceHUD.shared.showMessage("Скопировано — вставь ⌘V")
            return
        }
        axTrusted = true
        // Прежнее содержимое: все типы первого элемента.
        let saved: [(NSPasteboard.PasteboardType, Data)] = pasteboard.pasteboardItems?.first.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []

        pasteboard.clearContents()
        pasteboard.writeObjects([VoicePasteItem.make(text)])
        let changeCount = pasteboard.changeCount
        VoiceHUD.shared.hide()
        Self.sendPaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Пока ждали, в буфер мог что-то положить кто-то другой — тогда не трогаем.
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            guard !saved.isEmpty else { return }
            let restored = NSPasteboardItem()
            for (type, data) in saved { restored.setData(data, forType: type) }
            pasteboard.writeObjects([restored])
        }
    }

    private static func sendPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Разрешения

    func refreshPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        axTrusted = AXIsProcessTrusted()
    }

    func requestMic() {
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        } else {
            Self.openSettings("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        Self.openSettings("Privacy_Accessibility")
    }

    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            if !Kit.standRefuses("системные настройки") { NSWorkspace.shared.open(url) }
        }
    }
}

/// Обработчик Carbon: вызывается на главном потоке.
private func voiceHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == VoiceController.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { VoiceController.shared.hotKeyEvent(id: id, pressed: pressed) }
    }
    return noErr
}
