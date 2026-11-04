import Foundation
import CoreAudio

final class MonitorState: ObservableObject {
    static let shared = MonitorState()
    @Published var currentInputName: String = "—"
    @Published var currentInputIsBluetooth: Bool = false
    @Published var currentOutputName: String = "—"
    @Published var displayInputs: [DisplayDevice] = []
    @Published var displayOutputs: [DisplayDevice] = []
}

final class AudioMonitor {
    static let shared = AudioMonitor()

    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue(label: "utilitumus.sound.audio-monitor")
    private var refreshTimer: DispatchSourceTimer?

    // Защита от борьбы с системным call-роутингом (см. CorrectionThrottle) —
    // отдельно для входа и выхода, чтобы пауза одного не отключала другой.
    private var inputThrottle = CorrectionThrottle()
    private var outputThrottle = CorrectionThrottle()

    // Слушатели и флаг работы: start/stop зовут с main, а читает флаг `queue`.
    private let stateLock = NSLock()
    private var active = false
    private var listeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    private var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !active else { return }
        active = true

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.enforcePolicyOnQueue()
        }
        for selector in [kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(systemObjectID, &addr, queue, listener)
            listeners.append((addr, listener))
        }

        enforcePolicy()

        // Подстраховка: сразу после холодного старта процесса CoreAudio иногда
        // отдаёт неполный список устройств (особенно USB/Bluetooth) — снапшот
        // на старте может пропустить реально подключённое устройство, а раз
        // больше никаких device-change событий не происходит, обновиться уже
        // нечему. Периодический re-sync сам себя чинит.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.enforcePolicyOnQueue()
        }
        timer.resume()
        refreshTimer = timer
    }

    /// Выключение модуля: снять слушатели и таймер, устройства больше не трогаем.
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard active else { return }
        active = false

        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &listener.address, queue, listener.block)
        }
        listeners = []
        refreshTimer?.cancel()
        refreshTimer = nil
        // Счётчики отката живут на `queue`; после повторного включения паузы быть не должно.
        queue.async { [weak self] in
            self?.inputThrottle = CorrectionThrottle()
            self?.outputThrottle = CorrectionThrottle()
        }
    }

    /// Безопасно вызывать с любого потока (в т.ч. main — например после смены
    /// основного устройства в UI): всегда уходит на фоновую очередь первым делом.
    func enforcePolicy() {
        queue.async { [weak self] in
            self?.enforcePolicyOnQueue()
        }
    }

    // MARK: - Policy (выполняется только на `queue`)

    private func enforcePolicyOnQueue() {
        // Событие могло встать в очередь до stop() — после него устройства не трогаем.
        guard isActive else { return }
        let inputs = allDevices(scope: kAudioObjectPropertyScopeInput)
        let outputs = allDevices(scope: kAudioObjectPropertyScopeOutput)
        let currentInputID = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
        let currentOutputID = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)

        // Хранилища мутируются из SwiftUI на main thread — читаем и публикуем
        // состояние для UI одним синхронным хопом на main, чтобы не гонять
        // @Published свойства между потоками.
        let (bluetoothLocked, primaryUID, outputChoice) = DispatchQueue.main.sync { () -> (Bool, String?, OutputChoice) in
            let state = MonitorState.shared
            let currentInput = inputs.first { $0.id == currentInputID }
            if let currentInput {
                state.currentInputName = currentInput.name
                state.currentInputIsBluetooth = currentInput.transport == .bluetooth
            }
            if let current = outputs.first(where: { $0.id == currentOutputID }) {
                state.currentOutputName = current.name
            }
            let locked = LockState.shared.isLocked
            PrimaryInputStore.shared.migrateIfNeeded(connected: inputs, bluetoothLocked: locked)
            KnownDeviceStore.inputs.sync(from: inputs)
            KnownDeviceStore.outputs.sync(from: outputs)
            state.displayInputs = KnownDeviceStore.inputs.displayList(available: inputs)
            state.displayOutputs = KnownDeviceStore.outputs.displayList(available: outputs)
            return (locked, PrimaryInputStore.shared.primaryUID, PrimaryOutputStore.shared.choice)
        }

        let now = Date()

        // Нет default input вовсе — состояние переходное, не вмешиваемся.
        if let currentInputID,
           let desired = SoundPolicy.desiredInput(devices: inputs, currentID: currentInputID,
                                                  primaryUID: primaryUID, bluetoothLocked: bluetoothLocked),
           inputThrottle.allow(at: now) {
            setDefaultInput(desired.id)
        }

        if let currentOutputID,
           let desired = SoundPolicy.desiredOutput(devices: outputs, currentID: currentOutputID, choice: outputChoice),
           outputThrottle.allow(at: now) {
            setDefaultOutput(desired.id)
        }
    }

    // MARK: - CoreAudio helpers

    private func address(_ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func setDefault(_ selector: AudioObjectPropertySelector, _ deviceID: AudioDeviceID) {
        var addr = address(selector)
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(systemObjectID, &addr, 0, nil, size, &id)
    }

    private func setDefaultInput(_ deviceID: AudioDeviceID) {
        setDefault(kAudioHardwarePropertyDefaultInputDevice, deviceID)
    }

    /// Системный выход (звуки уведомлений) переключаем вместе с основным,
    /// как это делает сама macOS, иначе сигналы уйдут на «случайное» устройство.
    private func setDefaultOutput(_ deviceID: AudioDeviceID) {
        setDefault(kAudioHardwarePropertyDefaultOutputDevice, deviceID)
        setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, deviceID)
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &size, &ids)
        return ids
    }

    private func deviceName(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return "Unknown" }
        return cfName as String
    }

    /// Персистентный ключ устройства (переживает переподключение), в отличие
    /// от AudioDeviceID, который выдаётся заново при каждом коннекте — по нему хранятся
    /// основное устройство и список известных. Номер USB-порта из UID выкинут (см. DeviceIdentity).
    /// nil — у устройства нет UID: запомнить его всё равно не по чему.
    private func deviceUID(_ id: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid)
        guard status == noErr, let cfUID = uid?.takeRetainedValue() else { return nil }
        return DeviceIdentity.stableKey(cfUID as String)
    }

    private func transportType(_ id: AudioDeviceID) -> Transport {
        var addr = address(kAudioDevicePropertyTransportType)
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &raw) == noErr else { return .other }
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeAirPlay:
            return .airplay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .display
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return .virtual
        default:
            return .other
        }
    }

    private func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private func allDevices(scope: AudioObjectPropertyScope) -> [AudioDeviceInfo] {
        allDeviceIDs()
            .filter { hasStreams($0, scope: scope) }
            .compactMap { id in
                deviceUID(id).map { AudioDeviceInfo(id: id, uid: $0, name: deviceName(id), transport: transportType(id)) }
            }
    }
}
