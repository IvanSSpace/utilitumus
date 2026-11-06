import Foundation
import Security

/// Кто сейчас вызывает модуль по связи. Слушатель принимает центр и копию самой утилиты (она просит
/// показать окно), но действие вроде передачи ключа должно идти только от центра. Значение живёт на главном
/// потоке ровно на время одного вызова `moduleAction`.
@MainActor enum LinkCaller {
    static private(set) var isHub = false

    static func run<T>(fromHub: Bool, _ body: () -> T) -> T {
        isHub = fromHub
        defer { isHub = false }
        return body()
    }

    /// Процесс соединения подписан как центр. Соединение уже прошло требование слушателя, поэтому здесь
    /// различаются только допустимые собеседники между собой.
    nonisolated static func peerIsHub(pid: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: Int(pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(KitLink.requirement(identifier: Kit.hubBundleID) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
