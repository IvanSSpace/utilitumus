import Foundation

/// Имена и версия протокола связи центра и утилиты.
enum KitLink {
    static let protocolVersion = 1

    static func bundleID(_ id: String) -> String { "\(Kit.hubBundleID).app.\(id)" }
    static func machService(_ id: String) -> String { bundleID(id) + ".xpc" }
    static func statusChanged(_ id: String) -> Notification.Name { Notification.Name(bundleID(id) + ".statusChanged") }

    /// Требование к собеседнику: точный identifier и любой из доверенных листовых сертификатов.
    /// Строка одна, потому что на соединение есть только один вызов setCodeSigningRequirement.
    static func requirement(identifier: String, hashes: [String] = KitSigning.trustedLeafHashes) -> String {
        hashes.map { "(" + KitSigning.requirement(identifier: identifier, leafHash: $0) + ")" }.joined(separator: " or ")
    }

    /// Любой из собеседников: утилита принимает центр и свою же копию, запущенную из Finder.
    static func requirement(identifiers: [String], hashes: [String] = KitSigning.trustedLeafHashes) -> String {
        identifiers.map { requirement(identifier: $0, hashes: hashes) }.joined(separator: " or ")
    }

    /// «Перечитай мой статус». Уведомление никем не проверяется, поэтому без данных:
    /// получатель читает статус по проверенному XPC.
    static func postStatusChanged(_ id: String) {
        DistributedNotificationCenter.default().post(name: statusChanged(id), object: nil)
    }
}

struct LinkHello: Codable, Equatable {
    let id: String
    let version: String
    let protocolVersion: Int
}

struct LinkStatus: Codable, Equatable {
    let enabled: Bool
    let line: String
    let needsSetup: Int

    init(enabled: Bool, line: String, needsSetup: Int) {
        self.enabled = enabled
        self.line = String(line.prefix(80))
        self.needsSetup = needsSetup
    }

    /// Через init выше: длинную строку обрезает и получатель, сколько бы ни прислали.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decode(Bool.self, forKey: .enabled),
            line: try container.decode(String.self, forKey: .line),
            needsSetup: try container.decode(Int.self, forKey: .needsSetup))
    }
}

/// Весь протокол: ничего другого утилита не примет. Имя в ObjC задано явно, чтобы не зависеть
/// от имени модуля: у центра и утилит оно разное.
@objc(LinkXPC) protocol LinkXPC {
    func hello(reply: @escaping @Sendable (Data) -> Void)
    func status(reply: @escaping @Sendable (Data) -> Void)
    func setEnabled(_ enabled: Bool, reply: @escaping @Sendable () -> Void)
    func openWindow(reply: @escaping @Sendable () -> Void)
    func quit(reply: @escaping @Sendable () -> Void)
}

/// Что утилита отвечает центру. Вызывается на главном потоке.
@MainActor protocol LinkHandler: AnyObject {
    func linkHello() -> LinkHello
    func linkStatus() -> LinkStatus
    func linkSetEnabled(_ enabled: Bool)
    func linkOpenWindow()
    func linkQuit()
}
