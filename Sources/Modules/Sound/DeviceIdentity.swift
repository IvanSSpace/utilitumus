import Foundation

/// Стабильный ключ устройства для приоритета, галочек и цвета.
///
/// UID USB-аудио у CoreAudio — `AppleUSBAudioEngine:<производитель>:<модель>:<locationID>:<интерфейс>`,
/// где locationID — номер USB-порта/хаба. У микрофонов без серийника (fifine и т.п.)
/// тот же микрофон в другом порту получал новый UID и копился в списке дублем
/// внизу, а ранг и галочка оставались у старой записи. Порт из ключа выкидываем.
/// Цена: два одинаковых микрофона одной модели, подключённые одновременно,
/// считаются одним устройством.
enum DeviceIdentity {
    static func stableKey(_ uid: String) -> String {
        guard uid.hasPrefix("AppleUSBAudioEngine:") else { return uid }
        var parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5, !parts[parts.count - 2].isEmpty,
              parts[parts.count - 2].allSatisfy(\.isHexDigit) else { return uid }
        parts.remove(at: parts.count - 2)
        return parts.joined(separator: ":")
    }

    /// Записи вида `id-537` — фолбэк старых версий для устройств без UID:
    /// AudioDeviceID меняется при каждом появлении, так что каждая такая запись —
    /// мусор, который больше никогда не совпадёт с живым устройством.
    static func isVolatile(_ key: String) -> Bool {
        key.hasPrefix("id-") && key.dropFirst(3).allSatisfy(\.isNumber)
    }
}
