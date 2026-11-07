import Darwin

/// Десятиполосный эквалайзер одного тапа: полки по краям и восемь пиков между ними, формулы RBJ (Robert Bristow-Johnson,
/// «Cookbook formulae for audio EQ biquad filter coefficients»). Значения приходят только проверенными (`MixerEq.isValid`),
/// а `publish` всё равно зажимает их: в звуковой код чужое число не попадает ни при какой ошибке выше.
///
/// **Передача коэффициентов.** Тройной буфер: три заранее выделенных набора, у писателя свой, у читателя свой, третий лежит
/// в общем слове `exchange` вместе с признаком «свежий». Писатель (главный поток) заполняет свой набор целиком и меняет его
/// с общим атомарной заменой с барьером. Читатель в начале буфера, если признак стоит, так же меняет свой набор с общим.
/// Каждый читает и пишет только свой набор, поэтому половину чужой записи увидеть нельзя, и никто никого не ждёт. Два набора
/// здесь не годятся: вторая запись подряд пошла бы в набор, который читатель ещё читает. `Atomic` из Synchronization
/// требует macOS 15, поэтому замена через `OSAtomicCompareAndSwap32Barrier`: без блокировок и без аллокаций.
///
/// **Плавность.** Коэффициенты, предусиление и доля ограничителя идут к новому набору каждый кадр, одним полюсом с постоянной
/// 5 мс. Устойчивые наборы биквада образуют выпуклую область, поэтому промежуточный набор тоже устойчив. Форма прямая (DF1):
/// в её памяти входы и выходы, а не величины, зависящие от коэффициентов, поэтому при движении коэффициентов скачка нет.
///
/// **Обход.** Цель ровная и переход закончен: `begin` вернёт false, фильтры не вызываются вообще, а история обнулена.
/// На 0 дБ фильтр математически единичный, поэтому граница переключения не слышна.
///
/// **Порядок в тракте.** вход → предусиление → полосы → ограничитель → громкость → выход. Эквалайзер до громкости: тембр и
/// срабатывание ограничителя не зависят от положения ползунка, а громкость не больше 1 не выводит за предел. Пик входа
/// считается по сырому входу, пик выхода по тому, что ушло на устройство.
///
/// Всё считается в Double: у полки 60 Гц при 96 кГц полюса почти на единичной окружности, Float там шумит.
/// Структура из одних указателей: копируется в блок IOProc без подсчёта ссылок.
struct EqEngine {
    /// Каналов с историей. Шире не бывает на обычных выводах; лишние каналы идут без эквалайзера, см. `ProcessTap.render`.
    static var maxChannels: Int { 16 }
    private static var bands: Int { 10 }
    private static var stageSize: Int { 5 }

    // Раскладка набора: коэффициенты b0 b1 b2 a1 a2 всех полос, дальше предусиление, доля ограничителя, шаг сглаживания, номер формата.
    private static var preamp: Int { 50 }
    private static var limiterShare: Int { 51 }
    /// Сколько значений набора идут плавно.
    private static var smoothed: Int { 52 }
    private static var smoothStep: Int { 52 }
    private static var formatEpoch: Int { 53 }
    static var setSize: Int { 54 }
    static var historyPerChannel: Int { 40 }
    static var historySize: Int { maxChannels * historyPerChannel }

    private static var freshBit: Int32 { 4 }
    private static var settled: Double { 1e-7 }
    /// Меньше этого в истории и на выходе становится нулём: денормалы не успевают появиться (около −500 дБ).
    private static var silence: Double { 1e-25 }
    /// Порог ограничителя, −1 дБ: ниже него звук не меняется.
    private static var limiterKnee: Double { 0.891 }

