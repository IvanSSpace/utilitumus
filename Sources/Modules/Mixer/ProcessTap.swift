// Принцип (тап процесса → агрегатное устройство → IOProc с усилением) описан
// в документации Apple «Capturing system audio with Core Audio taps» и показан в
// открытых проектах: AudioCap (Guilherme Rambo, BSD-2-Clause,
// https://github.com/insidegui/AudioCap) и Fader (pantafive, MIT,
// https://github.com/pantafive/fader). Код написан заново, не перенесён.

import CoreAudio
import AudioToolbox
import Foundation

enum ProcessTapError: LocalizedError {
    case step(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .step(what, status): return "\(what): ошибка Core Audio \(status)"
        }
    }

    /// Нет разрешения «Запись системного звука».
    var isPermissionDenied: Bool {
        switch self {
        case let .step(_, status): return status == kAudioDevicePermissionsError
        }
    }
}

/// Перехват звука одной группы процессов и проигрывание его на устройство вывода
/// с множителем громкости. Пока тап жив, родной вывод приложения заглушен
/// (`mutedWhenTapped`), поэтому тап нужно уничтожать, как только он не нужен:
/// без него звук приложения возвращается как был.
final class ProcessTap {
    let processObjectIDs: Set<AudioObjectID>
    let outputUID: String
    let createdAt = Date()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.utilitumus.mixer.io", qos: .userInitiated)

    // Общая память с реалтайм-потоком: там нельзя ни блокировки, ни аллокации.
    // Выровненные чтения и записи Float/UInt32 на arm64 атомарны.
    // 0 — целевой множитель, 1 — текущий (идёт к целевому), 2 — пик входа, 3 — пик выхода.
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let callbacks = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    /// Эквалайзер: своя память и свой способ передачи, описаны в `EqEngine`.
    private let eq = EqEngine()
    private var eqBands: [Double]
    private var sampleRate: Double = 48000
    private var unlistenRate: (() -> Void)?

    /// Сколько раз вызывался IOProc. 0 спустя пару секунд — данные не идут
    /// (обычно нет разрешения), а приложение при этом заглушено.
    var callbackCount: UInt32 { callbacks.pointee }

    /// Множитель 0...1. Выше 1 не усиливаем.
    func setGain(_ gain: Float) {
        state[0] = max(0, min(1, gain))
    }

    /// Максимальные амплитуды входа (до усиления) и выхода с прошлого вызова.
    func takePeaks() -> (input: Float, output: Float) {
        let peaks = (state[2], state[3])
        state[2] = 0
        state[3] = 0
        return peaks
    }

    /// Новые значения полос: сюда только проверенные `MixerEq.isValid`.
    func setEqualizer(_ bands: [Double]) {
        guard bands != eqBands else { return }
        eqBands = bands
        bands.withUnsafeBufferPointer { eq.publish(bands: $0, rate: sampleRate) }
    }

    init(processObjectIDs: Set<AudioObjectID>, outputUID: String, gain: Float, equalizer: [Double]) throws {
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputUID
        eqBands = equalizer
        state[0] = max(0, min(1, gain))
        state[1] = state[0]
        state[2] = 0
        state[3] = 0
        callbacks.pointee = 0
        // Если build() упал на полпути, deinit сам снесёт созданное.
        try build()
    }

