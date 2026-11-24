import Foundation

/// UID фактического входа CoreAudio. nil в value означает, что драйвер не даёт менять уровень.
struct SoundInputLevel: Codable, Equatable, Sendable {
    static let range = 0.0...1.0
    let uid: String
    var value: Double?
}

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
    var currentInputLevel: SoundInputLevel? = nil
}

/// Что экран может попросить. Встроенное устройство выбирается своим uid: как его хранить, решает модуль.
enum SoundAction: Codable, Equatable, Sendable {
    case selectInput(String)
    case selectOutput(String)
    case selectSystemOutput
    case setBluetoothLocked(Bool)
    case setInputLevel(uid: String, value: Double)

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
        case "setInputLevel":
            try wire.fields("uid", "value")
            self = .setInputLevel(uid: try wire.field("uid"), value: try wire.field("value"))
        default:
            throw wire.refuse()
        }
    }
}
