import Foundation
import Combine

final class LockState: ObservableObject {
    static let shared = LockState()

    private static let key = "MicGuardBluetoothLocked"

    @Published var isLocked: Bool {
        didSet { Kit.defaults.set(isLocked, forKey: Self.key) }
    }

    var isUnlocked: Bool { !isLocked }

    private init() {
        isLocked = Self.stored()
    }

    private static func stored() -> Bool {
        if Kit.defaults.object(forKey: key) == nil {
            Kit.defaults.set(true, forKey: key)
        }
        return Kit.defaults.bool(forKey: key)
    }

    /// Пока модуль вёл другой процесс, настройка менялась там.
    func reload() {
        let new = Self.stored()
        if new != isLocked { isLocked = new }
    }
}
