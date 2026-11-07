import Foundation

extension ClipboardController: ClipboardModel {
    var totalCount: Int { items.count }
    func count(inSpace id: UUID) -> Int { items.filter { $0.spaceID == id }.count }
    var recent: [ClipRecentRow] { ClipRecentRow.rows(from: ClipConcealment.rowItems(items, spaces: spaces)) }
}

extension ClipboardView where Model == ClipboardController {
    /// Встроенный модуль.
    init() { self.init(model: .shared) }
}

extension ClipboardController: HotKeyTarget {}

extension ClipboardController {
    /// Записи программ из исключений наружу не идут, даже если попали в историю до включения исключения.
    /// Скрытие тоже не уходит: ни содержимое скрытых записей, ни само поле у пространства, договор связи прежний.
    var wireState: ClipboardState {
        var state = ClipboardState(model: self, recent: ClipRecentRow.wireRows(from: ClipConcealment.rowItems(items, spaces: spaces),
                                                                               hiding: excludedApps))
        state.spaces = ClipConcealment.wireSpaces(spaces)
        return state
    }
}
