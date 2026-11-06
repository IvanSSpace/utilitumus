import Combine

/// Всё, что экран «Голос» берёт у своей модели. Работает ли модуль здесь же или в утилите, экран не знает.
/// Имя `VoiceModel` занято: так называются модели распознавания.
@MainActor
protocol VoiceScreenModel: ObservableObject, HotKeyTarget {
    associatedtype StatusChanges: Publisher where StatusChanges.Failure == Never

    var hotKeyLabel: String { get }
    var hotKeyError: String? { get }
    var mode: VoiceController.Mode { get set }
    var micUID: String? { get set }
    var excludedApps: [String] { get }
    var axTrusted: Bool { get }
    func addExcluded(_ bundleID: String)
    func removeExcluded(_ bundleID: String)
    func refreshPermissions()
    func requestAccessibility()

    var selected: VoiceModel { get set }
    /// Срабатывает при каждой смене статусов моделей и сразу при подписке.
    var statusChanges: StatusChanges { get }
    func status(_ model: VoiceModel) -> VoiceModelStore.Status
    func download(_ model: VoiceModel)
    func cancel(_ model: VoiceModel)
    func delete(_ model: VoiceModel)

    /// Режим проверки (решение Q6): у встроенного экрана его нет, текст он вставляет в поле сам.
    var test: VoiceTestState? { get }
    func beginTest()
    func endTest()
}

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
    func endTest() {}
}

extension VoiceView where Model == VoiceLocalModel {
    init() { self.init(voice: .shared) }
}
