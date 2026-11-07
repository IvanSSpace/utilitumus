import Foundation

extension ClipboardController: ClipboardModel {
    var totalCount: Int { items.count }
    func count(inSpace id: UUID) -> Int { items.filter { $0.spaceID == id }.count }
    var recent: [ClipRecentRow] { ClipRecentRow.rows(from: items) }
}

extension ClipboardView where Model == ClipboardController {
    /// Встроенный модуль.
    init() { self.init(model: .shared) }
}

extension ClipboardController: HotKeyTarget {}

extension ClipboardController {
    /// Записи программ из исключений наружу не идут, даже если попали в историю до включения исключения.
    var wireState: ClipboardState {
        ClipboardState(model: self, recent: ClipRecentRow.wireRows(from: items, hiding: excludedApps))
    }
}
