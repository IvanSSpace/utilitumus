import AppKit
import ApplicationServices

/// «Озвучка»: по сочетанию читает вслух выделенный текст, повторное нажатие обрывает чтение.
/// Прочитанный текст живёт только в памяти, пока идёт чтение: на диск, в настройки, в логи, в строку статуса
/// и в состояние для центра он не попадает. Сеть не нужна.
@MainActor
final class SpeakController: SpeakModel {
    static let shared = SpeakController()

    // MARK: Настройки (Kit.defaults, ключи SpeakKeys)

    @Published private(set) var speed: Double
    @Published private(set) var pinnedVoices: [String: String]
    @Published private(set) var keyCode: UInt32
    @Published private(set) var modifiers: UInt32

    // MARK: Состояние

    @Published private(set) var voices: [SpeakVoiceRow] = []
    @Published private(set) var phase: SpeakPhase = .idle
    @Published private(set) var message: String?
    /// Сочетание не удалось занять.
    @Published private(set) var hotKeyError: String?
    @Published private(set) var accessibilityTrusted: Bool
    /// Можно ли читать. Отдельное приложение запрещает это, пока модуль ведёт центр.
    @Published var canStart = true

    private let synthesizer: SpeechSynthesizing
    private let reader: SelectionReading
    private let hotKey: SpeakHotKeyBinding
    private let trusted: () -> Bool
    private let preferredLanguages: () -> [String]
    private var isRunning = false
    private var hotKeySuspended = false

    /// Текущее чтение. Единственное место, где лежит текст; nil — ничего не читаем.
    private struct Session {
        let text: String
        let voiceID: String?
        /// Номер чтения у синтезатора; nil — ждём перезапуска (скорость сменили на паузе).
        var utterance: Int?
        /// С какого места текста (UTF-16) начато текущее чтение.
        var base = 0
        /// Где сейчас речь (UTF-16 от начала текста): начало слова из `willSpeakRange`.
        var position = 0
    }
    private var session: Session?

    /// Зависимости по умолчанию настоящие. Ничего не регистрирует и не читает: работа только после `start`.
    init(synthesizer: SpeechSynthesizing? = nil, reader: SelectionReading? = nil, hotKey: SpeakHotKeyBinding? = nil,
         trusted: (() -> Bool)? = nil, preferredLanguages: (() -> [String])? = nil) {
        self.synthesizer = synthesizer ?? AVSpeechSynthesizerAdapter()
        self.reader = reader ?? AXSelectionReader()
        self.hotKey = hotKey ?? CarbonSpeakHotKey()
        self.trusted = trusted ?? { Kit.accessTrusted() }
        self.preferredLanguages = preferredLanguages ?? { Locale.preferredLanguages }
        let d = Kit.defaults
        speed = SpeakSpeed.stored(d.object(forKey: SpeakKeys.speed))
        pinnedVoices = d.dictionary(forKey: SpeakKeys.pinnedVoices) as? [String: String] ?? [:]
        keyCode = d.object(forKey: SpeakKeys.keyCode) as? UInt32 ?? SpeakKeys.defaultKeyCode
        modifiers = d.object(forKey: SpeakKeys.modifiers) as? UInt32 ?? SpeakKeys.defaultModifiers
        accessibilityTrusted = self.trusted()

        self.synthesizer.onFinish = { [weak self] id in self?.speechFinished(id) }
        self.synthesizer.onRange = { [weak self] id, range in self?.speechAt(id, range) }
        self.hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
    }

