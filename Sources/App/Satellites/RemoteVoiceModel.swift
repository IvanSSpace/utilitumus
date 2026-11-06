import Combine
import Foundation

/// Модель экрана «Голос», когда модуль ведёт утилита: микрофон, клавишу и модели держит она, у центра ничего этого нет.
/// `.changes`: стору нужен ход загрузки и при закрытом экране.
@MainActor
final class RemoteVoiceModel: RemoteModuleModel<VoiceState, VoiceAction>, VoiceScreenModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        super.init(id: id, initial: VoiceController.storedState(), baseWatch: .changes, link: link, canRead: canRead,
                   optimistic: { state, action in
                       switch action {
                       case .setMode(let mode): state.mode = mode
                       case .setMic(let uid): state.micUID = uid
                       case .addExcluded(let id): if !state.excludedApps.contains(id) { state.excludedApps.append(id) }
                       case .removeExcluded(let id): state.excludedApps.removeAll { $0 == id }
                       case .selectModel(let model): state.selected = model
                       case .setHotKey(let keyCode, let modifiers):
                           state.hotKeyLabel = VoiceHotKey.label(keyCode: keyCode, modifiers: modifiers)
                       case .download(let model):
                           if let i = state.models.firstIndex(where: { $0.model == model }) {
                               state.models[i].status = .downloading(progress: 0)
                           }
                       // Режим виден сразу: быстрый уход из поля иначе не выключил бы его.
                       case .beginTest: state.test = VoiceTestState(phrase: nil, serial: state.test?.serial ?? 0)
                       case .endTest: state.test = nil
                       // Остальное решает утилита: права и отказы.
                       default: break
                       }
                   })
    }

    var hotKeyLabel: String { state.hotKeyLabel }
    var hotKeyError: String? { state.hotKeyError }
    var mode: VoiceController.Mode {
        get { state.mode }
        set { send(.setMode(newValue)) }
    }
    var micUID: String? {
        get { state.micUID }
        set { send(.setMic(newValue)) }
    }
    var excludedApps: [String] { state.excludedApps }
    var axTrusted: Bool { state.axTrusted }
    func addExcluded(_ bundleID: String) { send(.addExcluded(bundleID)) }
    func removeExcluded(_ bundleID: String) { send(.removeExcluded(bundleID)) }
    func refreshPermissions() { send(.refreshPermissions) }
    func requestAccessibility() { send(.requestAccessibility) }

    func setHotKey(keyCode: UInt32, modifiers: UInt32) { send(.setHotKey(keyCode: keyCode, modifiers: modifiers)) }
    func resetHotKey() { send(.resetHotKey) }
    func suspendHotKey() { send(.suspendHotKey) }
    func resumeHotKey() { send(.resumeHotKey) }

    var selected: VoiceModel {
        get { state.selected }
        set { send(.selectModel(newValue)) }
    }
    /// После записи значения, а не до неё, как у `@Published`: экран читает статусы сразу по сигналу.
    var statusChanges: AnyPublisher<[VoiceModelRow], Never> {
        $state.receive(on: DispatchQueue.main).map(\.models).removeDuplicates().eraseToAnyPublisher()
    }
    func status(_ model: VoiceModel) -> VoiceModelStore.Status {
        state.models.first { $0.model == model }?.status ?? .notInstalled
    }
    func download(_ model: VoiceModel) { send(.download(model)) }
    func cancel(_ model: VoiceModel) { send(.cancelDownload(model)) }
    func delete(_ model: VoiceModel) { send(.deleteModel(model)) }

    var test: VoiceTestState? { state.test }
    func beginTest() { send(.beginTest) }
    var recording: Bool { state.recording }
    func toggleTestRecording() { send(.toggleTestRecording) }
    func endTest() {
        // Режим уже выключен и записи нет: лишнее действие не нужно, и утилиту ради него не будят.
        if state.test != nil || state.recording { send(.endTest) }
    }

    // Карточка та же, что у встроенного: «идёт запись…» приходит флагом в состоянии, строка статуса от записи не меняется.
    override func dashboardState(base: DashState, status: LinkStatus?) -> DashState {
        if state.recording { return DashState(text: "идёт запись…") }
        let model = state.selected.title.components(separatedBy: " — ")[0]
        if self.status(state.selected) != .installed {
            return DashState(text: "\(hotKeyLabel) · модель не скачана", attention: true)
        }
        return DashState(text: "\(hotKeyLabel) · \(model)")
    }
}
