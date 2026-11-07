import CoreAudio
import Foundation

// Эквалайзер Микшера: математика, настоящий `ProcessTap.render` на подставных буферах, передача коэффициентов, настройки.
// Тапов, устройств и звука нет: тап не создаётся, вызывается только статическая функция. Запуск: Tests/run-mixer-eq-check.sh

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let allUp = [Double](repeating: 12, count: 10)
let allDown = [Double](repeating: -12, count: 10)
let zigzag: [Double] = [12, -12, 12, -12, 12, -12, 12, -12, 12, -12]
let zagzig: [Double] = zigzag.map { -$0 }
func single(_ band: Int, _ gain: Double) -> [Double] {
    var bands = MixerEq.flat
    bands[band] = gain
    return bands
}
func preset(_ id: String) -> [Double] { MixerEq.presets.first { $0.id == id }?.bands ?? [] }

func engine(_ bands: [Double], rate: Double) -> EqEngine {
    let eq = EqEngine()
    bands.withUnsafeBufferPointer { eq.start(bands: $0, rate: rate) }
    return eq
}

func publish(_ eq: EqEngine, _ bands: [Double], rate: Double) {
    bands.withUnsafeBufferPointer { eq.publish(bands: $0, rate: rate) }
}

/// Память тапа: те же четыре значения, что в `ProcessTap.state`.
final class TapState {
    let state = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    init(gain: Float = 1) {
        state[0] = gain
        state[1] = gain
        state[2] = 0
        state[3] = 0
    }
    deinit { state.deallocate() }
}

/// `render` на подставных буферах: один входной поток `inCh` и один выходной `outCh`, чередование как у HAL.
func render(_ input: UnsafeMutablePointer<Float>, frames: Int, inCh: Int = 2, output: UnsafeMutablePointer<Float>, outCh: Int = 2,
            tap: TapState, eq: EqEngine, ramp: Float = 0.001, isFloat32: Bool = true) {
    var ins = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(inCh), mDataByteSize: UInt32(frames * inCh * 4), mData: input))
    var outs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(outCh), mDataByteSize: UInt32(frames * outCh * 4), mData: output))
    ProcessTap.render(&ins, &outs, state: tap.state, ramp: ramp, isFloat32: isFloat32, eq: eq)
}

/// Копия `ProcessTap.render` до эквалайзера (405a23b), без изменений, чтобы сверять обход байт в байт.
func legacyRender(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
                  state: UnsafeMutablePointer<Float>, ramp: Float, isFloat32: Bool) {
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outs = UnsafeMutableAudioBufferListPointer(output)
    let target = state[0]
    var gain = state[1]
    var peakIn = state[2]
    var peakOut = state[3]
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
        for f in 0..<frames {
            gain += (target - gain) * ramp
            for c in 0..<outCh {
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
                let value = sample * gain
                dst[f * outCh + c] = value
                peakIn = max(peakIn, abs(sample))
                peakOut = max(peakOut, abs(value))
            }
        }
        let written = frames * outCh * 4
        if written < outBytes { memset(outData + written, 0, outBytes - written) }
    }
    if abs(gain - target) < 1e-4 { gain = target }
    state[1] = gain
    state[2] = peakIn
    state[3] = peakOut
}

/// Повторяемый шум и синус, стерео, чередование.
struct Source {
    var seed: UInt64 = 88172645463325252
    mutating func noise() -> Float {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Float(seed % 2_000_001) / 1_000_000 - 1
    }
}

func sine(_ frequency: Double, rate: Double, frames: Int, amplitude: Double, start: Int = 0, channels: Int = 2) -> [Float] {
    var out = [Float](repeating: 0, count: frames * channels)
    for f in 0..<frames {
        let v = Float(amplitude * sin(2 * .pi * frequency * Double(f + start) / rate))
        for c in 0..<channels { out[f * channels + c] = v }
    }
    return out
}

/// Прогон блоками по `block` кадров, как идёт IOProc.
func run(_ input: [Float], tap: TapState, eq: EqEngine, block: Int = 512, inCh: Int = 2, outCh: Int = 2) -> [Float] {
    let frames = input.count / inCh
    var output = [Float](repeating: 0, count: frames * outCh)
    var input = input
    input.withUnsafeMutableBufferPointer { src in
        output.withUnsafeMutableBufferPointer { dst in
            var f = 0
            while f < frames {
                let n = min(block, frames - f)
                render(src.baseAddress! + f * inCh, frames: n, inCh: inCh, output: dst.baseAddress! + f * outCh, outCh: outCh, tap: tap, eq: eq)
                f += n
            }
        }
    }
    return output
}

func rms(_ values: ArraySlice<Float>) -> Double {
    var sum = 0.0
    for v in values { sum += Double(v) * Double(v) }
    return (sum / Double(max(values.count, 1))).squareRoot()
}