    deinit {
        destroy()
        state.deallocate()
        callbacks.deallocate()
        eq.deallocate()
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw ProcessTapError.step(what, status) }
    }

    private func build() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Utilitumus Mixer"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "создание тапа")

        // Частота и главное устройство — устройство вывода: по его часам идёт
        // IOProc, а тап подстраивается под них компенсацией дрейфа.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Utilitumus Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "создание агрегатного устройства")

        var rate: Float64 = MixerHAL.value(aggregateID, kAudioDevicePropertyNominalSampleRate, default: 48000.0) ?? 48000
        if rate <= 0 { rate = 48000 }
        // Плавный переход за ~20 мс: без щелчков при движении ползунка.
        let ramp = Float(1 - exp(-1 / (rate * 0.02)))
        let isFloat32 = outputIsFloat32()
        sampleRate = rate
        eqBands.withUnsafeBufferPointer { self.eq.start(bands: $0, rate: rate) }
        // Устройство сменилось: контроллер пересоберёт тап, и новая частота придёт оттуда. Здесь смена частоты того же устройства.
        unlistenRate = MixerHAL.listen(kAudioDevicePropertyNominalSampleRate, on: aggregateID) { [weak self] in
            self?.sampleRateChanged()
        }

        let state = state
        let callbacks = callbacks
        let eq = eq
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            callbacks.pointee &+= 1
            ProcessTap.render(input, output, state: state, ramp: ramp, isFloat32: isFloat32, eq: eq)
        }, "создание IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "запуск устройства")
    }

    private func sampleRateChanged() {
        guard let rate: Float64 = MixerHAL.value(aggregateID, kAudioDevicePropertyNominalSampleRate, default: sampleRate),
              rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        eqBands.withUnsafeBufferPointer { eq.publish(bands: $0, rate: rate) }
    }

    /// Усиление и эквалайзер считаем только для Float32; на любом другом формате честно
    /// копируем звук как есть, чтобы не испортить его.
    private func outputIsFloat32() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &format) == noErr else { return false }
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    /// Порядок обязателен: остановить → снять IOProc → удалить агрегат → удалить тап.
    /// Удаление тапа возвращает приложению родной вывод.
    func destroy() {
        unlistenRate?()
        unlistenRate = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Реалтайм: никаких аллокаций, блокировок и логов.

    static func render(_ input: UnsafePointer<AudioBufferList>,
                       _ output: UnsafeMutablePointer<AudioBufferList>,
                       state: UnsafeMutablePointer<Float>, ramp: Float, isFloat32: Bool, eq: EqEngine) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let target = state[0]
        var gain = state[1]
        var peakIn = state[2]
        var peakOut = state[3]
        // На не-Float32 эквалайзера нет, как и громкости: звук копируется как есть. Набор ждёт, история не копится.
        var eqOn = false
        if isFloat32 {
            var channels = 0
            for out in outs { channels += max(1, Int(out.mNumberChannels)) }
            eqOn = eq.begin(channels: channels)
        }
        var firstChannel = 0

        for (index, out) in outs.enumerated() {
            guard let outData = out.mData else { continue }
            let outBytes = Int(out.mDataByteSize)
            guard index < ins.count, let inData = ins[index].mData else {
                memset(outData, 0, outBytes)
                continue
            }
            guard isFloat32 else {
                let bytes = min(outBytes, Int(ins[index].mDataByteSize))
                memcpy(outData, inData, bytes)
                if bytes < outBytes { memset(outData + bytes, 0, outBytes - bytes) }
                continue
            }
            let inCh = max(1, Int(ins[index].mNumberChannels))
            let outCh = max(1, Int(out.mNumberChannels))
            let src = inData.assumingMemoryBound(to: Float.self)
            let dst = outData.assumingMemoryBound(to: Float.self)
            let frames = min(Int(ins[index].mDataByteSize) / 4 / inCh, outBytes / 4 / outCh)
            // Шире, чем хватает памяти истории: этот поток идёт без эквалайзера, но с громкостью. Без падения и без рассинхрона каналов внутри потока.
            let eqHere = eqOn && firstChannel + outCh <= EqEngine.maxChannels
            for f in 0..<frames {
                gain += (target - gain) * ramp
                if eqHere { eq.advance() }
                for c in 0..<outCh {
                    // Тап всегда стерео; на моно-выходе (Bluetooth-гарнитура) каналы
                    // усредняем, на широком — повторяем последний.
                    let sample: Float
                    if inCh == outCh {
                        sample = src[f * inCh + c]
                    } else if outCh == 1 {
                        var sum: Float = 0
                        for k in 0..<inCh { sum += src[f * inCh + k] }
                        sample = sum / Float(inCh)
                    } else {
                        sample = src[f * inCh + min(c, inCh - 1)]
                    }
                    let shaped = eqHere ? eq.process(sample, channel: firstChannel + c) : sample
                    let value = shaped * gain
                    dst[f * outCh + c] = value
                    peakIn = max(peakIn, abs(sample))
                    peakOut = max(peakOut, abs(value))
                }
            }
            let written = frames * outCh * 4
            if written < outBytes { memset(outData + written, 0, outBytes - written) }
            firstChannel += outCh
        }
        if eqOn { eq.end() }
        // Хвост экспоненты не тянем вечно: у нуля и у цели фиксируем значение.
        if abs(gain - target) < 1e-4 { gain = target }
        state[1] = gain
        state[2] = peakIn
        state[3] = peakOut
    }
}
