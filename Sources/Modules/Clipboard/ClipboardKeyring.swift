import Foundation
import CryptoKit
import Security

/// Две записи Связки ключей. Прежняя создана центром, своя принадлежит утилите «Буфер».
/// Утилита свою читает всегда, прежнюю только проверяет на наличие; удалить прежнюю может один центр.
enum ClipboardKeyItem: CaseIterable {
    case legacy
    case own

    var service: String {
        switch self {
        case .legacy: return "local.utilitumus.clipboard"
        case .own: return "local.utilitumus.app.clipboard"
        }
    }

    static let account = "history-key"
}

/// Чтение с данными. `absent` — только настоящее `errSecItemNotFound`: всё остальное, включая отказ и запертую
/// связку, — `failure`, и новый ключ из него появиться не может.
enum ClipboardKeyRead: Equatable {
    case found(Data)
    case absent
    case failure(OSStatus)
}

/// Проверка наличия без секрета: запись есть, нет, или связка ответила иначе.
enum ClipboardKeyProbe: Equatable {
    case exists
    case absent
    case failure(OSStatus)
}

/// Всё, что код Буфера просит у Связки ключей. Настоящая реализация одна; проверки подставляют память.
/// Вызовы блокирующие и могут показать системный запрос: только не с главного потока.
protocol ClipboardKeyring: Sendable {
    func read(_ item: ClipboardKeyItem) -> ClipboardKeyRead
    /// Только атрибуты: запроса пароля не вызывает, секрета не отдаёт.
    func probe(_ item: ClipboardKeyItem) -> ClipboardKeyProbe
    func add(_ item: ClipboardKeyItem, key: Data) -> OSStatus
    func delete(_ item: ClipboardKeyItem) -> OSStatus
}

/// Настоящая связка. Проверки её не создают: их проверяет `run-clipboard-key-check.sh`.
struct SystemClipboardKeyring: ClipboardKeyring {
    private func base(_ item: ClipboardKeyItem) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service,
         kSecAttrAccount as String: ClipboardKeyItem.account]
    }

    func read(_ item: ClipboardKeyItem) -> ClipboardKeyRead {
        let query = base(item).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            guard let data = out as? Data else { return .failure(errSecDecode) }
            return .found(data)
        case errSecItemNotFound: return .absent
        case let status: return .failure(status)
        }
    }

    func probe(_ item: ClipboardKeyItem) -> ClipboardKeyProbe {
        let query = base(item).merging([kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return .exists
        case errSecItemNotFound: return .absent
        case let status: return .failure(status)
        }
    }

    func add(_ item: ClipboardKeyItem, key: Data) -> OSStatus {
        // Только на этом Mac и только пока он разблокирован: в iCloud-связку ключ не уходит.
        let query = base(item).merging([kSecValueData as String: key,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
        return SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ item: ClipboardKeyItem) -> OSStatus {
        SecItemDelete(base(item) as CFDictionary)
    }
}

/// Результат разбора ключа утилиты.
enum ClipboardKeyOutcome: Equatable {
    /// Ключ прочитан из своей записи и открыл индекс (или индекса ещё нет). Дальше процесса он не идёт:
    /// ни в состояние, ни в статус, ни в журнал.
    case ready(Data)
    /// Своей записи нет, прежняя есть: ключ должен передать центр.
    case needsHandover
    case failed(ClipboardKeyFailure)
}

enum ClipboardKeyFailure: Equatable {
    case keychain(OSStatus)
    /// Индекс истории есть, а ключа нигде нет: новый ключ сделал бы историю нечитаемой.
    case indexWithoutKey
    /// Ключ есть, но индекс им не открывается. Индекс не трогаем.
    case keyDoesNotOpenIndex
    case indexUnknown
    case badItem
    /// Ключ, присланный центром, не подошёл. Ничего не записано.
    case handoverRejected
    case randomFailed(OSStatus)

    var message: String {
        switch self {
        case .keychain(let status):
            return "Связка ключей не отдала ключ (код \(status)): история не ведётся, старая не тронута"
        case .indexWithoutKey:
            return "История есть, а её ключ не найден: история не ведётся, файл не тронут"
        case .keyDoesNotOpenIndex:
            return "Ключ не открывает файл истории: история не ведётся, файл не тронут"
        case .indexUnknown:
            return "Не удалось проверить файл истории: история не ведётся, файл не тронут"
        case .badItem:
            return "Запись ключа в Связке ключей повреждена: история не ведётся, файл не тронут"
        case .handoverRejected:
            return "Ключ из Utilitumus не подошёл к истории: история не ведётся, файл не тронут"
        case .randomFailed:
            return "Не удалось создать ключ: история не ведётся"
        }
    }
}

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

/// Сообщение центра утилите. Отдельный тип, не `ClipboardAction`: экран его породить не может.
/// Принимает его только соединение центра (`LinkCaller.isHub`).
struct ClipboardKeyMessage: Codable, Equatable {
    let key: Data

    static let limit = 256

    init(key: Data) { self.key = key }

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        guard wire.name == "handoverKey" else { throw wire.refuse() }
        try wire.fields("key")
        key = try wire.field("key", Data.self)
    }

    func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Name.self)
        var inner = outer.nestedContainer(keyedBy: Field.self, forKey: .handoverKey)
        try inner.encode(key, forKey: .key)
    }

    private enum Name: String, CodingKey { case handoverKey }
    private enum Field: String, CodingKey { case key }
}