    /// Три набора подряд. Чей какой, знают `writer`, `reader[0]` и `exchange`.
    let sets: UnsafeMutablePointer<Double>
    private let exchange: UnsafeMutablePointer<Int32>
    /// Номер набора писателя. Меняет только главный поток.
    private let writer: UnsafeMutablePointer<Int32>
    /// Поля читателя: 0 — номер его набора, 1 — число каналов прошлого буфера, 2 — идёт переход.
    private let reader: UnsafeMutablePointer<Int>
    /// Живые значения: первые `smoothed` из набора; последним идёт номер формата, который видел читатель.
    let current: UnsafeMutablePointer<Double>
    /// История: на канал и полосу x1 x2 y1 y2.
    let history: UnsafeMutablePointer<Double>
    /// Писатель: 0 — частота, 1 — номер формата.
    private let writerFormat: UnsafeMutablePointer<Double>

    init() {
        sets = .allocate(capacity: Self.setSize * 3)
        exchange = .allocate(capacity: 1)
        writer = .allocate(capacity: 1)
        reader = .allocate(capacity: 3)
        current = .allocate(capacity: Self.setSize)
        history = .allocate(capacity: Self.historySize)
        writerFormat = .allocate(capacity: 2)
        writer.pointee = 0
        exchange.pointee = 1
        reader[0] = 2
        reader[1] = 0
        reader[2] = 0
        writerFormat[0] = 0
        writerFormat[1] = 0
        history.initialize(repeating: 0, count: Self.historySize)
        var slot = 0
        while slot < 3 {
            Self.fillIdentity(sets + slot * Self.setSize, rate: 48000, epoch: 0)
            slot += 1
        }
        current.initialize(from: sets, count: Self.setSize)
    }

    func deallocate() {
        sets.deallocate()
        exchange.deallocate()
        writer.deallocate()
        reader.deallocate()
        current.deallocate()
        history.deallocate()
        writerFormat.deallocate()
    }

    // MARK: - Писатель: главный поток

    /// Первый набор: до запуска звука, поэтому сразу без перехода.
    func start(bands: UnsafeBufferPointer<Double>, rate: Double) {
        publish(bands: bands, rate: rate)
        _ = begin(channels: 0)
        current.update(from: target, count: Self.setSize)
        reader[2] = 0
    }

    /// Посчитать новый набор и отдать читателю. Другая частота значит новый номер формата: читатель обнулит историю.
    func publish(bands: UnsafeBufferPointer<Double>, rate: Double) {
        let usable = rate.isFinite && rate > 0 ? rate : 48000
        if writerFormat[0] != usable {
            writerFormat[0] = usable
            writerFormat[1] += 1
        }
        let set = sets + Int(writer.pointee) * Self.setSize
        Self.fill(set, bands: bands, rate: usable, epoch: writerFormat[1])
        // Замена с барьером: набор виден читателю только целиком. Спорит с нею один читатель, поэтому цикл короткий.
        var old = exchange.pointee
        while !OSAtomicCompareAndSwap32Barrier(old, writer.pointee | Self.freshBit, exchange) { old = exchange.pointee }
        writer.pointee = old & ~Self.freshBit
    }

    /// Набор по значениям полос, без публикации.
    static func fill(_ set: UnsafeMutablePointer<Double>, bands: UnsafeBufferPointer<Double>, rate: Double, epoch: Double) {
        fillIdentity(set, rate: rate, epoch: epoch)
        var active = false
        var band = 0
        while band < Self.bands {
            // Сюда значения приходят проверенными; зажим и нули на случай ошибки выше.
            let raw = band < bands.count ? bands[band] : 0
            let gain = raw.isFinite ? (raw > 12 ? 12 : (raw < -12 ? -12 : raw)) : 0
            if gain != 0 { active = true }
            // И на 0 дБ настоящие коэффициенты, а не единичные: у полки полюса почти на единице, и переход от них к единичному
            // набору был бы почти скачком уже на первых кадрах. Рядом стоящие наборы идут друг к другу ровно.
            biquad(set + band * stageSize, band: band, gain: gain, rate: rate)
            band += 1
        }
        set[preamp] = active ? 1 / peakResponse(set, rate: rate) : 1
        set[limiterShare] = active ? 1 : 0
    }