/// Усиление синуса через настоящий `render`, дБ, без предусиления: то, что сделали полосы.
func measured(_ bands: [Double], at frequency: Double, rate: Double) -> Double {
    let frames = Int(rate) / 2 // Хвост полки за полсекунды уходит.
    let eq = engine(bands, rate: rate)
    defer { eq.deallocate() }
    let amplitude = 0.02 // Ниже порога ограничителя при любом подъёме.
    let out = run(sine(frequency, rate: rate, frames: frames, amplitude: amplitude), tap: TapState(), eq: eq)
    // Левый канал, последняя половина.
    let left = stride(from: frames, to: frames * 2, by: 2).map { out[$0] }
    return 20 * log10(rms(left[...]) / (amplitude / 2.0.squareRoot())) - 20 * log10(eq.currentPreamp)
}

// MARK: - АЧХ

func response() {
    for rate in [44100.0, 48000, 96000] {
        var worstNear = 0.0, worstFar = 0.0
        for band in 0..<10 {
            for set in [12.0, 6, -6, -12] {
                let bands = single(band, set)
                let gain = measured(bands, at: bandFrequencies[band], rate: rate)
                check(abs(gain - set) < 1.25, "АЧХ \(Int(rate)) Гц, полоса \(Int(bandFrequencies[band])): задано \(set), измерено \(String(format: "%.2f", gain))")
                // Полоса в октаву задевает соседа; полке больше, она продолжается дальше подписи.
                let shelf = band == 0 || band == 9
                for other in 0..<10 where other != band {
                    let share = abs(measured(bands, at: bandFrequencies[other], rate: rate)) / abs(set)
                    let near = abs(other - band) == 1
                    if near { worstNear = max(worstNear, share) } else { worstFar = max(worstFar, share) }
                    let otherShelf = other == 0 || other == 9
                    let limit = near ? (shelf || otherShelf ? 0.55 : 0.3) : (abs(other - band) == 2 ? 0.12 : 0.03)
                    if share > limit { check(false, "АЧХ \(Int(rate)): полоса \(Int(bandFrequencies[band])) на \(Int(bandFrequencies[other])) задета на \(String(format: "%.0f", share * 100)) %") }
                }
            }
        }
        check(true, "АЧХ \(Int(rate)) Гц: сосед задет до \(String(format: "%.0f", worstNear * 100)) %, дальние до \(String(format: "%.0f", worstFar * 100)) %")
    }
    // Режимы звучат так, как задуманы: знак верный, и обещанное заметно.
    let gain = { (id: String, f: Double) in measured(preset(id), at: f, rate: 48000) }
    check(gain("bass", 64) - gain("bass", 1000) > 4.5, "«Больше баса»: 64 Гц громче 1 кГц")
    check(gain("treble", 16000) - gain("treble", 250) > 4.5, "«Больше верхов»: 16 кГц громче 250 Гц")
    check(gain("voice", 2000) - gain("voice", 32) > 8, "«Голос»: 2 кГц громче 32 Гц")
    check(gain("podcast", 1000) - gain("podcast", 32) > 6 && gain("podcast", 1000) - gain("podcast", 16000) > 2, "«Подкасты»: середина громче краёв")
    check(gain("music", 32) - gain("music", 1000) > 2.5 && gain("music", 16000) - gain("music", 1000) > 2.5, "«Музыка»: края громче середины")
    check(gain("night", 1000) - gain("night", 32) > 5 && gain("night", 1000) - gain("night", 16000) > 4, "«Поздно ночью»: меньше баса и крайних верхов")
    // Предусиление считает всю цепочку: на обычном уровне ограничитель молчит, и режим не теряет форму.
    for item in MixerEq.presets {
        guard let bands = item.bands else { continue }
        for f in bandFrequencies {
            let eq = engine(bands, rate: 48000)
            let out = run(sine(f, rate: 48000, frames: 12000, amplitude: 0.8), tap: TapState(), eq: eq)
            let peak = out[12000...].map { abs($0) }.max() ?? 0
            if peak >= 0.86 { check(false, "\(item.title), \(Int(f)) Гц, вход 0,8: пик \(peak), ограничитель работает на обычном уровне") }
            eq.deallocate()
        }
    }
    check(true, "все режимы: вход 0,8 на любой из десяти частот не упирается в ограничитель")
    // Низкие и обычные частоты устройства: каждая полоса устойчива при любых значениях, полосы выше Найквиста не ломают звук.
    for rate in [4000.0, 8000, 11025, 16000, 17778, 22050, 24000, 32000, 35556, 44100, 48000, 88200, 96000, 176400, 192000, 384000] {
        for bands in [allUp, allDown, zigzag, zagzig, single(9, 12), single(9, -12), single(8, 12)] {
            let eq = engine(bands, rate: rate)
            var stable = true
            for band in 0..<10 {
                let a1 = eq.target[band * 5 + 3], a2 = eq.target[band * 5 + 4]
                // Треугольник устойчивости биквада.
                if !(abs(a2) < 1 && abs(a1) < 1 + a2) { stable = false }
            }
            check(stable, "частота устройства \(Int(rate)), \(bands.prefix(2))…: полюса всех полос внутри круга")
            var source = Source()
            var noise = [Float](repeating: 0, count: 40000)
            for i in noise.indices { noise[i] = source.noise() }
            let out = run(noise, tap: TapState(), eq: eq)
            check(out.allSatisfy { $0.isFinite && abs($0) <= 1 }, "частота устройства \(Int(rate)), \(bands.prefix(2))…: шум полного размаха, выход в пределах")
            eq.deallocate()
        }
    }
    // 16 кГц при 44,1 кГц считается и выше 2×16 кГц не падает: верхняя полоса при 32 кГц — полка с углом 9 кГц, ещё работает.
    check(measured(single(9, 12), at: 12000, rate: 32000) > 6, "32 кГц: верхняя полоса всё ещё поднимает 12 кГц")
}

