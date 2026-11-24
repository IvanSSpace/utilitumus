import Combine
import Foundation

/// Монитор, блокировка и два выбора как одна модель экрана. Создание ничего не запускает: работу ведёт `AudioMonitor`.
@MainActor
final class SoundController: SoundModel {
    static let shared = SoundController()

    private let monitor = MonitorState.shared
    private let lock = LockState.shared
    private let input = PrimaryInputStore.shared
    private let output = PrimaryOutputStore.shared
    private let enforcePolicy: () -> Void
    private let writeInputLevel: (String, Double, Bool) -> Double?
    private var forward: AnyCancellable?

    init(enforcePolicy: @escaping () -> Void = { AudioMonitor.shared.enforcePolicy() },
         writeInputLevel: @escaping (String, Double, Bool) -> Double? = {
             AudioMonitor.shared.setInputLevel(uid: $0, value: $1, bluetoothLocked: $2)
         }) {
        self.enforcePolicy = enforcePolicy
        self.writeInputLevel = writeInputLevel
        forward = Publishers.MergeMany(monitor.objectWillChange, lock.objectWillChange,
                                       input.objectWillChange, output.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    var currentInputName: String { monitor.currentInputName }
    var currentInputIsBluetooth: Bool { monitor.currentInputIsBluetooth }
    var currentInputLevel: SoundInputLevel? { monitor.currentInputLevel }
    var currentOutputName: String { monitor.currentOutputName }
    var displayInputs: [DisplayDevice] { monitor.displayInputs }
    var displayOutputs: [DisplayDevice] { monitor.displayOutputs }
    var primaryInputUID: String? { input.primaryUID }
    var outputChoice: OutputChoice { output.choice }

    var isBluetoothLocked: Bool {
        get { lock.isLocked }
        set { _ = handle(.setBluetoothLocked(newValue)) }
    }

    func selectInput(uid: String) { _ = handle(.selectInput(uid)) }
    func selectOutput(uid: String) { _ = handle(.selectOutput(uid)) }
    func selectSystemOutput() { _ = handle(.selectSystemOutput) }
    func setInputLevel(uid: String, value: Double) { _ = handle(.setInputLevel(uid: uid, value: value)) }

    /// Текст отказа или nil. Сначала проверка, изменения только после неё. Выбрать можно то же, что на экране:
    /// физическое устройство из своего списка, подключённое или нет; заблокированный Bluetooth-микрофон нельзя.
    func handle(_ action: SoundAction) -> String? {
        switch action {
        case .selectInput(let uid):
            let physical = displayInputs.filter { $0.transport.isPhysical }
            guard let device = physical.first(where: { $0.uid == uid }) else { return "Такого микрофона нет" }
            if device.transport == .bluetooth && lock.isLocked { return "Bluetooth-микрофон заблокирован" }
            let builtIn = SoundPolicy.builtIn(in: physical, marker: SoundPolicy.microphoneMarker)
            input.select(uid == builtIn?.uid ? nil : uid)
        case .selectOutput(let uid):
            let physical = displayOutputs.filter { $0.transport.isPhysical }
            guard physical.contains(where: { $0.uid == uid }) else { return "Такого выхода нет" }
            let builtIn = SoundPolicy.builtIn(in: physical, marker: SoundPolicy.speakerMarker)
            output.select(uid == builtIn?.uid ? .builtIn : .device(uid))
        case .selectSystemOutput:
            output.select(.system)
        case .setBluetoothLocked(let locked):
            lock.isLocked = locked
        case .setInputLevel(let uid, let value):
            guard SoundInputLevel.range.contains(value) else { return "Допустимая громкость микрофона: 0–100%" }
            guard let current = currentInputLevel, current.uid == uid else { return "Активный микрофон сменился" }
            guard current.value != nil, !(currentInputIsBluetooth && lock.isLocked) else {
                return "Громкость этого микрофона недоступна"
            }
            guard let applied = writeInputLevel(uid, value, lock.isLocked) else {
                return "Не удалось изменить громкость микрофона"
            }
            if applied != current.value { monitor.currentInputLevel = SoundInputLevel(uid: uid, value: applied) }
            return nil
        }
        enforcePolicy()
        return nil
    }
}
