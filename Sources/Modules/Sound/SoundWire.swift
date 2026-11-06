import Foundation

/// То, что показывает экран «Звук».
struct SoundState: Codable, Equatable, Sendable {
    var currentInputName: String
    var currentInputIsBluetooth: Bool
    var currentOutputName: String
    var displayInputs: [DisplayDevice]
    var displayOutputs: [DisplayDevice]
    var primaryInputUID: String?
    var outputChoice: OutputChoice
    var isBluetoothLocked: Bool
}

/// Что экран может попросить. Встроенное устройство выбирается своим uid: как его хранить, решает модуль.
enum SoundAction: Codable, Equatable, Sendable {
    case selectInput(String)
    case selectOutput(String)
    case selectSystemOutput
    case setBluetoothLocked(Bool)
}

extension SoundController {
    var wireState: SoundState {
        SoundState(currentInputName: currentInputName, currentInputIsBluetooth: currentInputIsBluetooth,
                   currentOutputName: currentOutputName, displayInputs: displayInputs, displayOutputs: displayOutputs,
                   primaryInputUID: primaryInputUID, outputChoice: outputChoice, isBluetoothLocked: isBluetoothLocked)
    }
}
