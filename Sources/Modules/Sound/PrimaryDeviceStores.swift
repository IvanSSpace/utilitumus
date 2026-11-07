import Foundation

/// Основной микрофон. nil — встроенный микрофон MacBook (значение по умолчанию).
/// Мутировать только с main thread.
final class PrimaryInputStore: ObservableObject {
    static let shared = PrimaryInputStore()

    private static let key = SoundShared.primaryInputKey
    private static let builtInValue = SoundShared.builtInValue
    // Ключи старого приоритета (MicGuard), из них считается миграция.
    private static let legacyDisabledKey = "MicGuardDisabledDeviceUIDs"

    @Published private(set) var primaryUID: String?
    /// false — выбор ещё ни разу не фиксировался (первый запуск после обновления
    /// или новая установка): на первом проходе монитора его решит migrateIfNeeded.
    private var isDecided: Bool

    private init() {
        (primaryUID, isDecided) = SoundShared.storedPrimaryInput()
    }

    /// Пока модуль вёл другой процесс, выбор менялся там.
    func reload() {
        let (uid, decided) = SoundShared.storedPrimaryInput()
        if uid != primaryUID { primaryUID = uid }
        isDecided = decided
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

    private static let key = SoundShared.primaryOutputKey
    private static let systemValue = SoundShared.systemValue
    private static let builtInValue = SoundShared.builtInValue
    private static let devicePrefix = SoundShared.devicePrefix

    @Published private(set) var choice: OutputChoice

    private init() {
        choice = SoundShared.storedOutputChoice()
    }

    /// Пока модуль вёл другой процесс, выбор менялся там.
    func reload() {
        let new = SoundShared.storedOutputChoice()
        if new != choice { choice = new }
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
