import Foundation
import Combine

final class LockState: ObservableObject {
    static let shared = LockState()

    private static let key = SoundShared.bluetoothLockedKey

    @Published var isLocked: Bool {
        didSet { Kit.defaults.set(isLocked, forKey: Self.key) }
    }

    var isUnlocked: Bool { !isLocked }

    private init() {
        isLocked = SoundShared.storedBluetoothLocked()
    }

    /// Пока модуль вёл другой процесс, настройка менялась там.
    func reload() {
        let new = SoundShared.storedBluetoothLocked()
        if new != isLocked { isLocked = new }
    }
}
