import Foundation

/// Имена и версия протокола связи центра и утилиты.
enum KitLink {
    /// Версия этой сборки.
    static let protocolVersion = 3
    /// Самая старая версия, которую эта сборка ещё понимает. Поля добавляются только необязательными, поэтому
    /// соседние версии говорят друг с другом; для несовместимых изменений есть `minHub` в каталоге.
    static let oldestProtocolVersion = 3

    static func bundleID(_ id: String) -> String { "\(Kit.hubBundleID).app.\(id)" }
    /// Служба центра: единственная, что принимает действия, экраны и выход. Требование — только подпись центра.
    static func machService(_ id: String) -> String { bundleID(id) + ".xpc" }
    /// Служба для копии самой утилиты, запущенной из Finder: умеет только «покажи окно», действий не принимает.
    static func selfService(_ id: String) -> String { bundleID(id) + ".self.xpc" }
    static func statusChanged(_ id: String) -> Notification.Name { Notification.Name(bundleID(id) + ".statusChanged") }

    /// Требование к собеседнику: точный identifier, любой из доверенных листовых сертификатов и метка выпуска.
    /// Строка одна, потому что на соединение есть только один вызов setCodeSigningRequirement.
    static func requirement(identifier: String, hashes: [String] = KitSigning.trustedLeafHashes) -> String {
        hashes.map { "(" + KitSigning.peerRequirement(identifier: identifier, leafHash: $0) + ")" }.joined(separator: " or ")
    }

    /// Любой из собеседников: утилита принимает центр и свою же копию, запущенную из Finder.
    static func requirement(identifiers: [String], hashes: [String] = KitSigning.trustedLeafHashes) -> String {
        identifiers.map { requirement(identifier: $0, hashes: hashes) }.joined(separator: " or ")
    }

    /// «Перечитай мой статус». Уведомление никем не проверяется и видно всем на этом Mac, поэтому без данных:
    /// получатель читает статус по проверенному XPC. Уходит только при смене самого статуса, не на каждое событие.
    static func postStatusChanged(_ id: String) {
        DistributedNotificationCenter.default().post(name: statusChanged(id), object: nil)
    }

    /// Диапазоны версий сторон пересекаются. Старая утилита без поля отвечает только за свою версию.
    static func isCompatible(_ hello: LinkHello) -> Bool {
        let oldest = hello.oldestProtocolVersion ?? hello.protocolVersion
        return oldest <= hello.protocolVersion
            && hello.protocolVersion >= oldestProtocolVersion
            && oldest <= protocolVersion
    }
}

struct LinkHello: Codable, Equatable {
    let id: String
    let version: String
    let protocolVersion: Int
    /// nil — утилита понимает только `protocolVersion`.
    let oldestProtocolVersion: Int?

    init(id: String, version: String, protocolVersion: Int, oldestProtocolVersion: Int? = nil) {
        self.id = id
        self.version = version
        self.protocolVersion = protocolVersion
        self.oldestProtocolVersion = oldestProtocolVersion
    }
}

/// Вопрос перед действием: центр показывает его сам, утилита присылает текст. Нужен тому, что закрывает чужие программы.
struct LinkConfirm: Codable, Equatable, Sendable {
    let title: String
    let message: String
    let button: String

    init(title: String, message: String, button: String) {
        self.title = String(title.prefix(80))
        self.message = String(message.prefix(400))
        self.button = String(button.prefix(40))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decode(String.self, forKey: .title),
            message: try container.decode(String.self, forKey: .message),
            button: try container.decode(String.self, forKey: .button))
    }
}

/// Быстрое действие дашборда и меню. Центр байты не разбирает и шлёт их обратно в `moduleAction`,
/// а утилита проверяет их как любое другое действие. `confirm` — спросить человека до отправки.
struct LinkQuickAction: Codable, Equatable, Sendable {
    let title: String
    let icon: String?
    let action: Data
    let confirm: LinkConfirm?

    init(title: String, icon: String? = nil, action: Data, confirm: LinkConfirm? = nil) {
        self.title = String(title.prefix(40))
        self.icon = icon.map { String($0.prefix(64)) }
        self.action = action
        self.confirm = confirm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decode(String.self, forKey: .title),
            icon: try container.decodeIfPresent(String.self, forKey: .icon),
            action: try container.decode(Data.self, forKey: .action),
            confirm: try container.decodeIfPresent(LinkConfirm.self, forKey: .confirm))
    }
}

/// Шаг настройки: рисует центр, разрешение просит утилита, потому что macOS показывает имя того, кто спросил.
/// Шаг, который пользователю не нужен при его настройках, модуль отдаёт с `required: false`.
struct LinkSetupStep: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case permission, system, recommendation

        /// Вид из будущей версии — как разрешение: главное, что статус не сломается.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .permission
        }
    }

    let id: String
    let title: String
    let why: String
    let icon: String
    let kind: Kind
    let buttonTitle: String?
    let required: Bool
    /// false — заранее не проверить, система спросит сама.
    let verifiable: Bool
    let done: Bool
    let busy: String?
    let error: String?

    init(id: String, title: String, why: String, icon: String, kind: Kind = .permission, buttonTitle: String? = nil,
         required: Bool = true, verifiable: Bool = true, done: Bool, busy: String? = nil, error: String? = nil) {
        self.id = String(id.prefix(64))
        self.title = String(title.prefix(80))
        self.why = String(why.prefix(200))
        self.icon = String(icon.prefix(64))
        self.kind = kind
        self.buttonTitle = buttonTitle.map { String($0.prefix(40)) }
        self.required = required
        self.verifiable = verifiable
        self.done = done
        self.busy = busy.map { String($0.prefix(200)) }
        self.error = error.map { String($0.prefix(200)) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            why: try c.decode(String.self, forKey: .why),
            icon: try c.decode(String.self, forKey: .icon),
            kind: try c.decode(Kind.self, forKey: .kind),
            buttonTitle: try c.decodeIfPresent(String.self, forKey: .buttonTitle),
            required: try c.decode(Bool.self, forKey: .required),
            verifiable: try c.decode(Bool.self, forKey: .verifiable),
            done: try c.decode(Bool.self, forKey: .done),
            busy: try c.decodeIfPresent(String.self, forKey: .busy),
            error: try c.decodeIfPresent(String.self, forKey: .error))
    }
}

