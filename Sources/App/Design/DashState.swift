import Foundation

// Состояние карточки дашборда и вопрос перед её действием. Отдельный файл: от них зависят и модели утилит,
// и реестр, а сам дашборд тянет за собой весь центр.

/// Что показать у модуля: строка статуса и название быстрого действия. Сравнивается целиком,
/// поэтому неизменный статус никого не перерисовывает. Само действие — `DashboardLive.perform`.
struct DashState: Equatable {
    var on = true
    var text = ""
    /// Нужно внимание (нет доступа, не хватает модели): строка оранжевая.
    var attention = false
    var actionTitle: String?
    var actionIcon: String?
    /// Действие из статуса утилиты: кнопка карточки шлёт его обратно утилите.
    var quick: LinkQuickAction?
}

/// Вопрос перед действием карточки: «Закрыть N программ?». Текст приходит от того, кто знает, что закрывается.
struct DashConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    let run: @MainActor () -> Void
}
