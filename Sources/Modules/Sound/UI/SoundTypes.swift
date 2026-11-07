import Foundation

enum Transport: String, Codable, Sendable {
    case builtIn
    case usb
    case bluetooth
    case airplay
    /// HDMI / DisplayPort: динамики монитора или телевизора.
    case display
    case virtual
    case other

    /// Настоящее железо, которое можно выбрать основным. Виртуальные и
    /// неопознанные устройства (Loopback, Zoom, агрегаты) — чужая песочница.
    var isPhysical: Bool { self != .virtual && self != .other }
}

protocol SoundDevice {
    var uid: String { get }
    var transport: Transport { get }
}

/// Выбор основного выхода. `.system` — не вмешиваться, решает macOS.
enum OutputChoice: Codable, Equatable, Sendable {
    case system
    case builtIn
    case device(String)
}

/// Устройство для отображения в UI: может быть сейчас не подключено.
struct DisplayDevice: SoundDevice, Codable, Equatable, Sendable {
    let uid: String
    let name: String
    let transport: Transport
    let isConnected: Bool
}

/// Общее у экрана, модели вкладки и логики модуля.
enum SoundShared {
    // UID встроенных устройств содержат эти слова (BuiltInMicrophoneDevice,
    // BuiltInSpeakerDevice). У встроенного бывает несколько устройств (вход/выход
    // для разъёма наушников), поэтому ищем нужное по слову, а не берём первое.
    static let microphoneMarker = "Microphone"
    static let speakerMarker = "Speaker"

    static func builtIn<D: SoundDevice>(in devices: [D], marker: String) -> D? {
        let builtIns = devices.filter { $0.transport == .builtIn }
        return builtIns.first { $0.uid.contains(marker) } ?? builtIns.first
    }

    // Настройки: хранилища модуля их пишут, а модель вкладки показывает до первого ответа утилиты. Домен настроек один.
    static let primaryInputKey = "UtilitumusPrimaryInput"
    static let primaryOutputKey = "UtilitumusPrimaryOutput"
    static let bluetoothLockedKey = "MicGuardBluetoothLocked"
    static let builtInValue = "builtin"
    static let systemValue = "system"
    static let devicePrefix = "uid:"

    /// `decided` ложно, если выбор ещё ни разу не фиксировался.
    static func storedPrimaryInput() -> (uid: String?, decided: Bool) {
        guard let saved = Kit.defaults.string(forKey: primaryInputKey) else { return (nil, false) }
        return (saved == builtInValue ? nil : saved, true)
    }

    static func storedOutputChoice() -> OutputChoice {
        let saved = Kit.defaults.string(forKey: primaryOutputKey)
        switch saved {
        case systemValue: return .system
        case let value? where value.hasPrefix(devicePrefix):
            return .device(String(value.dropFirst(devicePrefix.count)))
        default: return .builtIn
        }
    }

    /// Значения ещё нет: записывает «под замком».
    static func storedBluetoothLocked() -> Bool {
        if Kit.defaults.object(forKey: bluetoothLockedKey) == nil {
            Kit.defaults.set(true, forKey: bluetoothLockedKey)
        }
        return Kit.defaults.bool(forKey: bluetoothLockedKey)
    }
}