    /// Наибольшее усиление всей цепочки по сетке частот, не меньше 1. Соседние полосы через октаву складываются: все +12 дают около
    /// +19 дБ, и предусиление по одной полосе оставляло бы работу ограничителю на обычной музыке. Остаток между точками ловит он.
    private static func peakResponse(_ set: UnsafeMutablePointer<Double>, rate: Double) -> Double {
        var peak = 1.0
        var point = 0
        while point < 64 {
            let frequency = 20 * pow(1000, Double(point) / 63)
            point += 1
            guard frequency < rate * 0.49 else { break }
            let w = 2 * Double.pi * frequency / rate
            let c1 = cos(w), c2 = cos(2 * w), s1 = sin(w), s2 = sin(2 * w)
            var power = 1.0
            var band = 0
            while band < bands {
                let c = set + band * stageSize
                let topRe = c[0] + c[1] * c1 + c[2] * c2, topIm = c[1] * s1 + c[2] * s2
                let lowRe = 1 + c[3] * c1 + c[4] * c2, lowIm = c[3] * s1 + c[4] * s2
                power *= (topRe * topRe + topIm * topIm) / (lowRe * lowRe + lowIm * lowIm)
                band += 1
            }
            let size = power.squareRoot()
            if size > peak { peak = size }
        }
        return peak
    }

    private static func fillIdentity(_ set: UnsafeMutablePointer<Double>, rate: Double, epoch: Double) {
        var i = 0
        while i < setSize {
            set[i] = 0
            i += 1
        }
        var band = 0
        while band < bands {
            set[band * stageSize] = 1
            band += 1
        }
        set[preamp] = 1
        set[smoothStep] = 1 - exp(-1 / (rate * 0.005))
        set[formatEpoch] = epoch
    }

    /// Частота расчёта полосы: 32 Гц ... 16 кГц через октаву. У полок угол внутри диапазона: при угле на подписи там вышла бы половина подъёма.
    private static func corner(_ band: Int) -> Double {
        switch band {
        case 0: return 60
        case 1: return 64
        case 2: return 125
        case 3: return 250
        case 4: return 500
        case 5: return 1000
        case 6: return 2000
        case 7: return 4000
        case 8: return 8000
        default: return 9000
        }
    }