    var hotKeyLabel: String { VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers) }

    // MARK: Запуск и остановка модуля

    /// Модуль включён: перечитать настройки (пока он стоял, их мог менять центр), занять сочетание.
    func start() {
        reloadSettings()
        refreshVoices()
        refreshPermissions()
        isRunning = true
        registerHotKey()
    }

    /// Выключили: отпустить сочетание и оборвать чтение. Повторный вызов безвреден.
    func stop() {
        stopSpeaking()
        isRunning = false
        // Запись сочетания на экране тоже кончилась: следующий `start` займёт сочетание сразу.
        hotKeySuspended = false
        hotKey.unregister()
        if hotKeyError != nil { hotKeyError = nil }
    }

    /// Строка статуса для утилиты. Чтение в ней не видно: о смене статуса узнают все на этом Mac.
    func statusLine(passiveReason: String?) -> String {
        if let passiveReason { return passiveReason }
        if !accessibilityTrusted { return "Нужен Универсальный доступ" }
        return "Читает выделенное по \(hotKeyLabel)"
    }

    /// Только изменившееся: лишняя запись разбудила бы подписчиков.
    private func reloadSettings() {
        let d = Kit.defaults
        // Запись другого процесса: без этого может прийти значение из кэша.
        d.synchronize()
        let savedSpeed = SpeakSpeed.stored(d.object(forKey: SpeakKeys.speed))
        if speed != savedSpeed { speed = savedSpeed }
        let savedPins = d.dictionary(forKey: SpeakKeys.pinnedVoices) as? [String: String] ?? [:]
        if pinnedVoices != savedPins { pinnedVoices = savedPins }
        let savedKey = d.object(forKey: SpeakKeys.keyCode) as? UInt32 ?? SpeakKeys.defaultKeyCode
        let savedModifiers = d.object(forKey: SpeakKeys.modifiers) as? UInt32 ?? SpeakKeys.defaultModifiers
        if keyCode != savedKey { keyCode = savedKey }
        if modifiers != savedModifiers { modifiers = savedModifiers }
    }

    private func refreshVoices() {
        let fresh = synthesizer.voices()
        if voices != fresh { voices = fresh }
    }

    // MARK: Чтение

    /// Нажали сочетание: читаем — оборвать, иначе прочитать выделенное.
    func hotKeyPressed() {
        guard isRunning, canStart else { return }
        if phase != .idle { return stopSpeaking() }
        switch reader.read() {
        case .notTrusted:
            if accessibilityTrusted { accessibilityTrusted = false }
            show(SpeakMessage.needAccess)
        case .none:
            markTrusted()
            show(SpeakMessage.noSelection)
        case .secureField:
            markTrusted()
            show(SpeakMessage.secureField)
        case .text(let text):
            markTrusted()
            begin(text)
        }
    }

    /// Текст из меню «Службы»: Универсальный доступ не нужен. Отказ — текст сообщения, nil — читаем.
    @discardableResult
    func speak(text: String) -> String? {
        guard isRunning, canStart else { return SpeakMessage.notRunning }
        stopSpeaking()
        begin(text)
        return message
    }

    private func begin(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return show(SpeakMessage.noSelection) }
        guard SpeakText.fits(text) else { return show(SpeakMessage.tooLong) }
        refreshVoices()
        let voiceID = SpeakVoiceChooser.choose(for: text, voices: voices, pinned: pinnedVoices, preferred: preferredLanguages())
        if message != nil { message = nil }
        session = Session(text: text, voiceID: voiceID)
        play(from: 0)
    }

    /// Читать с места `offset` (UTF-16) текущей скоростью.
    private func play(from offset: Int) {
        guard var current = session else { return }
        let text = current.text as NSString
        // Начало символа: смещение посреди составного символа дало бы обрывок.
        let start = offset < text.length ? text.rangeOfComposedCharacterSequence(at: offset).location : text.length
        let rest = text.substring(from: start)
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return stopSpeaking() }
        current.base = start
        current.position = start
        current.utterance = nil
        // Сначала сессия, потом синтезатор: колбэк старого чтения, пришедший внутри `speak`, уже не наш.
        session = current
        let id = synthesizer.speak(rest, voiceID: current.voiceID, rate: SpeakRate.utteranceRate(forSpeed: speed))
        session?.utterance = id
        if phase != .speaking { phase = .speaking }
    }

    func pause() {
        guard phase == .speaking else { return }
        synthesizer.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused, let current = session else { return }
        if current.utterance == nil {
            play(from: current.position)
        } else {
            synthesizer.resume()
            phase = .speaking
        }
    }

    /// Оборвать чтение и забыть текст. Модуль работает дальше.
    func stopSpeaking() {
        // Сначала забыть: колбэк остановки, пришедший внутри `stop`, уже ничего не найдёт.
        let wasSpeaking = session != nil || phase != .idle
        session = nil
        if wasSpeaking { synthesizer.stop() }
        if phase != .idle { phase = .idle }
    }

    private func speechFinished(_ id: Int) {
        guard let current = session, current.utterance == id else { return }
        session = nil
        if phase != .idle { phase = .idle }
    }

    private func speechAt(_ id: Int, _ range: NSRange) {
        guard let current = session, current.utterance == id, range.location != NSNotFound else { return }
        session?.position = current.base + range.location
    }

    private func show(_ text: String) {
        if message != text { message = text }
    }

    private func markTrusted() {
        if !accessibilityTrusted { accessibilityTrusted = true }
    }

    // MARK: Скорость

    func setSpeed(_ value: Double) {
        guard let value = SpeakSpeed.clamped(value), value != speed else { return }
        speed = value
        Kit.defaults.set(value, forKey: SpeakKeys.speed)
        restartWithNewSpeed()
    }

    func stepSpeed(_ direction: Int) {
        setSpeed(SpeakSpeed.stepped(speed, direction))
    }

    /// Скорость фразы задаётся при старте, поэтому остаток текста читается заново с текущего слова.
    /// На паузе только запоминаем: остаток пойдёт по «Продолжить».
    private func restartWithNewSpeed() {
        guard let current = session, current.utterance != nil else { return }
        switch phase {
        case .speaking:
            session?.utterance = nil
            synthesizer.stop()
            play(from: current.position)
        case .paused:
            session?.utterance = nil
            synthesizer.stop()
        case .idle:
            break
        }
    }

    // MARK: Голоса

    func setVoiceAuto() {
        guard !pinnedVoices.isEmpty else { return }
        pinnedVoices = [:]
        Kit.defaults.removeObject(forKey: SpeakKeys.pinnedVoices)
    }

    /// Почему закрепить нельзя; nil — можно.
    func pinError(language: String, id: String) -> String? {
        refreshVoices()
        guard voices.contains(where: { $0.id == id && $0.languageKey == language }) else { return "Такого голоса нет" }
        return nil
    }

    func pinVoice(language: String, id: String) {
        guard pinError(language: language, id: id) == nil, pinnedVoices[language] != id else { return }
        pinnedVoices[language] = id
        Kit.defaults.set(pinnedVoices, forKey: SpeakKeys.pinnedVoices)
    }

    func unpin(language: String) {
        guard pinnedVoices[language] != nil else { return }
        pinnedVoices[language] = nil
        if pinnedVoices.isEmpty {
            Kit.defaults.removeObject(forKey: SpeakKeys.pinnedVoices)
        } else {
            Kit.defaults.set(pinnedVoices, forKey: SpeakKeys.pinnedVoices)
        }
    }

    // MARK: Сочетание

    func setHotKey(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        Kit.defaults.set(keyCode, forKey: SpeakKeys.keyCode)
        Kit.defaults.set(modifiers, forKey: SpeakKeys.modifiers)
        registerHotKey()
    }

    func resetHotKey() {
        setHotKey(keyCode: SpeakKeys.defaultKeyCode, modifiers: SpeakKeys.defaultModifiers)
    }

    /// На время записи сочетания на экране: иначе текущее сработает вместо записи.
    func suspendHotKey() {
        hotKeySuspended = true
        hotKey.unregister()
    }

    func resumeHotKey() {
        hotKeySuspended = false
        registerHotKey()
    }

    private func registerHotKey() {
        guard isRunning, !hotKeySuspended else { return }
        let error = hotKey.register(keyCode: keyCode, modifiers: modifiers) ? nil : SpeakMessage.hotKeyBusy
        if hotKeyError != error { hotKeyError = error }
    }

    // MARK: Разрешения

    func refreshPermissions() {
        let now = trusted()
        if accessibilityTrusted != now { accessibilityTrusted = now }
    }

    /// Окно системы про Универсальный доступ и сразу его раздел в Настройках. Только по кнопке.
    func requestAccessibility() {
        guard !Kit.standRefuses("запросить Универсальный доступ") else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
