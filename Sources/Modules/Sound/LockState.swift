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
        if Kit.defaults.object(forKey: Self.key) == nil {
            Kit.defaults.set(true, forKey: Self.key)
        }
        isLocked = Kit.defaults.bool(forKey: Self.key)
    }
}
