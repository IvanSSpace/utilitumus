import Foundation

/// Модель вкладки «Звук», когда модуль ведёт утилита. Устройствами по умолчанию управляет она, у центра монитора нет.
@MainActor
final class RemoteSoundModel: RemoteModuleModel<SoundState, SoundAction>, SoundModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        // До первого ответа — сохранённые настройки: домен настроек у центра и утилиты один. Списка устройств пока нет.
        super.init(id: id,
                   initial: SoundState(currentInputName: "—", currentInputIsBluetooth: false, currentOutputName: "—",
                                       displayInputs: [], displayOutputs: [],
                                       primaryInputUID: SoundShared.storedPrimaryInput().uid,
                                       outputChoice: SoundShared.storedOutputChoice(),
                                       isBluetoothLocked: SoundShared.storedBluetoothLocked()),
                   dashboardWatch: .changes, link: link, canRead: canRead,
                   // Выбор виден сразу, как у встроенного. Отказ утилиты (нет устройства, Bluetooth под замком) откатит его.
                   optimistic: { state, action in
                       switch action {
                       case .selectInput(let uid):
                           let physical = state.displayInputs.filter { $0.transport.isPhysical }
                           guard let device = physical.first(where: { $0.uid == uid }),
                                 !(device.transport == .bluetooth && state.isBluetoothLocked) else { return }
                           let builtIn = SoundShared.builtIn(in: physical, marker: SoundShared.microphoneMarker)
                           state.primaryInputUID = uid == builtIn?.uid ? nil : uid
                       case .selectOutput(let uid):
                           let physical = state.displayOutputs.filter { $0.transport.isPhysical }
                           guard physical.contains(where: { $0.uid == uid }) else { return }
                           let builtIn = SoundShared.builtIn(in: physical, marker: SoundShared.speakerMarker)
                           state.outputChoice = uid == builtIn?.uid ? .builtIn : .device(uid)
                       case .selectSystemOutput:
                           state.outputChoice = .system
                       case .setBluetoothLocked(let locked):
                           state.isBluetoothLocked = locked
                       }
                   })
    }

    var currentInputName: String { state.currentInputName }
    var currentInputIsBluetooth: Bool { state.currentInputIsBluetooth }
    var currentOutputName: String { state.currentOutputName }
    var displayInputs: [DisplayDevice] { state.displayInputs }
    var displayOutputs: [DisplayDevice] { state.displayOutputs }
    var primaryInputUID: String? { state.primaryInputUID }
    var outputChoice: OutputChoice { state.outputChoice }
    var isBluetoothLocked: Bool {
        get { state.isBluetoothLocked }
        set { send(.setBluetoothLocked(newValue)) }
    }

    func selectInput(uid: String) { send(.selectInput(uid)) }
    func selectOutput(uid: String) { send(.selectOutput(uid)) }
    func selectSystemOutput() { send(.selectSystemOutput) }

    // Карточка та же, что у встроенного: имя микрофона берётся из состояния, оно меняется со сменой устройства.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        DashState(text: currentInputName == "—" ? "слежу за микрофоном" : currentInputName)
    }
}
