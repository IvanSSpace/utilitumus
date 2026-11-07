import Carbon.HIToolbox
import Combine
import Foundation

/// Встроенный модуль: контроллер и хранилище моделей как одна модель экрана.
@MainActor
final class VoiceLocalModel: VoiceScreenModel {
    static let shared = VoiceLocalModel()

    private let controller = VoiceController.shared
    private let store = VoiceModelStore.shared
    /// Экран перерисовывается от обоих объектов, как при двух `@ObservedObject`.
    nonisolated let objectWillChange: Publishers.Merge<ObservableObjectPublisher, ObservableObjectPublisher>

    private init() {
        objectWillChange = controller.objectWillChange.merge(with: store.objectWillChange)
    }

    var hotKeyLabel: String { controller.hotKeyLabel }
    var hotKeyError: String? { controller.hotKeyError }
    var mode: VoiceController.Mode {
        get { controller.mode }
        set { controller.mode = newValue }
    }
    var micUID: String? {
        get { controller.micUID }
        set { controller.micUID = newValue }
    }
    var excludedApps: [String] { controller.excludedApps }
    var axTrusted: Bool { controller.axTrusted }
    func addExcluded(_ bundleID: String) { controller.addExcluded(bundleID) }
    func removeExcluded(_ bundleID: String) { controller.removeExcluded(bundleID) }
    func refreshPermissions() { controller.refreshPermissions() }
    func requestAccessibility() { controller.requestAccessibility() }

    func setHotKey(keyCode: UInt32, modifiers: UInt32) { controller.setHotKey(keyCode: keyCode, modifiers: modifiers) }
    func resetHotKey() { controller.resetHotKey() }
    func suspendHotKey() { controller.suspendHotKey() }
    func resumeHotKey() { controller.resumeHotKey() }

    var selected: VoiceModel {
        get { store.selected }
        set { store.selected = newValue }
    }
    var statusChanges: Published<[VoiceModel: VoiceModelStore.Status]>.Publisher { store.$statuses }
    func status(_ model: VoiceModel) -> VoiceModelStore.Status { store.status(model) }
    func download(_ model: VoiceModel) { store.download(model) }
    func cancel(_ model: VoiceModel) { store.cancel(model) }
    func delete(_ model: VoiceModel) { store.delete(model) }

    var test: VoiceTestState? { nil }
    func beginTest() {}
    /// Ушёл с экрана или убрал фокус: запись, начатая кнопкой, обрывается.
    func endTest() { controller.cancelTestRecording() }
    var recording: Bool { controller.phase == .recording }
    func toggleTestRecording() {
        if let error = controller.toggleTestRecording(intoState: false) { VoiceHUD.shared.showMessage(error, isError: true) }
    }
}

extension VoiceView where Model == VoiceLocalModel {
    init() { self.init(voice: .shared) }
}

extension VoiceController: HotKeyTarget {}

extension VoiceController {
    private static let maxExcluded = 200
    private static let maxFailureText = 300
    private static let knownModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    var wireState: VoiceState {
        let store = VoiceModelStore.shared
        return VoiceState(hotKeyLabel: hotKeyLabel, hotKeyError: hotKeyError, mode: mode, micUID: micUID,
                          excludedApps: excludedApps, axTrusted: axTrusted,
                          models: VoiceModel.allCases.map { VoiceModelRow(model: $0, status: Self.wireStatus(store.status($0))) },
                          selected: store.selected, test: liveTest,
                          recording: phase == .recording)
    }

    /// Прогресс приходит на каждый блок загрузки; на экран хватает целых процентов, тогда и состояние меняется реже.
    static func wireStatus(_ status: VoiceModelStore.Status) -> VoiceModelStore.Status {
        switch status {
        case let .downloading(progress): return .downloading(progress: (progress * 100).rounded(.down) / 100)
        case let .failed(text): return .failed(String(text.prefix(maxFailureText)))
        default: return status
        }
    }

    private static func isBundleID(_ text: String) -> Bool {
        (1...255).contains(text.utf8.count) && text.utf8.allSatisfy {
            switch $0 {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    /// Действие из связи. Самое длинное настоящее (идентификатор программы до 255 байт) короче 512.
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: VoiceAction.self, limit: 512, state: { wireState }) { handle($0) }
    }

    /// Действие от экрана: сначала проверка, изменения только после неё. Возвращает текст отказа.
    func handle(_ action: VoiceAction) -> String? {
        let store = VoiceModelStore.shared
        switch action {
        case let .setMode(value):
            mode = value
        case let .setMic(uid):
            // Выбранный, но сейчас отключённый микрофон выбрать заново можно: так он остаётся в меню экрана.
            if let uid, uid != micUID, !VoiceRecorder.inputDevices().contains(where: { $0.uid == uid }) {
                return "Такого микрофона нет"
            }
            micUID = uid
        case let .addExcluded(id):
            guard Self.isBundleID(id) else { return "Это не идентификатор программы" }
            guard !Kit.isOurs(id) else { return "Utilitumus исключить нельзя" }
            guard excludedApps.contains(id) || excludedApps.count < Self.maxExcluded else { return "Список исключений полон" }
            addExcluded(id)
        case let .removeExcluded(id):
            guard excludedApps.contains(id) else { return "Этой программы нет в списке" }
            removeExcluded(id)
        case let .setHotKey(keyCode, modifiers):
            guard modifiers & ~Self.knownModifiers == 0, VoiceHotKey.isAcceptable(keyCode: keyCode, modifiers: modifiers) else {
                return "Такое сочетание не подходит"
            }
            setHotKey(keyCode: keyCode, modifiers: modifiers)
        case .resetHotKey:
            resetHotKey()
        case .suspendHotKey:
            suspendHotKey()
        case .resumeHotKey:
            resumeHotKey()
        case .refreshPermissions:
            refreshPermissions()
        case .requestAccessibility:
            requestAccessibility()
        case let .download(model):
            switch store.status(model) {
            case .notInstalled, .failed: store.download(model)
            case .installed: return "Модель уже скачана"
            case .downloading, .verifying: return "Модель уже качается"
            }
        case let .cancelDownload(model):
            guard case .downloading = store.status(model) else { return "Загрузка не идёт" }
            store.cancel(model)
        case let .deleteModel(model):
            guard store.status(model) == .installed else { return "Модель не установлена" }
            store.delete(model)
        case let .selectModel(model):
            guard store.status(model) == .installed else { return "Модель не установлена" }
            store.selected = model
        case .beginTest:
            beginTest()
        case .endTest:
            endTest()
        case .toggleTestRecording:
            return toggleTestRecording(intoState: true)
        }
        return nil
    }
}

extension VoiceController {
    /// Проверки берут начальное состояние экрана под этим именем.
    static func storedState() -> VoiceState { VoiceState.stored() }
}