// MARK: - Обход

func bypass() {
    var source = Source()
    for (inCh, outCh, name) in [(2, 2, "стерео"), (2, 1, "моно"), (2, 6, "шесть каналов"), (1, 2, "вход моно")] {
        for gain in [Float(1), 0.37, 0] {
            let frames = 4096
            var input = [Float](repeating: 0, count: frames * inCh)
            for i in input.indices { input[i] = source.noise() * 1.2 } // Выше 1 тоже: обход ничего не режет.
            // Значения есть, выключатель выключен: в фильтры идёт то же, что у ровного.
            let eq = engine(MixerEqSetting(enabled: false, preset: "voice", bands: preset("voice")).soundingBands, rate: 48000)
            let tap = TapState(gain: gain == 1 ? 1 : 0.8)
            tap.state[0] = gain
            let old = TapState(gain: gain == 1 ? 1 : 0.8)
            old.state[0] = gain
            var a = [Float](repeating: 1, count: frames * outCh)
            var b = [Float](repeating: 2, count: frames * outCh)
            input.withUnsafeMutableBufferPointer { src in
                a.withUnsafeMutableBufferPointer { dst in
                    render(src.baseAddress!, frames: frames, inCh: inCh, output: dst.baseAddress!, outCh: outCh, tap: tap, eq: eq)
                }
                b.withUnsafeMutableBufferPointer { dst in
                    var ins = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(inCh), mDataByteSize: UInt32(frames * inCh * 4), mData: src.baseAddress!))
                    var outs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(outCh), mDataByteSize: UInt32(frames * outCh * 4), mData: dst.baseAddress!))
                    legacyRender(&ins, &outs, state: old.state, ramp: 0.001, isFloat32: true)
                }
            }
            let same = a.withUnsafeBytes { x in b.withUnsafeBytes { y in memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 } }
            check(same, "обход, \(name), громкость \(gain): выход байт в байт как до эквалайзера")
            check((0..<4).allSatisfy { tap.state[$0].bitPattern == old.state[$0].bitPattern }, "обход, \(name), громкость \(gain): громкость и пики те же")
            eq.deallocate()
        }
    }

    // Был подъём, вернулись к ровному: переход кончается и путь снова прежний.
    let eq = engine(preset("music"), rate: 48000)
    let tap = TapState()
    _ = run(sine(440, rate: 48000, frames: 9600, amplitude: 0.5), tap: tap, eq: eq)
    check(eq.begin(channels: 2), "с подъёмом эквалайзер работает")
    publish(eq, MixerEq.flat, rate: 48000)
    check(eq.begin(channels: 2), "сразу после возврата к ровному идёт переход")
    _ = run(sine(440, rate: 48000, frames: 48000, amplitude: 0.5), tap: tap, eq: eq)
    check(!eq.begin(channels: 2), "через секунду переход кончился, эквалайзер выключен")
    check((0..<EqEngine.historySize).allSatisfy { eq.history[$0] == 0 }, "и история обнулена")
    let input = sine(440, rate: 48000, frames: 2048, amplitude: 0.9)
    let out = run(input, tap: tap, eq: eq)
    let exact = zip(input, out).allSatisfy { $0.bitPattern == ($1 / 1).bitPattern }
    check(exact, "после перехода выход равен входу байт в байт")
    eq.deallocate()
}

// MARK: - Крайние значения

