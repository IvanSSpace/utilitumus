import Foundation

/// Всё, что экран «Звук» берёт у своей модели. Устройства выбираются по uid из списков самой модели.
@MainActor
protocol SoundModel: ObservableObject {
    var currentInputName: String { get }
    var currentInputIsBluetooth: Bool { get }
    var currentOutputName: String { get }
    var displayInputs: [DisplayDevice] { get }
    var displayOutputs: [DisplayDevice] { get }
    /// nil — микрофон MacBook.
    var primaryInputUID: String? { get }
    var outputChoice: OutputChoice { get }
    var isBluetoothLocked: Bool { get set }
    func selectInput(uid: String)
    func selectOutput(uid: String)
    func selectSystemOutput()
}
