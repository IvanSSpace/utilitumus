import CoreAudio
import Foundation

/// Аудио-процесс из списка Core Audio (macOS 14.2+).
struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    /// Процесс прямо сейчас выводит звук.
    let isRunningOutput: Bool
}

/// Тонкие обёртки над свойствами Core Audio для микшера.
enum MixerHAL {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? result : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        value(object, selector, default: "" as CFString) as String?
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func processes() -> [AudioProcessInfo] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid: pid_t = value(id, kAudioProcessPropertyPID, default: 0), pid > 0 else { return nil }
            let bundle = string(id, kAudioProcessPropertyBundleID)
            let running: UInt32 = value(id, kAudioProcessPropertyIsRunningOutput, default: 0) ?? 0
            return AudioProcessInfo(objectID: id, pid: pid,
                                    bundleID: (bundle?.isEmpty ?? true) ? nil : bundle,
                                    isRunningOutput: running != 0)
        }
    }

    /// UID текущего устройства вывода по умолчанию (не «системных звуков»:
    /// музыка и видео идут именно на него).
    static func defaultOutputUID() -> String? {
        guard let device: AudioDeviceID = value(AudioObjectID(kAudioObjectSystemObject),
                                                kAudioHardwarePropertyDefaultOutputDevice,
                                                default: kAudioObjectUnknown),
              device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    /// Подписка на изменение свойства системного объекта. Возвращает отписку.
    static func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) -> () -> Void {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(system, &addr, .main, block)
        return { AudioObjectRemovePropertyListenerBlock(system, &addr, .main, block) }
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    /// Приложение, которому принадлежит процесс: звук в браузерах и Electron
    /// играет из вспомогательных процессов, а ползунок нужен один на приложение.
    /// Приватный символ системы (на нём же строится атрибуция TCC); не нашёлся —
    /// процесс считается сам себе приложением.
    static func responsiblePID(for pid: pid_t) -> pid_t {
        let owner = responsibleFn?(pid) ?? 0
        return owner > 0 ? owner : pid
    }
}
