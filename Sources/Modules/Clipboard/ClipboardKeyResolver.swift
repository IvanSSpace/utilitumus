import Foundation
import CryptoKit
import Security

/// Порядок утилиты с ключом. Новый ключ создаётся только когда обеих записей нет и индекса тоже нет.
/// Любая другая ошибка Связки останавливает работу и ничего не меняет.
struct ClipboardKeyResolver: Sendable {
    let keyring: ClipboardKeyring
    let directory: URL

    func resolve() -> ClipboardKeyOutcome {
        switch keyring.read(.own) {
        case .found(let data):
            guard data.count == 32 else { return .failed(.badItem) }
            switch ClipboardStore.indexCheck(directory: directory, key: SymmetricKey(data: data)) {
            case .noIndex, .readable: return .ready(data)
            case .unreadable: return .failed(.keyDoesNotOpenIndex)
            case .unknown: return .failed(.indexUnknown)
            }
        case .failure(let status):
            return .failed(.keychain(status))
        case .absent:
            switch keyring.probe(.legacy) {
            case .exists: return .needsHandover
            case .failure(let status): return .failed(.keychain(status))
            case .absent: return createFirstKey()
            }
        }
    }

    /// Первый запуск: ни одной записи и нет индекса.
    private func createFirstKey() -> ClipboardKeyOutcome {
        switch ClipboardStore.indexCheck(directory: directory, key: SymmetricKey(size: .bits256)) {
        case .noIndex: break
        case .unreadable, .readable: return .failed(.indexWithoutKey)
        case .unknown: return .failed(.indexUnknown)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let random = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard random == errSecSuccess else { return .failed(.randomFailed(random)) }
        let status = keyring.add(.own, key: Data(bytes))
        guard status == errSecSuccess else { return .failed(.keychain(status)) }
        return resolve()
    }

    /// Ключ, присланный центром. Своей записи он не получает, пока не открыл индекс; после записи ответ даёт
    /// обычный `resolve()`, то есть повторное чтение из Связки и повторная проверка индекса. nil — принят,
    /// иначе причина. Вызывать только когда `resolve()` вернул `needsHandover`.
    func accept(_ key: Data) -> ClipboardKeyFailure? {
        guard key.count == 32 else { return .handoverRejected }
        switch ClipboardStore.indexCheck(directory: directory, key: SymmetricKey(data: key)) {
        case .noIndex, .readable: break
        case .unreadable: return .handoverRejected
        case .unknown: return .indexUnknown
        }
        let status = keyring.add(.own, key: key)
        guard status == errSecSuccess else { return .keychain(status) }
        guard keyring.read(.own) == .found(key) else {
            // Запись, которая не читается обратно, не оставляем: следующий запуск начнёт передачу заново.
            _ = keyring.delete(.own)
            return .badItem
        }
        return nil
    }
}

extension ClipboardKeyResolver {
    /// Утилита отдаёт старому центру свой ключ перед удалением. Отдаёт только тот, что открывает историю (или истории нет):
    /// чужой ключ центр у себя не поселит. Записи не меняются. Своей записи нет — отдавать нечего.
    func keyToReturn() -> ClipboardKeyReturnReply {
        switch keyring.read(.own) {
        case .absent: return ClipboardKeyReturnReply(key: nil, error: nil)
        case .failure(let status): return ClipboardKeyReturnReply(key: nil, error: ClipboardKeyFailure.keychain(status).message)
        case .found(let data):
            guard data.count == 32 else { return ClipboardKeyReturnReply(key: nil, error: ClipboardKeyFailure.badItem.message) }
            switch ClipboardStore.indexCheck(directory: directory, key: SymmetricKey(data: data)) {
            case .noIndex, .readable: return ClipboardKeyReturnReply(key: data, error: nil)
            case .unreadable: return ClipboardKeyReturnReply(key: nil, error: ClipboardKeyFailure.keyDoesNotOpenIndex.message)
            case .unknown: return ClipboardKeyReturnReply(key: nil, error: ClipboardKeyFailure.indexUnknown.message)
            }
        }
    }

    /// Центр подтвердил, что ключ лежит у него: своя запись больше не нужна. Без прежней записи в связке
    /// не удаляет: иначе ключ остался бы нигде. nil — удалена (или её не было).
    func dropOwn() -> String? {
        switch keyring.probe(.legacy) {
        case .exists: break
        case .absent: return "Ключа нет в записи Utilitumus: запись утилиты не удалена"
        case .failure(let status): return ClipboardKeyFailure.keychain(status).message
        }
        let status = keyring.delete(.own)
        return status == errSecSuccess || status == errSecItemNotFound ? nil : ClipboardKeyFailure.keychain(status).message
    }
}

/// Просьбы старого центра перед удалением утилиты: отдать ключ обратно и потом удалить свою запись. Нынешний центр
/// их не шлёт: запись утилиты переживает удаление, и новая установка находит её сама. Не действия экрана,
/// принимает их только соединение центра (`LinkCaller.isHub`).
enum ClipboardKeyReturnMessage: Codable, Equatable {
    case returnKey
    case dropKey

    static let limit = 64

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "returnKey": try wire.none(); self = .returnKey
        case "dropKey": try wire.none(); self = .dropKey
        default: throw wire.refuse()
        }
    }

    func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Name.self)
        switch self {
        case .returnKey: _ = outer.nestedContainer(keyedBy: Field.self, forKey: .returnKey)
        case .dropKey: _ = outer.nestedContainer(keyedBy: Field.self, forKey: .dropKey)
        }
    }

    private enum Name: String, CodingKey { case returnKey, dropKey }
    private enum Field: String, CodingKey { case none }
}

/// Ответ утилиты. `key` — только на `returnKey` и только когда есть что отдавать; `error` — причина отказа.
struct ClipboardKeyReturnReply: Codable, Equatable {
    let key: Data?
    let error: String?
}

#if KIT_TEST_DEFAULTS
/// Одни и те же выдуманные записи для утилиты и для встроенного экрана стенда: снимки сравниваются по пикселям.
enum ClipboardStandFixture {
    static func seed(_ store: ClipboardStore) {
        let work = store.addSpace(name: "Работа", colorID: "teal")
        store.addSpace(name: "Дом", colorID: "pink")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = ["первая строка", "https://example.com/page", "третья строка с длинным текстом для обрезки в колонке экрана", "четвёртая", "пятая", "шестая"]
        for (index, text) in rows.enumerated() {
            let snap = ClipSnapshot(types: ["public.utf8-plain-text"], text: text, sourceBundleID: "com.apple.Safari", sourceName: "Safari")
            store.ingest(snap, now: base.addingTimeInterval(Double(index)))
        }
        if let first = store.items.last { store.pin(first.id, to: work.id) }
    }
}
#endif
