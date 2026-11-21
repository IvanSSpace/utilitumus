import Foundation

/// Модель вкладки «Студия», когда модуль ведёт утилита. Сервер, токен, код входа и папка у утилиты; у центра только снимок
/// состояния: ни токена, ни кода, который на него меняется, здесь нет.
@MainActor
final class RemoteStudioModel: RemoteModuleModel<StudioState, StudioAction>, StudioModel {
    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool) {
        // До первого ответа — сохранённая папка: домен настроек у центра и утилиты один.
        super.init(id: id, initial: StudioState.stored(), link: link, canRead: canRead,
                   optimistic: { state, action in
                       // Сервером и кодом распоряжается утилита: показываем её ответ. Папка видна сразу, отказ откатит.
                       switch action {
                       case .setFolder(let path):
                           if let folder = StudioPath.validated(path) { state.folder = folder }
                       case .select(let id):
                           // Выбранная утилита видна сразу; дело подгрузит утилита.
                           state.board?.selected = id
                           if state.board?.detail?.id != id { state.board?.detail = nil }
                       case .deselect:
                           state.board?.selected = nil
                           state.board?.detail = nil
                       default: break
                       }
                   })
    }

    func setFolder(_ path: String) { send(.setFolder(path)) }
    func openInBrowser() { send(.openInBrowser) }
}
