import Foundation
import CoreGraphics
import IOKit.hid

/// Сессионный tap на прокрутку со своим потоком. На главном потоке нельзя: пока
/// SwiftUI занят, прокрутка во всей системе вставала бы, и система отключила бы tap.
final class MouseScrollTap: @unchecked Sendable {
    let engine: MouseScrollEngine

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private var timer: CFRunLoopTimer?
    private var hid: IOHIDManager?
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var created = false

    private static let frame = 1.0 / 120
    /// Magic Mouse: производитель Apple, три модели (Lightning, первая, USB-C).
    private static let magicProducts = [0x030D, 0x0269, 0x0323]

    init(engine: MouseScrollEngine) {
        self.engine = engine
    }

    var isRunning: Bool { thread != nil }

    /// Tap жив и включён. Система могла выключить его, если колбэк не успевал.
    var isEnabled: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Создаёт tap и ждёт результата. false — нет доступа «Универсальный доступ».
    func start() -> Bool {
        guard thread == nil else { return true }
        created = false
        let t = Thread { [self] in run() }
        t.name = "Utilitumus.MouseScrollTap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if !created { thread = nil }
        return created
    }

    /// Снимает tap полностью и дожидается, пока поток завершится.
    func stop() {
        guard thread != nil, let rl = runLoop else { return }
        CFRunLoopStop(rl)
        finished.wait()
        thread = nil
    }

    // MARK: Поток tap'а

    private func run() {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MouseScrollTap>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // Система выключила tap: включаем сразу. Если не вышло, контроллер пересоздаст.
                if let port = me.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            case .scrollWheel:
                return me.engine.process(event) ? nil : Unmanaged.passUnretained(event)
            default:
                return Unmanaged.passUnretained(event)
            }
        }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            ready.signal()
            return
        }
        self.port = port
        let rl: CFRunLoop = CFRunLoopGetCurrent()
        runLoop = rl
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(rl, source, .commonModes)

        // Таймер анимации: спит, пока колесо не крутили.
        let timer = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, Self.frame, 0, 0) { [weak self] timer in
            guard let self else { return }
            if !self.engine.tick() { CFRunLoopTimerSetNextFireDate(timer, .greatestFiniteMagnitude) }
        }
        self.timer = timer
        CFRunLoopAddTimer(rl, timer, .commonModes)
        engine.wake = { CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent()) }

        startMagicMouseWatch(on: rl)
        CGEvent.tapEnable(tap: port, enable: true)
        created = true
        ready.signal()

        CFRunLoopRun()

        // Снятие: сначала tap, потом остальное.
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(rl, source, .commonModes)
        CFMachPortInvalidate(port)
        CFRunLoopTimerInvalidate(timer)
        engine.wake = {}
        engine.finish()
        stopMagicMouseWatch()
        self.port = nil
        self.timer = nil
        runLoop = nil
        finished.signal()
    }

    // MARK: Magic Mouse

    /// Magic Mouse в событиях прокрутки неотличима от трекпада, зато в HID видно,
    /// какое устройство только что присылало данные. Читаем только время последнего
    /// отчёта. Если менеджер не открылся (нет прав) или такой мыши нет, жесты считаются трекпадными.
    private func startMagicMouseWatch(on rl: CFRunLoop) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = Self.magicProducts.map { [kIOHIDVendorIDKey: 0x004C, kIOHIDProductIDKey: $0] as CFDictionary }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let me = Unmanaged<MouseScrollTap>.fromOpaque(context).takeUnretainedValue()
            me.engine.lastMagicActivity = me.engine.now()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, rl, CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, rl, CFRunLoopMode.commonModes.rawValue)
            return
        }
        hid = manager
    }

    private func stopMagicMouseWatch() {
        guard let manager = hid, let rl = runLoop else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, rl, CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hid = nil
    }
}
