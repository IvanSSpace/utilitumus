import Foundation

/// Основной микрофон. nil — встроенный микрофон MacBook (значение по умолчанию).
/// Мутировать только с main thread.
final class PrimaryInputStore: ObservableObject {
    static let shared = PrimaryInputStore()

    private static let key = "UtilitumusPrimaryInput"
    private static let builtInValue = "builtin"
    // Ключи старого приоритета (MicGuard), из них считается миграция.
    private static let legacyDisabledKey = "MicGuardDisabledDeviceUIDs"

    @Published private(set) var primaryUID: String?
    /// false — выбор ещё ни разу не фиксировался (первый запуск после обновления
    /// или новая установка): на первом проходе монитора его решит migrateIfNeeded.
    private var isDecided: Bool

    private init() {
        if let saved = Kit.defaults.string(forKey: Self.key) {
            primaryUID = saved == Self.builtInValue ? nil : saved
            isDecided = true
        } else {
            primaryUID = nil
            isDecided = false
        }
    }

    func select(_ uid: String?) {
        primaryUID = uid
        isDecided = true
        Kit.defaults.set(uid ?? Self.builtInValue, forKey: Self.key)
    }

    /// Звать ДО KnownDeviceStore.inputs.sync: пока список не дополнен живыми
    /// устройствами, непустой список значит «старые настройки были».
    func migrateIfNeeded(connected: [AudioDeviceInfo], bluetoothLocked: Bool) {
        guard !isDecided else { return }
        let oldOrder = KnownDeviceStore.inputs.known.map(\.uid)
        let disabled = Set((Kit.defaults.stringArray(forKey: Self.legacyDisabledKey) ?? [])
            .map(DeviceIdentity.stableKey))
        select(SoundPolicy.migratedPrimaryInput(oldOrder: oldOrder,
                                                connected: connected,
                                                disabled: disabled,
                                                bluetoothLocked: bluetoothLocked))
    }
}

/// Основной выход. По умолчанию (и для новых установок) — динамики MacBook.
/// Мутировать только с main thread.
final class PrimaryOutputStore: ObservableObject {
    static let shared = PrimaryOutputStore()

    private static let key = "UtilitumusPrimaryOutput"
    private static let systemValue = "system"
    private static let builtInValue = "builtin"
    private static let devicePrefix = "uid:"

    @Published private(set) var choice: OutputChoice

    private init() {
        let saved = Kit.defaults.string(forKey: Self.key)
        switch saved {
        case Self.systemValue: choice = .system
        case let value? where value.hasPrefix(Self.devicePrefix):
            choice = .device(String(value.dropFirst(Self.devicePrefix.count)))
        default: choice = .builtIn
        }
    }

    func select(_ choice: OutputChoice) {
        self.choice = choice
        let value: String
        switch choice {
        case .system: value = Self.systemValue
        case .builtIn: value = Self.builtInValue
        case .device(let uid): value = Self.devicePrefix + uid
        }
        Kit.defaults.set(value, forKey: Self.key)
    }
}
