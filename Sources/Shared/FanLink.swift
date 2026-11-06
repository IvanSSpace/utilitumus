import Foundation

/// Общее для приложения и root-службы вентиляторов. Значения вшиты при сборке: в боевом бинарнике
/// их не подменить ни окружением, ни аргументами, тестовые есть только под `FAN_TEST_FAKE_SMC`.
enum FanLink {
    #if FAN_TEST_FAKE_SMC
    static let label = "local.utilitumus.test.fan"
    static let service = "local.utilitumus.test.fan.xpc"
    static let connectionOptions: NSXPCConnection.Options = []
    static let idleExit: TimeInterval = 2
    #else
    static let label = "local.utilitumus.fan"
    static let service = "local.utilitumus.fan.xpc"
    /// Служба в системном домене: без этой опции поиск идёт в домене пользователя.
    static let connectionOptions: NSXPCConnection.Options = .privileged
    /// Дольше 10 с: иначе launchd придержал бы следующий запуск (ThrottleInterval по умолчанию).
    static let idleExit: TimeInterval = 30
    #endif

    /// Менять при КАЖДОМ изменении поведения службы: по ней приложение решает,
    /// просить ли «Обновить доступ» (пароль). Сборка сама её не трогает.
    /// Только целое число и только вверх: пароль просит клиент новее службы, клиент старше работает с ней как есть.
    static let helperVersion = "4"

    /// Identifier подписи самой службы: один и тот же в боевой и в тестовой сборке.
    private static let serviceIdentifier = "local.utilitumus.fan"
    /// Кому служба отвечает: центр и будущая отдельная утилита вентиляторов.
    private static let clientIdentifiers = ["local.utilitumus", "local.utilitumus.app.fans"]

    static let listenerRequirement = clientIdentifiers.flatMap { identifier in
        KitSigning.trustedLeafHashes.map { "(" + KitSigning.peerRequirement(identifier: identifier, leafHash: $0) + ")" }
    }.joined(separator: " or ")

    /// Что клиент требует от службы. Без метки выпуска: у службы нет бандла, а чужой процесс не зарегистрирует
    /// имя в системном домене без root. Сейчас хэш один: скобки появляются, только когда их несколько.
    static let serviceRequirement: String = {
        let each = KitSigning.trustedLeafHashes.map { KitSigning.requirement(identifier: serviceIdentifier, leafHash: $0) }
        return each.count == 1 ? each[0] : each.map { "(\($0))" }.joined(separator: " or ")
    }()
}

/// `String?` в ответе: текст ошибки, `nil` — успех.
/// Имя для Objective-C задано явно: протокол не должен зависеть от имени модуля.
/// Клиенты обновляются отдельно от службы, поэтому служба принимает всё, что слали клиенты прежних версий: методы
/// только добавляются, с подъёмом `helperVersion`, ни один не убирается и не меняется. Новый метод клиент вызывает
/// только в `.ready`: старой службе он неизвестен. Tests/run-fan-version-check.sh держит список неизменным.
@objc(FanHelperXPC) protocol FanHelperXPC {
    func version(reply: @escaping (String) -> Void)
    func setAuto(_ fan: Int, reply: @escaping (String?) -> Void)
    func setRPM(_ fan: Int, _ rpm: Double, reply: @escaping (String?) -> Void)
}
