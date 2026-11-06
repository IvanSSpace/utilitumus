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

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "selectInput":
            self = .selectInput(try wire.value())
        case "selectOutput":
            self = .selectOutput(try wire.value())
        case "selectSystemOutput":
            try wire.none()
            self = .selectSystemOutput
        case "setBluetoothLocked":
            self = .setBluetoothLocked(try wire.value())
        default:
            throw wire.refuse()
        }
    }
}

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