/// Ответ утилиты на сообщение. Принято ли к проверке; готовность видна в состоянии (`keyState`).
struct ClipboardKeyReply: Codable, Equatable {
    let received: Bool
}

/// Что утилита говорит о ключе в состоянии. Только слово, не данные.
enum ClipboardKeyState: String, Codable {
    case ready, waiting, failed
}

/// Сторона центра. Читает прежнюю запись (системный запрос не на главном потоке), передаёт ключ один раз,
/// ждёт, пока утилита сама прочитает свою запись и откроет ею историю, и только тогда удаляет прежнюю.
struct ClipboardKeyHandover: Sendable {
    enum Result: Equatable {
        case done
        /// Прежней записи уже нет: передавать нечего.
        case nothingToHand
        case failed(String)
    }

    let keyring: ClipboardKeyring
    /// Отправить байты утилите и вернуть ответ.
    let send: @Sendable (Data) async throws -> Data
    /// Прочитать состояние утилиты.
    let readKeyState: @Sendable () async throws -> ClipboardKeyState?
    var attempts = 20
    var pause: Duration = .milliseconds(500)

    func run() async -> Result {
        let keyring = keyring
        let read = await Task.detached { keyring.read(.legacy) }.value
        let key: Data
        switch read {
        case .absent: return .nothingToHand
        case .failure(let status): return .failed("Связка ключей не отдала прежний ключ (код \(status))")
        case .found(let data):
            guard data.count == 32 else { return .failed("Прежний ключ неверной длины") }
            key = data
        }
        do {
            let answer = try await send(LinkWire.encoded(ClipboardKeyMessage(key: key)))
            guard (try? JSONDecoder().decode(ClipboardKeyReply.self, from: answer))?.received == true else {
                return .failed("Утилита не приняла ключ")
            }
            for _ in 0..<attempts {
                switch try await readKeyState() {
                case .ready:
                    let status = await Task.detached { keyring.delete(.legacy) }.value
                    guard status == errSecSuccess || status == errSecItemNotFound else {
                        return .failed("Прежняя запись не удалена (код \(status))")
                    }
                    return .done
                case .failed: return .failed("Утилита отвергла ключ")
                case .waiting, .none: try await Task.sleep(for: pause)
                }
            }
            return .failed("Утилита не подтвердила ключ")
        } catch {
            return .failed("Утилита не ответила")
        }
    }
}

#if KIT_TEST_DEFAULTS
/// Связка стенда: в памяти, настоящая не нужна. `Test.ClipboardLegacyKey` (base64) кладёт прежнюю запись.
final class MemoryClipboardKeyring: ClipboardKeyring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardKeyItem: Data] = [:]

    static func forStand() -> MemoryClipboardKeyring {
        let ring = MemoryClipboardKeyring()
        if let text = Kit.defaults.string(forKey: "Test.ClipboardLegacyKey"), let key = Data(base64Encoded: text) {
            ring.items[.legacy] = key
        }
        return ring
    }

    func read(_ item: ClipboardKeyItem) -> ClipboardKeyRead {
        lock.withLock { items[item].map(ClipboardKeyRead.found) ?? .absent }
    }

    func probe(_ item: ClipboardKeyItem) -> ClipboardKeyProbe {
        lock.withLock { items[item] == nil ? .absent : .exists }
    }

    func add(_ item: ClipboardKeyItem, key: Data) -> OSStatus {
        lock.withLock {
            guard items[item] == nil else { return errSecDuplicateItem }
            items[item] = key
            return errSecSuccess
        }
    }

    func delete(_ item: ClipboardKeyItem) -> OSStatus {
        lock.withLock { items.removeValue(forKey: item) == nil ? errSecItemNotFound : errSecSuccess }
    }
}

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