func extremes() {
    let sets: [[Double]] = [allUp, allDown, zigzag, zagzig, single(0, 12), single(9, 12), single(4, 12)]
    for rate in [44100.0, 48000, 96000] {
        for bands in sets {
            let eq = engine(bands, rate: rate)
            var source = Source()
            var input = [Float](repeating: 0, count: Int(rate) * 2)
            for i in input.indices { input[i] = source.noise() }
            // Полный размах: шум, меандр, синусы на частотах полос.
            var chunks = [input, (0..<20000).map { Float($0 / 20 % 2 == 0 ? 1 : -1) }]
            for f in bandFrequencies { chunks.append(sine(f, rate: rate, frames: 20000, amplitude: 1)) }
            var worst: Float = 0
            var bad = false
            for chunk in chunks {
                for v in run(chunk, tap: TapState(), eq: eq) {
                    if !v.isFinite { bad = true }
                    worst = max(worst, abs(v))
                }
            }
            check(!bad && worst <= 1, "\(Int(rate)) Гц, \(bands.prefix(3))…: выход конечен и в [−1; 1], наибольший \(worst)")
            let stable = (0..<EqEngine.historySize).allSatisfy { eq.history[$0].isFinite && abs(eq.history[$0]) < 100 }
            check(stable, "\(Int(rate)) Гц, \(bands.prefix(3))…: история ограничена, фильтр устойчив")
            eq.deallocate()
        }
    }

    // Подъём съедается предусилением: тихий звук не упирается в ограничитель, форма синуса цела.
    let eq = engine(allUp, rate: 48000)
    let out = run(sine(1000, rate: 48000, frames: 48000, amplitude: 0.5), tap: TapState(), eq: eq)
    let tail = out[48000...].map { abs($0) }.max() ?? 0
    check(tail < 0.89, "все +12, вход 0,5: ограничитель не работает, пик \(tail)")
    eq.deallocate()
}

func poison() {
    let bands = preset("music")
    let bad = engine(bands, rate: 48000)
    let clean = engine(bands, rate: 48000)
    let tapBad = TapState(), tapClean = TapState()
    let music = sine(300, rate: 48000, frames: 4800, amplitude: 0.5)
    _ = run(music, tap: tapBad, eq: bad)
    _ = run(music, tap: tapClean, eq: clean)
    for (name, poisoned) in [("NaN", Float.nan), ("+Inf", Float.infinity), ("−Inf", -Float.infinity), ("сигнальный NaN", Float.signalingNaN), ("1e30", 1e30)] {
        var burst = [Float](repeating: poisoned, count: 256)
        burst[100] = 0.3
        let out = run(burst, tap: tapBad, eq: bad)
        check(out.allSatisfy { $0.isFinite && abs($0) <= 1 }, "вход \(name): выход конечен и в пределах")
        check((0..<EqEngine.historySize).allSatisfy { bad.history[$0].isFinite }, "вход \(name): в истории нет NaN и Inf")
    }
    // После отравления фильтр снова считает как чистый: хвост от всплеска ушёл, расхождения нет.
    let after = sine(300, rate: 48000, frames: 96000, amplitude: 0.5, start: 4800)
    let a = run(after, tap: tapBad, eq: bad), b = run(after, tap: tapClean, eq: clean)
    let gap = zip(a[150000...], b[150000...]).map { abs($0 - $1) }.max() ?? 1
    check(gap < 1e-4, "после отравления выход сходится с чистым, разница \(gap)")
    bad.deallocate()
    clean.deallocate()
}

// MARK: - Резкая смена

func jumps() {
    let rate = 48000.0
    // Низкий синус: его собственный шаг мал (0,0065), и скачок от смены коэффициентов виден сразу.
    let changes: [([Double], [Double])] = [
        (MixerEq.flat, single(0, 12)), (single(0, 12), MixerEq.flat), (MixerEq.flat, single(9, 12)),
        (MixerEq.flat, allUp), (allUp, allDown), (zigzag, zagzig), (allDown, MixerEq.flat), (preset("bass"), preset("night")),
    ]
    for (from, to) in changes {
        let eq = engine(from, rate: rate)
        let tap = TapState()
        // Смена на гребне синуса (четверть периода): там скачок был бы наибольшим.
        let settled = 48000 + 120
        let before = run(sine(100, rate: rate, frames: settled, amplitude: 0.5), tap: tap, eq: eq)
        publish(eq, to, rate: rate)
        let out = run(sine(100, rate: rate, frames: 48000, amplitude: 0.5, start: settled), tap: tap, eq: eq, block: 256)
        var worst = abs(out[0] - before[before.count - 2])
        for i in stride(from: 2, to: out.count, by: 2) { worst = max(worst, abs(out[i] - out[i - 2])) }
        check(worst < 0.02, "смена \(from.prefix(3))… → \(to.prefix(3))…: наибольший скачок \(worst)")
        eq.deallocate()
    }
    // Смена на каждом блоке, как при движении регулятора.
    let eq = engine(MixerEq.flat, rate: rate)
    let tap = TapState()
    var worst: Float = 0
    var previous: Float?
    for step in 0..<400 {
        publish(eq, [Double(step % 49) / 2 - 12, 0, Double(step % 25) - 12, 0, 12 - Double(step % 49) / 2, 0, Double(step % 25) - 12, 0, 0, 12 - Double(step % 49) / 2], rate: rate)
        let out = run(sine(100, rate: rate, frames: 128, amplitude: 0.5, start: step * 128), tap: tap, eq: eq, block: 128)
        for i in stride(from: 0, to: out.count, by: 2) {
            if let previous { worst = max(worst, abs(out[i] - previous)) }
            previous = out[i]
        }
    }
    check(worst < 0.03 && !worst.isNaN, "регулятор в движении: наибольший скачок \(worst)")
    eq.deallocate()
}

