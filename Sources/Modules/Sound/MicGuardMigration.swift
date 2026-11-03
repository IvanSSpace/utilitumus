import Foundation

/// Однократный перенос настроек из отдельного MicGuard.app (bundle id
/// `local.micguard`): ключи те же, меняется только домен UserDefaults.
/// Копируем только отсутствующие ключи — повторный запуск ничего не перетрёт.
/// Звать до первого обращения к LockState/PriorityStore/DeviceEnableStore:
/// они читают UserDefaults в init.
enum MicGuardMigration {
    private static let keys = [
        "MicGuardBluetoothLocked",
        "MicGuardDisabledDeviceUIDs",
        "MicGuardKnownDevicesOrder",
    ]

    static func run() {
        guard let old = UserDefaults(suiteName: "local.micguard") else { return }
        let current = UserDefaults.standard
        for key in keys where current.object(forKey: key) == nil {
            if let value = old.object(forKey: key) {
                current.set(value, forKey: key)
            }
        }
    }
}
