import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

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
        let input = engine.inputNode
        if let deviceUID, var device = Self.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw VoiceEngineError("Микрофон недоступен") }

        lock.withLock {
            samples = []
            samples.reserveCapacity(16_000 * 30)
            smoothedLevel = 0
        }
        let ratio = Self.sampleRate / inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
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

    struct InputDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Устройства, у которых есть вход.
    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

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