// MARK: - Тишина и каналы

func silenceAndChannels() {
    let eq = engine(zigzag, rate: 96000)
    let tap = TapState()
    var source = Source()
    var loud = [Float](repeating: 0, count: 96000)
    for i in loud.indices { loud[i] = source.noise() }
    _ = run(loud, tap: tap, eq: eq)
    let silent = [Float](repeating: 0, count: 1024)
    var subnormal = 0
    for _ in 0..<(96000 * 2 * 60 / 1024) {
        for v in run(silent, tap: tap, eq: eq) where v.isSubnormal { subnormal += 1 }
        for i in 0..<EqEngine.historyPerChannel * 2 where eq.history[i].isSubnormal { subnormal += 1 }
    }
    check(subnormal == 0, "минута тишины: денормалов на выходе и в истории \(subnormal)")
    check((0..<EqEngine.historyPerChannel * 2).allSatisfy { eq.history[$0] == 0 }, "после тишины история ровно ноль: считать нечего")
    eq.deallocate()

    // Каналы независимы.
    let two = engine(single(0, 12).enumerated().map { $0.offset == 9 ? 12 : $0.element }, rate: 48000)
    var split = sine(1000, rate: 48000, frames: 4800, amplitude: 0.5)
    for i in stride(from: 0, to: split.count, by: 2) { split[i] = 0 }
    let out = run(split, tap: TapState(), eq: two)
    check(stride(from: 0, to: out.count, by: 2).allSatisfy { out[$0] == 0 } && rms(out[1...]) > 0.01, "тишина в левом канале остаётся тишиной: состояние у каждого канала своё")
    // Смена формата обнуляет историю.
    check(two.begin(channels: 2), "работает")
    check((0..<EqEngine.historySize).contains { two.history[$0] != 0 }, "история накопилась")
    _ = two.begin(channels: 1)
    check((0..<EqEngine.historySize).allSatisfy { two.history[$0] == 0 }, "другое число каналов: история обнулена")
    _ = run(sine(1000, rate: 48000, frames: 480, amplitude: 0.5, channels: 1), tap: TapState(), eq: two, inCh: 1, outCh: 1)
    check((0..<EqEngine.historySize).contains { two.history[$0] != 0 }, "на новом формате снова считает")
    publish(two, single(0, 12), rate: 44100)
    _ = two.begin(channels: 1)
    check((0..<EqEngine.historySize).allSatisfy { two.history[$0] == 0 }, "другая частота: история обнулена")
    two.deallocate()

    // Новая частота даёт верные коэффициенты, а не только новую историю.
    let moved = engine(single(5, 12), rate: 48000)
    publish(moved, single(5, 12), rate: 96000)
    let frames = 96000
    let output = run(sine(1000, rate: 96000, frames: frames, amplitude: 0.02), tap: TapState(), eq: moved)
    let left = stride(from: frames, to: frames * 2, by: 2).map { output[$0] }
    let gain = 20 * log10(rms(left[...]) / (0.02 / 2.0.squareRoot())) - 20 * log10(moved.currentPreamp)
    check(abs(gain - 12) < 1, "смена частоты 48 → 96 кГц: 1 кГц снова +12, измерено \(String(format: "%.2f", gain))")
    moved.deallocate()

    // Широкие форматы и не Float32.
    for outCh in [1, 2, 3, 6, 8, 16, 17, 32, 64] {
        let wide = engine(preset("voice"), rate: 48000)
        let tap = TapState()
        let out = run(sine(440, rate: 48000, frames: 4096, amplitude: 1), tap: tap, eq: wide, outCh: outCh)
        check(out.count == 4096 * outCh && out.allSatisfy { $0.isFinite }, "\(outCh) каналов на выходе: без падения, значения конечны")
        let peak = out.map { abs($0) }.max() ?? 0
        check(peak <= 1.0001, "\(outCh) каналов: в пределах, пик \(peak)")
        wide.deallocate()
    }
    let many = engine(preset("voice"), rate: 48000)
    let wider = run(sine(440, rate: 48000, frames: 2048, amplitude: 0.5), tap: TapState(), eq: many, outCh: EqEngine.maxChannels + 1)
    let plain = sine(440, rate: 48000, frames: 2048, amplitude: 0.5)
    let dry = stride(from: 0, to: 2048 * (EqEngine.maxChannels + 1), by: EqEngine.maxChannels + 1).enumerated().allSatisfy { wider[$1] == plain[$0 * 2] }
    check(dry, "шире памяти истории: поток идёт без эквалайзера, только с громкостью")
    many.deallocate()

    let eqFloat = engine(allUp, rate: 48000)
    var raw = [Float](repeating: 0, count: 2048)
    var noise = Source()
    for i in raw.indices { raw[i] = noise.noise() }
    var copy = [Float](repeating: 9, count: 2048)
    raw.withUnsafeMutableBufferPointer { src in
        copy.withUnsafeMutableBufferPointer { dst in
            render(src.baseAddress!, frames: 1024, output: dst.baseAddress!, tap: TapState(gain: 0.3), eq: eqFloat, isFloat32: false)
        }
    }
    check(copy == raw, "не Float32: копия как есть, ни эквалайзера, ни громкости")
    check((0..<EqEngine.historySize).allSatisfy { eqFloat.history[$0] == 0 }, "не Float32: история не трогается")
    eqFloat.deallocate()

    // Несколько выходных потоков: у второго нет входа, он как раньше получает нули.
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { list.unsafeMutablePointer.deallocate() }
    let streams = engine(preset("bass"), rate: 48000)
    var a = [Float](repeating: 9, count: 1024), b = [Float](repeating: 9, count: 1024)
    var source2 = sine(440, rate: 48000, frames: 512, amplitude: 0.5)
    a.withUnsafeMutableBytes { pa in
        b.withUnsafeMutableBytes { pb in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096, mData: pa.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096, mData: pb.baseAddress)
            source2.withUnsafeMutableBytes { ps in
                var ins = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096, mData: ps.baseAddress))
                ProcessTap.render(&ins, list.unsafeMutablePointer, state: TapState().state, ramp: 0.001, isFloat32: true, eq: streams)
            }
        }
    }
    check(b.allSatisfy { $0 == 0 } && a.contains { $0 != 0 && $0 != 9 }, "второй поток без входа: нули, первый звучит")
    streams.deallocate()
}

