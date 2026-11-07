import Foundation

extension SoundController {
    var wireState: SoundState {
        SoundState(currentInputName: currentInputName, currentInputIsBluetooth: currentInputIsBluetooth,
                   currentOutputName: currentOutputName, displayInputs: displayInputs, displayOutputs: displayOutputs,
                   primaryInputUID: primaryInputUID, outputChoice: outputChoice, isBluetoothLocked: isBluetoothLocked)
    }
}

extension SoundController {
    /// Действие из связи. Самое длинное настоящее — uid устройства, ему хватает 1 КБ.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: SoundAction.self, limit: 1024, state: { wireState }) { handle($0) }
    }
}

/// Встроенный модуль: экран берёт модель этого процесса.
extension SoundView where Model == SoundController {
    init() { self.init(model: .shared) }
}
