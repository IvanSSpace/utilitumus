import Foundation

/// Всё, что экран «Буфер» берёт у своей модели. Самих записей здесь нет намеренно: экрану хватает
/// счётчиков и пяти обрезанных строк, а история из модуля не выходит.
@MainActor
protocol ClipboardModel: ObservableObject, HotKeyTarget {
    var totalCount: Int { get }
    /// Записи без пространства.
    var historyCount: Int { get }
    var spaces: [ClipSpace] { get }
    func count(inSpace id: UUID) -> Int
    var recent: [ClipRecentRow] { get }
    var hotKeyLabel: String { get }
    var hotKeyError: String? { get }
    var storeError: String? { get }
    var storeNotice: String? { get }
    var limit: Int { get }
    var excludedApps: [String] { get }
    var axTrusted: Bool { get }

    func togglePanel()
    func refreshPermissions()
    func requestAccessibility()
    func clearHistory()
    func setLimit(_ value: Int)
    func addSpace(name: String, colorID: String)
    func renameSpace(_ id: UUID, to name: String)
    func setColor(_ id: UUID, _ colorID: String)
    func moveSpace(_ id: UUID, by offset: Int)
    func deleteSpace(_ id: UUID)
    func addExcluded(_ bundleID: String)
    func removeExcluded(_ bundleID: String)
}

extension ClipboardController: ClipboardModel {
    var totalCount: Int { items.count }
    func count(inSpace id: UUID) -> Int { items.filter { $0.spaceID == id }.count }
    var recent: [ClipRecentRow] { ClipRecentRow.rows(from: items) }
}
