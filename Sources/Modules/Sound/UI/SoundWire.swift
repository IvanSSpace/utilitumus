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
