import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Что контроллеру нужно от записи: настоящая — `VoiceRecorder`, в проверках подставная.
protocol VoiceCapturing: AnyObject, Sendable {
    var count: Int { get }
    var level: Float { get }
    func start(deviceUID: String?) throws
    func finish() -> [Float]
}

extension VoiceRecorder: VoiceCapturing {}

/// Запись с микрофона в память: 16 кГц, моно, Float32 — как ждёт `VoiceEngine`.
/// Звук нигде не сохраняется: только массив в оперативке, который отдаёт `finish()`.
final class VoiceRecorder: @unchecked Sendable {
    /// 10 минут — тот же предел, что у движка.
    static let maxSamples = VoiceEngine.maxSamples
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var smoothedLevel: Float = 0
    private var running = false

    /// Сколько сэмплов записано.
    var count: Int { lock.withLock { samples.count } }
    /// Громкость 0...1 для индикатора.
    var level: Float { lock.withLock { smoothedLevel } }

    /// `deviceUID` — UID устройства CoreAudio; nil или пропавшее устройство — системный микрофон.
    func start(deviceUID: String?) throws {
        // Повторный старт (двойное нажатие клавиши) ставил второй tap на ту же шину —
        // AVAudioEngine на это бросает исключение и роняет приложение. Сначала всё снимаем.
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if let deviceUID, var device = Self.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // Формат берём у самого входа (inputFormat — то, что даёт устройство). Свой формат
        // в installTap, не совпавший с устройством (сменили микрофон, другая частота), —
        // тоже исключение и падение. Поэтому tap ставим с format: nil, а конвертер
        // собираем по формату первого пришедшего буфера.
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: false)
        else { throw VoiceEngineError("Микрофон недоступен") }

        lock.withLock {
            samples = []
            samples.reserveCapacity(16_000 * 30)
            smoothedLevel = 0
        }
        let box = ConverterBox()
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let format = buffer.format
            if box.converter == nil || box.format != format {
                box.converter = AVAudioConverter(from: format, to: outFormat)
                box.format = format
            }
            guard let converter = box.converter, format.sampleRate > 0 else { return }
            let ratio = Self.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData?[0] else { return }
            self.append(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    /// Остановить и забрать записанное. Внутри ничего не остаётся.
    func finish() -> [Float] {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        return lock.withLock {
            let result = samples
            samples = []
            smoothedLevel = 0
            return result
        }
    }

    private func append(_ chunk: UnsafeBufferPointer<Float>) {
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (sum / Float(chunk.count)).squareRoot()
        // От -50 дБ (тишина) до 0 дБ.
        let db = 20 * log10(max(rms, 1e-5))
        let target = min(max((db + 50) / 50, 0), 1)
        lock.withLock {
            // Лишнего сверх предела не копим: контроллер остановит запись по таймеру.
            if samples.count < Self.maxSamples + 16_000 { samples.append(contentsOf: chunk) }
            smoothedLevel = max(target, smoothedLevel * 0.7)
        }
    }

    // MARK: - Устройства

    static func inputDevices() -> [VoiceInputs.Device] { VoiceInputs.devices() }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}

/// Конвертер, который создаётся в аудиопотоке по формату первого буфера. Пользуется им
/// только поток tap-а, поэтому без блокировок.
private final class ConverterBox: @unchecked Sendable {
    var converter: AVAudioConverter?
    var format: AVAudioFormat?
}
