import Foundation

/// Модель вкладки «Боты», когда модуль ведёт утилита. Команд и путей у центра нет: он шлёт id бота, кнопку и id плана,
/// который утилита сама показала. Замеры идут, пока открыта вкладка (аренда экрана ведёт `RemoteModulePage`).
/// Карточка и меню строятся из статуса утилиты: счёт и быстрые действия.
@MainActor
final class RemoteBotsModel: RemoteModuleModel<BotsState, BotsAction>, BotsModel {
    init(id: String, canRead: @escaping () -> Bool, link: RemoteModuleLink? = nil) {
        super.init(id: id, initial: .empty, link: link, canRead: canRead,
                   optimistic: { state, action in
                       // Закрыть окно подтверждения и баннер можно сразу; остальное показывается по ответу утилиты.
                       switch action {
                       case .cancel: state.prompt = nil
                       case .dismissNotice: state.notice = nil
                       default: break
                       }
                   })
    }

    func screenAppeared() {}
    func screenDisappeared() {}
    func request(_ bot: BotCard, _ verb: BotVerb) { send(.request(id: bot.id, verb: verb)) }
    func cancel() { send(.cancel) }
    func confirm(_ planID: UUID) { send(.confirm(planID: planID)) }
    func dismissNotice() { send(.dismissNotice) }
    func refreshNow() { send(.refresh) }
}
