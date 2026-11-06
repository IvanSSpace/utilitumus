import Combine
import SwiftUI

/// Модуль внутри своей утилиты. Всё остальное делает `SatelliteHost`. `init` ничего не запускает: копия из Finder
/// создаёт модуль, просит настоящую показать окно и выходит. Работа идёт только между `start` и остановкой.
/// Главный поток не занимать: центр ждёт ответа 2 с, и зависшая утилита для него не отвечает.
@MainActor protocol SatelliteModule: AnyObject {
    /// Заголовок, значок и фон окна.
    var module: Module { get }
    /// Имя на связи, из него `LinkIdentity` выводит id и метку. По умолчанию имя модуля.
    var linkName: String { get }

    /// Утилита активна и включена: начать работу. Настройки читать заново, пока модуль стоял, их мог менять центр.
    func start()
    /// Выключили. Повторный вызов безвреден. Снимает всё, что модуль держит.
    func stop()
    /// Модуль ведёт центр. По умолчанию `stop()`: иначе рядом окажутся два писателя и два обработчика событий.
    /// Переопределять только там, где работа со встроенным модулем не столкнётся.
    func enterPassive()
    /// Выход ради обновления или выхода из системы, и прямо перед заменой бандла при самообновлении. Системные настройки
    /// пользователя остаются: следующая версия их ждёт. Самообновление сорвалось — снова `start()`. По умолчанию `stop()`.
    func stopForUpdate()
    /// Утилиту удаляют: снять и системные настройки. По умолчанию `stop()`.
    func stopForUninstall()

    /// Строка статуса. Только то, что не меняется на каждое событие: о смене статуса уходит уведомление,
    /// видное всем на этом Mac. Диктовка и копирование через него читаться не должны.
    func statusLine(passiveReason: String?) -> String
    var attention: Bool { get }
    var quickActions: [LinkQuickAction] { get }
    var setupSteps: [LinkSetupStep] { get }
    /// Шаг уже проверен: id есть в `setupSteps`. Текст ошибки или nil. Системный запрос показывать без ожидания.
    func performSetupStep(_ id: String) -> String?

    /// То, что показывает экран. `LinkWire.encoded(...)`.
    func state() -> Data
    /// `LinkWire.handle(...)`: проверка, действие, ответ.
    func handle(_ action: Data) -> Data
    /// Состояние изменилось. Хост сам склеивает и сообщает.
    var changes: AnyPublisher<Void, Never> { get }
    /// Экран модуля открыт в центре или в своём окне. Приходит только между `start` и остановкой.
    func screenOpen(_ open: Bool)

    /// Экран для своего окна, когда центра нет.
    func windowRoot() -> AnyView
    var windowSize: CGSize { get }
    /// Можно ли сейчас перезапустить процесс ради обновления.
    var mayRestart: Bool { get }

    #if KIT_TEST_DEFAULTS
    /// Стенд: команда сигналом USR1, окна и значка на экране нет.
    func standCommand()
    #endif
}

extension SatelliteModule {
    var linkName: String { module.rawValue }
    func enterPassive() { stop() }
    func stopForUpdate() { stop() }
    func stopForUninstall() { stop() }
    var attention: Bool { false }
    var quickActions: [LinkQuickAction] { [] }
    var setupSteps: [LinkSetupStep] { [] }
    func performSetupStep(_ id: String) -> String? { nil }
    func screenOpen(_ open: Bool) {}
    var windowSize: CGSize { CGSize(width: 480, height: 520) }
    var mayRestart: Bool { true }
    #if KIT_TEST_DEFAULTS
    func standCommand() {}
    #endif
}
