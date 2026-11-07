import Foundation

// Чистая логика модуля «Мышь»: без CGEvent и системных вызовов, чтобы её
// можно было проверить на подставных данных.

// MARK: Откуда пришло событие

/// Признаки события прокрутки, по которым отличают устройства.
struct ScrollTraits: Equatable {
    var isContinuous: Bool
    var scrollPhase: Int64
    var momentumPhase: Int64

    /// Значения полей CGEvent (`CGScrollPhase` и `CGMomentumScrollPhase`).
    static let phaseBegan: Int64 = 1
    static let phaseCancelled: Int64 = 8
    static let phaseMayBegin: Int64 = 128
    static let momentumEnd: Int64 = 3

    /// У колеса фаз не бывает вовсе, у трекпада и Magic Mouse они есть всегда:
    /// жест начинается, идёт и заканчивается, потом инерция.
    var hasPhase: Bool { scrollPhase != 0 || momentumPhase != 0 }
}

enum ScrollDevice: Equatable {
    case wheelMouse, magicMouse, trackpad
}

/// Колесо отличаем по отсутствию фаз. Трекпад и Magic Mouse одинаково «непрерывные»
/// и с фазами, их различает только привязка жеста к устройству: кто первым
/// шевельнулся по данным HID в начале жеста, тому принадлежит и инерция после него.
struct ScrollSourceTracker {
    private var magicOwnsGesture: Bool?

    mutating func device(for t: ScrollTraits, magicActive: Bool) -> ScrollDevice {
        guard t.hasPhase else { return .wheelMouse }
        if t.scrollPhase == ScrollTraits.phaseBegan || t.scrollPhase == ScrollTraits.phaseMayBegin {
            magicOwnsGesture = magicActive
        }
        let magic = magicOwnsGesture ?? magicActive
        if t.momentumPhase == ScrollTraits.momentumEnd || t.scrollPhase == ScrollTraits.phaseCancelled {
            magicOwnsGesture = nil
        }
        return magic ? .magicMouse : .trackpad
    }
}

// MARK: Плавность

/// Превращает щелчки колеса в плавную прокрутку: остаток пути проходит через два
/// последовательных экспоненциальных сглаживания. Одного хватило бы для «доезда»,
/// но вторая ступень даёт мягкий разгон, а не рывок на первом кадре. Сумма выданных
/// пикселей равна сумме поданных: ничего не теряется и не добавляется.
struct SmoothScroller {
    enum Phase: Equatable { case began, changed, ended }
    struct Step: Equatable {
        var dx: Int
        var dy: Int
        var phase: Phase
    }

    /// Пикселей за один щелчок колеса при скорости 1×.
    static let pixelsPerLine = 36.0
    /// Больше накопленного пути не держим: безумный разгон колеса не должен крутить минуту.
    static let maxPending = 20000.0

    /// Постоянная времени каждой из двух ступеней. Полный доезд — около 4,5 таких.
    static func tau(smoothness: Double) -> Double { 0.03 + 0.14 * min(max(smoothness, 0), 1) }

    private var pending = SIMD2<Double>.zero
    private var buffer = SIMD2<Double>.zero
    /// Дробная часть, которую нельзя отдать целыми пикселями прямо сейчас.
    private var carry = SIMD2<Double>.zero
    private var started = false
    private var finishing = false
    private(set) var isActive = false

    /// Добавить путь в пикселях (x — горизонталь, y — вертикаль).
    mutating func add(_ delta: SIMD2<Double>) {
        for i in 0..<2 where delta[i] != 0 {
            // Колесо крутнули в обратную сторону: остаток старого движения гасим,
            // иначе страница сначала доедет туда, куда уже не нужно.
            if (pending[i] + buffer[i]) * delta[i] < 0 {
                pending[i] = 0
                buffer[i] = 0
                carry[i] = 0
            }
            pending[i] = min(max(pending[i] + delta[i], -Self.maxPending), Self.maxPending)
        }
        isActive = true
        finishing = false
    }

    /// Один кадр анимации. nil — в этом кадре событие слать не нужно.
    mutating func step(dt: Double, tau: Double) -> Step? {
        guard isActive else { return nil }
        // Длинный простой (сон потока) не должен выплеснуть всё одним скачком.
        let k = 1 - exp(-min(max(dt, 0), 0.05) / tau)
        let moved = pending * k
        pending -= moved
        buffer += moved
        let out = buffer * k
        buffer -= out
        carry += out

        var whole = carry.rounded(.towardZero)
        carry -= whole

        if !finishing {
            // Дробный остаток в carry в расчёт не берём: он сам по себе не убывает.
            let rest = pointwiseMax(pending, -pending) + pointwiseMax(buffer, -buffer)
            if rest.x < 0.5 && rest.y < 0.5 {
                // Хвост короче пикселя: докатываем сразу, чтобы не тянуть его вечно.
                whole += (pending + buffer + carry).rounded(.toNearestOrAwayFromZero)
                pending = .zero
                buffer = .zero
                carry = .zero
                finishing = true
            }
        }

        if finishing && whole == .zero {
            let wasStarted = started
            reset()
            return wasStarted ? Step(dx: 0, dy: 0, phase: .ended) : nil
        }
        if whole == .zero { return nil }
        let phase: Phase = started ? .changed : .began
        started = true
        return Step(dx: Int(whole.x), dy: Int(whole.y), phase: phase)
    }

    /// Остановить анимацию. Если жест уже начат, возвращает завершающий шаг.
    mutating func cancel() -> Step? {
        let wasStarted = started
        reset()
        return wasStarted ? Step(dx: 0, dy: 0, phase: .ended) : nil
    }

    private mutating func reset() {
        pending = .zero
        buffer = .zero
        carry = .zero
        started = false
        finishing = false
        isActive = false
    }
}