// MARK: - Передача коэффициентов

func concurrency() {
    let rate = 48000.0
    let bank: [[Double]] = [allUp, allDown, zigzag, preset("voice"), MixerEq.flat, single(0, 0.5)]
    // Эталоны: номер формата 1, те же формулы.
    let references: [[Double]] = bank.map { bands in
        var set = [Double](repeating: 0, count: EqEngine.setSize)
        set.withUnsafeMutableBufferPointer { out in
            bands.withUnsafeBufferPointer { EqEngine.fill(out.baseAddress!, bands: $0, rate: rate, epoch: 1) }
        }
        return set
    }
    let eq = EqEngine()
    publish(eq, bank[0], rate: rate)
    eq.takeLatest()
    let stop = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    stop.pointee = 0
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable {
        let eq: EqEngine, stop: UnsafeMutablePointer<Int32>, bank: [[Double]], rate: Double
        init(_ eq: EqEngine, _ stop: UnsafeMutablePointer<Int32>, _ bank: [[Double]], _ rate: Double) { self.eq = eq; self.stop = stop; self.bank = bank; self.rate = rate }
    }
    let box = Box(eq, stop, bank, rate)
    let writer = Thread {
        var i = 0
        while !OSAtomicCompareAndSwap32Barrier(1, 1, box.stop) {
            box.bank[i % box.bank.count].withUnsafeBufferPointer { box.eq.publish(bands: $0, rate: box.rate) }
            i += 1
        }
        done.signal()
    }
    writer.qualityOfService = .userInitiated
    writer.start()

    var reads = 0, torn = 0, takes = 0
    var last: UnsafeMutablePointer<Double>?
    let size = EqEngine.setSize
    let refs = references.map { r -> UnsafeMutablePointer<Double> in
        let p = UnsafeMutablePointer<Double>.allocate(capacity: size)
        p.initialize(from: r, count: size)
        return p
    }
    let end = Date().addingTimeInterval(3)
    // Читатель как `render`: забрал набор и проверил его целиком, несколько раз подряд: чужая запись успела бы вклиниться.
    while Date() < end {
        for _ in 0..<2000 {
            eq.takeLatest()
            let set = eq.target
            if set != last { takes += 1; last = set }
            for _ in 0..<4 {
                reads += 1
                var whole = false
                for ref in refs where memcmp(set, ref, size * 8) == 0 { whole = true }
                if !whole { torn += 1 }
            }
        }
    }
    OSAtomicCompareAndSwap32Barrier(0, 1, stop)
    done.wait()
    check(reads > 10000 && takes > 100, "писатель и читатель работают одновременно: чтений \(reads), смен набора \(takes)")
    check(torn == 0, "читатель всегда видит целый набор: половинных \(torn)")
    // Последняя запись не теряется.
    publish(eq, bank[3], rate: rate)
    eq.takeLatest()
    check(memcmp(eq.target, refs[3], size * 8) == 0, "после остановки читатель видит последний набор")
    for r in refs { r.deallocate() }
    stop.deallocate()
    eq.deallocate()
}

