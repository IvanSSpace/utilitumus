import AppKit
import Combine
import Foundation

/// Модель вкладки «Студия», когда модуль ведёт утилита. Сервер, токен и папка у утилиты; у центра только состояние
/// с адресом входа: токена здесь нет и получить его нечем.
@MainActor
final class RemoteStudioModel: RemoteModuleModel<StudioState, StudioAction>, StudioModel {
    private let handoff: StudioBrowserHandoff
    private var sub: AnyCancellable?

    init(id: String, link: RemoteModuleLink? = nil, canRead: @escaping () -> Bool,
         openExternal: @escaping @MainActor (URL) -> Void = { StudioOpen.inBrowser($0) }) {
        handoff = StudioBrowserHandoff(open: openExternal)
        // До первого ответа — сохранённая папка: домен настроек у центра и утилиты один.
        super.init(id: id, initial: StudioState.stored(), link: link, canRead: canRead,
                   optimistic: { state, action in
                       // Сервером и кодом распоряжается утилита: показываем её ответ. Папка видна сразу, отказ откатит.
                       if case .setFolder(let path) = action, let folder = StudioPath.validated(path) { state.folder = folder }
                   })
        sub = $state.sink { [weak self] state in self?.handoff.observe(state) }
    }

    var browserLogin: Int { handoff.claimed }

    func setFolder(_ path: String) { send(.setFolder(path)) }
    func newLogin() { send(.newLogin) }

    func openInBrowser() {
        handoff.request(after: state.login)
        send(.newLogin)
    }
}
