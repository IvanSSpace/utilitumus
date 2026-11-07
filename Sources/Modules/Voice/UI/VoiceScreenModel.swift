import Combine

/// Всё, что экран «Голос» берёт у своей модели. Работает ли модуль здесь же или в утилите, экран не знает.
/// Имя `VoiceModel` занято: так называются модели распознавания.
@MainActor
protocol VoiceScreenModel: ObservableObject, HotKeyTarget {
    associatedtype StatusChanges: Publisher where StatusChanges.Failure == Never

    var hotKeyLabel: String { get }
    var hotKeyError: String? { get }
    var mode: VoiceMode { get set }
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
    func status(_ model: VoiceModel) -> VoiceModelStatus
    func download(_ model: VoiceModel)
    func cancel(_ model: VoiceModel)
    func delete(_ model: VoiceModel)

    /// Режим проверки (решение Q6): у встроенного экрана его нет, текст он вставляет в поле сам.
    var test: VoiceTestState? { get }
    func beginTest()
    func endTest()
    /// Идёт ли запись: кнопка «Проверить» тогда останавливает её.
    var recording: Bool { get }
    /// Кнопка «Проверить»: начать запись или закончить. Отказ показывает сам модуль.
    func toggleTestRecording()
}