/// Ни одной новой памяти за настоящие вызовы. Считает чистый остаток блоков, поэтому парные malloc и free не видит: вторая линия за стражем по исходникам.
func noAllocations() {
    let eq = engine(preset("music"), rate: 48000)
    let tap = TapState()
    let input = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    var source = Source()
    for i in 0..<2048 { input[i] = source.noise() }
    let flat = preset("voice")
    render(input, frames: 1024, output: output, tap: tap, eq: eq)
    var before = malloc_statistics_t(), after = malloc_statistics_t()
    malloc_zone_statistics(nil, &before)
    for step in 0..<2000 {
        render(input, frames: 1024, output: output, tap: tap, eq: eq)
        if step == 1000 { flat.withUnsafeBufferPointer { eq.publish(bands: $0, rate: 48000) } }
    }
    malloc_zone_statistics(nil, &after)
    check(after.blocks_in_use <= before.blocks_in_use, "2000 вызовов render: блоков памяти было \(before.blocks_in_use), стало \(after.blocks_in_use)")
    input.deallocate()
    output.deallocate()
    eq.deallocate()
}

// MARK: - Проверка значений и настройки

func validation() {
    check(MixerEq.isValid(MixerEq.flat), "десять нулей верны")
    check(MixerEq.isValid([12, -12, 0, 0.5, -0.0, 1, 2, 3, 4, 5]), "границы верны")
    let ones = { (n: Int) in [Double](repeating: 1, count: n) }
    for (name, bands) in [("пусто", []), ("5 полос", ones(5)), ("9 полос", ones(9)), ("11 полос", ones(11)), ("13 полос", ones(13)),
                          ("выше предела", single(0, 12.5)), ("ниже предела", single(9, -12.01)), ("NaN", single(1, .nan)),
                          ("+Inf", single(2, .infinity)), ("−Inf", single(3, -.infinity)), ("1e308", single(4, 1e308))] as [(String, [Double])] {
        check(!MixerEq.isValid(bands), "\(name): отказ")
        check(!MixerEqSetting(enabled: true, preset: "custom", bands: bands).isValid, "\(name): настройка не верна")
    }
    for id in ["", "voice ", "Голос", "CUSTOM", String(repeating: "a", count: 300), "<script>"] {
        check(!MixerEqSetting(enabled: true, preset: id, bands: MixerEq.flat).isValid, "режим «\(id.prefix(10))»: отказ")
    }
    check(MixerEq.presets.map(\.title) == ["Ровно", "Больше баса", "Больше верхов", "Голос", "Подкасты", "Музыка", "Поздно ночью", "Свой"], "восемь режимов по заданию")
    check(MixerEq.presets.allSatisfy { p in p.bands.map(MixerEq.isValid) ?? (p.id == MixerEq.customID) } && MixerEq.isFlat(preset("flat")), "значения режимов верны, «Ровно» ровный, у «Своего» значений нет")
    check(Set(MixerEq.presets.compactMap(\.bands)).count == 7, "значения режимов различаются")
    check(MixerEq.bandTitles.count == MixerEq.bandCount, "подписей столько же, сколько полос")

    // Выключатель и режим.
    let voice = MixerEqSetting.off.choosing(MixerEq.presets[3])
    check(voice.bands == preset("voice") && voice.preset == "voice" && !voice.enabled, "выбор режима меняет значения и имя, выключатель не трогает")
    var on = voice
    on.enabled = true
    check(on.isActive && on.soundingBands == voice.bands, "включённый со значениями работает")
    check(!voice.isActive && MixerEq.isFlat(voice.soundingBands) && voice.bands == preset("voice"), "выключенный идёт обходом, значения те же")
    let edited = on.editing(band: 3, to: 7.5)
    check(edited.preset == MixerEq.customID && edited.bands[3] == 7.5 && edited.bands[0] == on.bands[0] && edited.enabled, "ручная правка переключает на «Свой», значения остаются")
    let kept = edited.choosing(MixerEq.presets.last!)
    check(kept == edited, "выбор «Своего» значения не меняет")
    let flatOn = MixerEqSetting(enabled: true, preset: "flat", bands: MixerEq.flat)
    check(!flatOn.isActive && !MixerEqSetting.off.isActive, "включённый ровный ничего не меняет: тап не нужен")
    check(!edited.editing(band: 3, to: 0).bands.contains(7.5), "двойной щелчок идёт той же правкой: значение 0")

    // Значение мимо проверки: звук остаётся цел.
    let eq = engine([.nan, .infinity, -.infinity, 1e308, -1e308, 0, 0, 0, 0, 0], rate: .nan)
    let out = run(sine(440, rate: 48000, frames: 4096, amplitude: 0.5), tap: TapState(), eq: eq)
    check(out.allSatisfy { $0.isFinite && abs($0) <= 1 }, "мусор мимо проверки и NaN вместо частоты: выход конечен")
    eq.deallocate()
    let short = engine([12, 12], rate: 48000)
    check(run(sine(440, rate: 48000, frames: 4096, amplitude: 0.5), tap: TapState(), eq: short).allSatisfy { $0.isFinite && abs($0) <= 1 }, "короткий список мимо проверки: без выхода за память")
    short.deallocate()
    let long = engine([Double](repeating: 12, count: 13), rate: 48000)
    check(run(sine(440, rate: 48000, frames: 4096, amplitude: 0.5), tap: TapState(), eq: long).allSatisfy { $0.isFinite && abs($0) <= 1 }, "длинный список мимо проверки: лишнее не читается")
    long.deallocate()
    for rate in [0.0, -44100, .infinity] {
        let other = engine(allUp, rate: rate)
        let out = run(sine(440, rate: 48000, frames: 4096, amplitude: 0.5), tap: TapState(), eq: other)
        check(out.allSatisfy { $0.isFinite && abs($0) <= 1 }, "частота \(rate): выход конечен")
        other.deallocate()
    }
}