struct LinkStatus: Codable, Equatable {
    let enabled: Bool
    let line: String
    let needsSetup: Int
    /// Оранжевое состояние карточки: перегрев, нет ключа и так далее.
    let attention: Bool
    let quickActions: [LinkQuickAction]
    let setupSteps: [LinkSetupStep]

    init(enabled: Bool, line: String, needsSetup: Int, attention: Bool = false,
         quickActions: [LinkQuickAction] = [], setupSteps: [LinkSetupStep] = []) {
        self.enabled = enabled
        self.line = String(line.prefix(80))
        self.needsSetup = needsSetup
        self.attention = attention
        self.quickActions = Array(quickActions.prefix(4))
        self.setupSteps = Array(setupSteps.prefix(16))
    }

    /// Через init выше: длинную строку обрезает и получатель, сколько бы ни прислали.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decode(Bool.self, forKey: .enabled),
            line: try container.decode(String.self, forKey: .line),
            needsSetup: try container.decode(Int.self, forKey: .needsSetup),
            attention: try container.decodeIfPresent(Bool.self, forKey: .attention) ?? false,
            quickActions: try container.decodeIfPresent([LinkQuickAction].self, forKey: .quickActions) ?? [],
            setupSteps: try container.decodeIfPresent([LinkSetupStep].self, forKey: .setupSteps) ?? [])
    }
}

/// Зачем центр держит соединение. Держит только пока оно живо: разрыв равен `.none`.
enum LinkWatch: Int, Sendable {
    case none = 0
    /// Сообщать о смене состояния.
    case changes = 1
    /// То же, и экран модуля открыт (аренда).
    case screen = 2
}

/// Зачем утилиту просят выйти. Обновление не снимает системные настройки пользователя, удаление снимает.
enum LinkQuitReason: Int, Sendable {
    case update = 1
    case uninstall = 2
}

/// Весь протокол: ничего другого утилита не примет. Имя в ObjC задано явно, чтобы не зависеть
/// от имени модуля: у центра и утилит оно разное.
@objc(LinkXPC) protocol LinkXPC {
    func hello(reply: @escaping @Sendable (Data) -> Void)
    func status(reply: @escaping @Sendable (Data) -> Void)
    /// То, что вкладка центра показывает на экране. Для связи это байты: разбирает только код модуля.
    func moduleState(reply: @escaping @Sendable (Data) -> Void)
    /// Действие с вкладки центра. Утилита проверяет его сама и отвечает своим кодом.
    func moduleAction(_ action: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Шаг настройки по его id из статуса. Ответ — `LinkReply<LinkStatus>`.
    func performSetupStep(_ id: String, reply: @escaping @Sendable (Data) -> Void)
    /// `LinkWatch`. Действует, пока живо это соединение.
    func watch(_ level: Int, reply: @escaping @Sendable () -> Void)
    func setEnabled(_ enabled: Bool, reply: @escaping @Sendable () -> Void)
    /// Свой значок модуля в строке меню (`MenuBarIcon`): сразу, без перезапуска. Только служба центра.
    func setMenuIcon(_ on: Bool, reply: @escaping @Sendable () -> Void)
    func openWindow(reply: @escaping @Sendable () -> Void)
    /// `LinkQuitReason`.
    func quit(reason: Int, reply: @escaping @Sendable () -> Void)
}

/// Всё, что умеет служба для копии утилиты (`KitLink.selfService`). Остальных вызовов в её интерфейсе нет.
@objc(LinkSelfXPC) protocol LinkSelfXPC {
    func openWindow(reply: @escaping @Sendable () -> Void)
}

/// Обратное направление того же соединения. Проверенный канал вместо уведомления: о смене состояния
/// узнаёт только тот, кто подписался, и ни одно другое приложение этого не видит.
@objc(LinkPingXPC) protocol LinkPingXPC {
    func stateChanged()
}

/// Что утилита отвечает центру. Вызывается на главном потоке.
@MainActor protocol LinkHandler: AnyObject {
    func linkHello() -> LinkHello
    func linkStatus() -> LinkStatus
    func linkModuleState() -> Data
    func linkModuleAction(_ action: Data) -> Data
    func linkPerformSetupStep(_ id: String) -> Data
    func linkSetEnabled(_ enabled: Bool)
    func linkSetMenuIcon(_ on: Bool)
    func linkOpenWindow()
    func linkQuit(_ reason: LinkQuitReason)
    /// Открыт ли экран хотя бы у одного соединения. Приходит только при смене.
    func linkScreenOpen(_ open: Bool)
    /// Подписчик пропал. Новый должен узнать, что пора перечитать: его собственный канал ещё не поднят.
    func linkWatcherLost()
}

extension LinkHandler {
    /// Утилиты без значка в меню-баре это не касается.
    func linkSetMenuIcon(_ on: Bool) {}
}
