import AVFoundation

/// Синтезатор речи. Настоящий — `AVSpeechSynthesizerAdapter`; проверки ставят подмену, настоящий звук им не нужен.
/// Каждое `speak` получает свой номер: колбэки оборванного или перезапущенного чтения контроллер по нему отбрасывает.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Чтение с этим номером началось.
    var onStart: ((Int) -> Void)? { get set }
    /// Закончилось или оборвано.
    var onFinish: ((Int) -> Void)? { get set }
    /// Сейчас звучит этот кусок строки чтения (UTF-16, как в `willSpeakRangeOfSpeechString`).
    var onRange: ((Int, NSRange) -> Void)? { get set }

    /// Начать читать, вернуть номер чтения. `voiceID` nil — голос системы по умолчанию. `rate` — шкала `AVSpeechUtterance`.
    func speak(_ text: String, voiceID: String?, rate: Float) -> Int
    func pause()
    func resume()
    func stop()
    /// Голоса, установленные в системе.
    func voices() -> [SpeakVoiceRow]
}

/// Множитель скорости → `AVSpeechUtterance.rate` (0…1, обычная речь — 0,5). Шкала rate нелинейна. Замер 2026-11, macOS 26,
/// голоса Samantha и Milena, запись в буфер без звука: rate 0 → 0,5×, 0,5 → 1×, 1 → 4×. Ниже 0,5 скорость растёт
/// как 0,5 + rate, выше — как 1 + 6·(rate − 0,5). Здесь обратная функция по этим двум отрезкам: 1× — ровно
/// `AVSpeechUtteranceDefaultSpeechRate`, 0,5× — минимум шкалы, 3× ≈ 0,83, до максимума 1 (≈ 4×) не доходит.
enum SpeakRate {
    /// Скорость при максимуме шкалы по замеру.
    static let speedAtMaximum = 4.0

    static func utteranceRate(forSpeed speed: Double) -> Float {
        let s = SpeakSpeed.clamped(speed) ?? SpeakSpeed.normal
        let low = Double(AVSpeechUtteranceMinimumSpeechRate)
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        let high = Double(AVSpeechUtteranceMaximumSpeechRate)
        let rate: Double
        if s <= SpeakSpeed.normal {
            // 0,5× → минимум шкалы, 1× → обычная.
            let lowest = SpeakSpeed.range.lowerBound
            rate = low + (s - lowest) / (SpeakSpeed.normal - lowest) * (normal - low)
        } else {
            rate = normal + (s - SpeakSpeed.normal) / (speedAtMaximum - SpeakSpeed.normal) * (high - normal)
        }
        return Float(min(max(rate, low), high))
    }
}

/// Настоящий синтезатор. До первого `speak` ничего не создаёт: модуль без нажатия не трогает речь системы.
@MainActor
final class AVSpeechSynthesizerAdapter: SpeechSynthesizing {
    var onStart: ((Int) -> Void)?
    var onFinish: ((Int) -> Void)?
    var onRange: ((Int, NSRange) -> Void)?

    private var synthesizer: AVSpeechSynthesizer?
    private let relay = SpeechRelay()
    /// Текущие чтения по фразе. Колбэк держит фразу до главного потока, так что адрес не достанется новой раньше времени.
    private var live: [ObjectIdentifier: Int] = [:]
    private var lastID = 0

    init() {
        relay.event = { [weak self] event, ref in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(event, ref) } }
        }
    }

    func speak(_ text: String, voiceID: String?, rate: Float) -> Int {
        lastID += 1
        let id = lastID
        if Kit.standRefuses("читать вслух") {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFinish?(id) } }
            return id
        }
        let utterance = AVSpeechUtterance(string: text)
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) { utterance.voice = voice }
        utterance.rate = rate
        // Свежий синтезатор на каждое чтение: по известным отчётам прежний сразу после `stopSpeaking` бывает, что
        // молча пропускает следующую фразу. Старому чтению это не мешает: его колбэки отброшены по `live`.
        synthesizer?.stopSpeaking(at: .immediate)
        let fresh = AVSpeechSynthesizer()
        fresh.delegate = relay
        synthesizer = fresh
        live = [ObjectIdentifier(utterance): id]
        fresh.speak(utterance)
        return id
    }

    func pause() { synthesizer?.pauseSpeaking(at: .word) }
    func resume() { synthesizer?.continueSpeaking() }

    func stop() {
        live = [:]
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }

    /// Без «новинок» вроде Zarvox и Bells: читать ими текст никто не станет.
    func voices() -> [SpeakVoiceRow] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { SpeakVoiceRow(id: $0.identifier, name: $0.name, language: $0.language, quality: Self.quality($0.quality)) }
            .sorted { ($0.language, $0.name, $0.id) < ($1.language, $1.name, $1.id) }
    }

    private static func quality(_ value: AVSpeechSynthesisVoiceQuality) -> SpeakVoiceQuality {
        switch value {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .regular
        }
    }

    private func deliver(_ event: SpeechRelay.Event, _ ref: SpeechRelay.UtteranceRef) {
        let key = ObjectIdentifier(ref.utterance)
        guard let id = live[key] else { return }
        switch event {
        case .start: onStart?(id)
        case .range(let range): onRange?(id, range)
        case .finish:
            live[key] = nil
            onFinish?(id)
        }
    }
}

/// Делегат синтезатора: колбэки приходят не на главном потоке, отсюда они уходят на него.
private final class SpeechRelay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    enum Event: @unchecked Sendable { case start, range(NSRange), finish }
    /// Фраза едет на главный поток целиком: пока колбэк в очереди, её адрес не займёт новая.
    struct UtteranceRef: @unchecked Sendable { let utterance: AVSpeechUtterance }

    /// Ставится один раз, до первого чтения.
    var event: (@Sendable (Event, UtteranceRef) -> Void)?

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        event?(.start, UtteranceRef(utterance: utterance))
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        event?(.range(range), UtteranceRef(utterance: utterance))
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        event?(.finish, UtteranceRef(utterance: utterance))
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        event?(.finish, UtteranceRef(utterance: utterance))
    }
}
