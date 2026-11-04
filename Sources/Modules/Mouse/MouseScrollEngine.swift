import Foundation
import CoreGraphics
import QuartzCore
import os

/// Обработка событий прокрутки: направление для мыши и плавность. Вся работа
/// идёт на одном потоке tap'а (колбэк и таймер анимации), поэтому состояние без
/// блокировок; снаружи меняются только настройки.
final class MouseScrollEngine: @unchecked Sendable {
    /// Метка на своих событиях: свой tap их узнаёт и не обрабатывает второй раз.
    static let marker: Int64 = 0x55544C4D

    private let settingsBox = OSAllocatedUnfairLock(initialState: MouseSettings())
    private var scroller = SmoothScroller()
    private var tracker = ScrollSourceTracker()
    private var lastTick = 0.0
    private let source = CGEventSource(stateID: .privateState)

    /// Когда Magic Mouse в последний раз присылала данные (секунды `now`). Пишет поток tap'а.
    var lastMagicActivity = -Double.infinity
    /// Окно «Magic Mouse только что шевелилась», в которое считаем жест её жестом.
    static let magicWindow = 0.4

    /// Куда отправлять готовые события; в проверках подменяется.
    var post: (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    var now: () -> Double = { CACurrentMediaTime() }
    /// Разбудить таймер анимации (он спит, пока крутить нечего).
    var wake: () -> Void = {}

    var settings: MouseSettings {
        get { settingsBox.withLock { $0 } }
        set { settingsBox.withLock { $0 = newValue } }
    }

    var isAnimating: Bool { scroller.isActive }

    /// Признаки события, по которым определяется устройство.
    static func traits(of e: CGEvent) -> ScrollTraits {
        ScrollTraits(isContinuous: e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                     scrollPhase: e.getIntegerValueField(.scrollWheelEventScrollPhase),
                     momentumPhase: e.getIntegerValueField(.scrollWheelEventMomentumPhase))
    }

    /// true — событие поглощено (вместо него пойдёт анимация), false — отдать дальше
    /// системе, возможно изменённым. Колбэк tap'а: без выделений памяти.
    func process(_ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
        let s = settings
        let t = Self.traits(of: e)
        let t0 = now()
        switch tracker.device(for: t, magicActive: t0 - lastMagicActivity < Self.magicWindow) {
        case .trackpad:
            return false
        case .magicMouse:
            // Magic Mouse «непрерывная»: плавность ей не нужна, только направление.
            if s.magicMouseDirection == .reversed { Self.invert(e) }
            return false
        case .wheelMouse:
            // Cmd/Ctrl/Opt/Shift меняют смысл прокрутки (масштаб, горизонталь): не лезем,
            // только направление.
            let modified = !e.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
            // Непрерывное колесо без фаз (драйвер мыши со своей плавностью) уже плавное.
            if s.smoothEnabled && !modified && !t.isContinuous {
                let sign = s.mouseDirection.sign * SmoothScroller.pixelsPerLine * s.speed
                let dy = Self.lines(e, fixed: .scrollWheelEventFixedPtDeltaAxis1, line: .scrollWheelEventDeltaAxis1)
                let dx = Self.lines(e, fixed: .scrollWheelEventFixedPtDeltaAxis2, line: .scrollWheelEventDeltaAxis2)
                guard dx != 0 || dy != 0 else { return false }
                let wasActive = scroller.isActive
                scroller.add(SIMD2(dx, dy) * sign)
                if !wasActive {
                    lastTick = t0
                    wake()
                }
                return true
            }
            if s.mouseDirection == .reversed { Self.invert(e) }
            return false
        }
    }

    /// Кадр анимации. Возвращает, нужен ли следующий.
    func tick() -> Bool {
        let t = now()
        let dt = t - lastTick
        lastTick = t
        let tau = SmoothScroller.tau(smoothness: settings.smoothness)
        if let step = scroller.step(dt: dt, tau: tau) { emit(step) }
        return scroller.isActive
    }

    /// Выключение: оборвать анимацию, закрыв жест, чтобы приложение не ждало его конца.
    func finish() {
        if let step = scroller.cancel() { emit(step) }
    }

    // MARK: События

    private static func lines(_ e: CGEvent, fixed: CGEventField, line: CGEventField) -> Double {
        // Дробное значение есть у колёс высокого разрешения: целое у них может быть 0.
        let f = e.getDoubleValueField(fixed)
        return f != 0 ? f : Double(e.getIntegerValueField(line))
    }

    /// Меняет знак у всех полей с направлением: приложения читают разные. Порядок
    /// важен: запись строчной дельты пересчитывает дробную и точечную, поэтому
    /// сначала читаем всё, потом пишем от строчных к точечным.
    static func invert(_ e: CGEvent) {
        let d1 = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let d2 = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let d3 = e.getIntegerValueField(.scrollWheelEventDeltaAxis3)
        let f1 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let f2 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let f3 = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3)
        let p1 = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let p2 = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let p3 = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis3)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -d1)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -d2)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: -d3)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -f1)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -f2)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3, value: -f3)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -p1)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -p2)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: -p3)
    }

    private func emit(_ step: SmoothScroller.Step) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(step.dy), wheel2: Int32(step.dx), wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Приложения с тачпадной логикой ждут начало и конец жеста.
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.cgPhase(step.phase))
        // Событие прокрутки идёт в окно под курсором, а у нового события координаты нулевые.
        if let location = CGEvent(source: nil)?.location { e.location = location }
        post(e)
    }

    private static func cgPhase(_ p: SmoothScroller.Phase) -> Int64 {
        switch p {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        }
    }
}