func settings() {
    let suite = "local.utilitumus.test.mixer-eq"
    guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "тестовый домен не открылся") }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    check(MixerEqSettings.read(from: defaults).isEmpty, "пустой домен: настроек нет")
    // Как у прежней версии: только громкости.
    defaults.set(["com.a": 0.4], forKey: "MixerVolumes")
    defaults.set(["com.b"], forKey: "MixerMuted")
    check(MixerEqSettings.read(from: defaults).isEmpty, "старые настройки без эквалайзера читаются, эквалайзера в них нет")
    let saved: [String: MixerEqSetting] = [
        "com.a": MixerEqSetting(enabled: true, preset: "voice", bands: preset("voice")),
        "exe:afplay": MixerEqSetting(enabled: false, preset: "custom", bands: [-12, 12, 0.5, -0.5, 0, 1, 2, 3, 4, 5]),
    ]
    MixerEqSettings.write(saved, to: defaults)
    defaults.synchronize()
    check(MixerEqSettings.read(from: UserDefaults(suiteName: suite)!) == saved, "запись и чтение на тестовом домене по устойчивому id, с выключателем и режимом")
    check(defaults.dictionary(forKey: "MixerVolumes") as? [String: Double] == ["com.a": 0.4], "ключ громкостей не задет: старая версия прочитает своё")
    MixerEqSettings.write([:], to: defaults)
    check(MixerEqSettings.read(from: defaults).isEmpty, "пустая запись стирает")
    // С диска тоже чужие значения не проходят.
    let good = saved["com.a"]!
    let fields = { (e: Any, p: Any, b: Any) -> [String: Any] in ["enabled": e, "preset": p, "bands": b] }
    defaults.set(["ok": fields(true, "voice", good.bands), "11": fields(true, "custom", [Double](repeating: 1, count: 11)), "big": fields(true, "custom", single(0, 99)),
                  "text": "x", "nan": fields(true, "custom", single(0, .nan)), "words": fields(true, "custom", ["a", "b"]), "preset": fields(true, "чужой", MixerEq.flat),
                  "switch": fields("да", "flat", MixerEq.flat), "missing": ["enabled": true], "off": fields(false, "flat", MixerEq.flat)] as [String: Any], forKey: MixerEqSettings.key)
    check(MixerEqSettings.read(from: defaults) == ["ok": good], "битые записи с диска отброшены, хорошая цела")
    defaults.set("мусор", forKey: MixerEqSettings.key)
    check(MixerEqSettings.read(from: defaults).isEmpty, "ключ не того типа: настроек нет, не падает")
}

// MARK: - Нагрузка

/// Настоящий `render`, 512 кадров стерео при 48 кГц, то есть 10,67 мс звука. Медиана: очередь сборок рядом шумит, а не сам код.
func load() {
    let frames = 512
    let budget = Double(frames) / 48000 * 1_000_000
    let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    var source = Source()
    for i in 0..<frames * 2 { input[i] = source.noise() * 0.5 }
    func median(_ eq: EqEngine, moving: Bool) -> Double {
        let tap = TapState()
        var times: [Double] = []
        times.reserveCapacity(3000)
        var flip = false
        for _ in 0..<3000 {
            if moving {
                flip.toggle()
                publish(eq, flip ? allUp : allDown, rate: 48000)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            render(input, frames: frames, output: output, tap: tap, eq: eq)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        return times.sorted()[times.count / 2]
    }
    let off = engine(MixerEq.flat, rate: 48000), on = engine(preset("music"), rate: 48000), moving = engine(allUp, rate: 48000)
    let bypassTime = median(off, moving: false), activeTime = median(on, moving: false), movingTime = median(moving, moving: true)
    let report = { (name: String, value: Double) in String(format: "%@: %.1f мкс на буфер, %.2f %% от длины буфера %.0f мкс", name, value, value / budget * 100, budget) }
    print("     нагрузка, " + report("обход", bypassTime))
    print("     нагрузка, " + report("10 полос", activeTime))
    print("     нагрузка, " + report("10 полос, идёт переход", movingTime))
    check(activeTime < budget * 0.05, report("10 полос дешевле 5 % буфера", activeTime))
    check(movingTime < budget * 0.1, report("переход дешевле 10 % буфера", movingTime))
    off.deallocate(); on.deallocate(); moving.deallocate()
    input.deallocate(); output.deallocate()
}

@main
enum Main {
    static func main() {
        validation()
        settings()
        response()
        bypass()
        extremes()
        poison()
        jumps()
        silenceAndChannels()
        noAllocations()
        load()
        concurrency()
        print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