    /// Коэффициенты одной полосы. Полоса выше почти-Найквиста остаётся единичной: при низкой частоте устройства (Bluetooth-гарнитура)
    /// формула не имеет смысла, а 16 кГц при 44,1 кГц ещё считается: угол полки 9 кГц.
    private static func biquad(_ out: UnsafeMutablePointer<Double>, band: Int, gain: Double, rate: Double) {
        let frequency = corner(band)
        guard frequency < rate * 0.45 else { return }
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * frequency / rate
        let cosW = cos(w)
        let sinW = sin(w)
        var b0, b1, b2, a0, a1, a2: Double
        if band == 0 || band == bands - 1 {
            // Наклон S = 1.
            let root = 2 * a.squareRoot() * sinW / 2.0.squareRoot()
            if band == 0 {
                b0 = a * ((a + 1) - (a - 1) * cosW + root)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
                b2 = a * ((a + 1) - (a - 1) * cosW - root)
                a0 = (a + 1) + (a - 1) * cosW + root
                a1 = -2 * ((a - 1) + (a + 1) * cosW)
                a2 = (a + 1) + (a - 1) * cosW - root
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosW + root)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
                b2 = a * ((a + 1) + (a - 1) * cosW - root)
                a0 = (a + 1) - (a - 1) * cosW + root
                a1 = 2 * ((a - 1) - (a + 1) * cosW)
                a2 = (a + 1) - (a - 1) * cosW - root
            }
        } else {
            // Q = 1,41, полоса в октаву: соседняя задета примерно на 21 % подъёма, следующая на 4 %.
            let alpha = sinW / (2 * 1.41)
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a
        }
        out[0] = b0 / a0
        out[1] = b1 / a0
        out[2] = b2 / a0
        out[3] = a1 / a0
        out[4] = a2 / a0
    }

    // MARK: - Реалтайм: никаких аллокаций, блокировок и логов. Страж: Tests/run-mixer-eq-check.sh

    /// Предусиление текущего набора.
    var currentPreamp: Double { current[Self.preamp] }

    /// Набор, к которому идёт звук. Принадлежит читателю.
    var target: UnsafeMutablePointer<Double> { sets + reader[0] * Self.setSize }

    /// Забрать свежий набор, если он есть: писатель положит следующий уже в другой.
    func takeLatest() {
        var word = exchange.pointee
        while word & Self.freshBit != 0 {
            if OSAtomicCompareAndSwap32Barrier(word, Int32(reader[0]), exchange) {
                reader[0] = Int(word & ~Self.freshBit)
                reader[2] = 1
                return
            }
            word = exchange.pointee
        }
    }

    /// Начало буфера: свежий набор и смена формата. true — эквалайзер работает, false — путь звука прежний.
    func begin(channels: Int) -> Bool {
        takeLatest()
        let set = target
        if set[Self.formatEpoch] != current[Self.formatEpoch] {
            // Другая частота: старая история к новым коэффициентам не подходит, и плавно идти не от чего.
            current.update(from: set, count: Self.setSize)
            clearHistory()
            reader[2] = 0
        }
        if channels != reader[1] {
            reader[1] = channels
            clearHistory()
        }
        return reader[2] != 0 || set[Self.limiterShare] != 0
    }

    /// Один шаг сглаживания на кадр.
    @inline(__always) func advance() {
        guard reader[2] != 0 else { return }
        let set = target
        let step = set[Self.smoothStep]
        var i = 0
        while i < Self.smoothed {
            current[i] += (set[i] - current[i]) * step
            i += 1
        }
    }

    /// Один отсчёт канала: предусиление, полосы, ограничитель. Выход всегда в [−1; 1].
    @inline(__always) func process(_ sample: Float, channel: Int) -> Float {
        var x = Double(sample) * current[Self.preamp]
        let memory = history + channel * Self.historyPerChannel
        var band = 0
        while band < Self.bands {
            let c = current + band * Self.stageSize
            let s = memory + band * 4
            var y = c[0] * x + c[1] * s[0] + c[2] * s[1] - c[3] * s[2] - c[4] * s[3]
            if y > -Self.silence && y < Self.silence { y = 0 }
            s[1] = s[0]
            s[0] = x
            s[3] = s[2]
            s[2] = y
            x = y
            band += 1
        }
        // NaN, бесконечность и огромные значения со входа прошли все полосы и лежат в истории: стираем, на выходе тишина.
        if !(x > -1e6 && x < 1e6) {
            memset(memory, 0, Self.historyPerChannel * MemoryLayout<Double>.size)
            return 0
        }
        let limited = Self.softLimit(x)
        var out = x + (limited - x) * current[Self.limiterShare]
        if out > 1 { out = 1 } else if out < -1 { out = -1 }
        return Float(out)
    }

    /// Конец буфера: переход дошёл до цели — фиксируем её, ровная цель отключает эквалайзер до следующей смены.
    func end() {
        guard reader[2] != 0 else { return }
        let set = target
        var i = 0
        while i < Self.smoothed {
            let gap = set[i] - current[i]
            if gap > Self.settled || gap < -Self.settled { return }
            i += 1
        }
        current.update(from: set, count: Self.setSize)
        reader[2] = 0
        if set[Self.limiterShare] == 0 { clearHistory() }
    }

    private func clearHistory() {
        memset(history, 0, Self.historySize * MemoryLayout<Double>.size)
    }

    /// Ниже порога без изменений, выше плавно к единице: наклон на пороге 1, щелчка нет.
    @inline(__always) private static func softLimit(_ x: Double) -> Double {
        let size = x < 0 ? -x : x
        guard size > limiterKnee else { return x }
        let over = (size - limiterKnee) / (1 - limiterKnee)
        let limited = limiterKnee + (1 - limiterKnee) * over / (1 + over)
        return x < 0 ? -limited : limited
    }
}
