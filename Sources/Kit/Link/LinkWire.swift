import Foundation

/// Имена на связи. Сборка со швом работает под тестовой меткой launchd и своим id: настоящие имена ей не нужны.
/// Исключение — `KIT_TEST_REAL_ID`: сквозной проверке нужен плист, который пишет настоящий установщик.
enum LinkIdentity {
    static func id(_ module: String) -> String {
        #if KIT_TEST_DEFAULTS && !KIT_TEST_REAL_ID
        "test.\(module)"
        #else
        module
        #endif
    }

    static func label(_ module: String) -> String {
        #if KIT_TEST_DEFAULTS && !KIT_TEST_REAL_ID
        "\(Kit.hubBundleID).test.\(module)"
        #else
        KitLink.bundleID(module)
        #endif
    }
}

/// Ответ на действие: состояние после него и текст, если действие не выполнено.
struct LinkReply<State: Codable>: Codable {
    let state: State
    let error: String?

    init(state: State, error: String? = nil) {
        self.state = state
        self.error = error
    }
}
extension LinkReply: Sendable where State: Sendable {}
extension LinkReply: Equatable where State: Equatable {}

enum LinkWire {
    /// Кодирование для связи. Порядок ключей фиксирован: без `sortedKeys` он меняется от запуска к запуску,
    /// а утилита сравнивает полученное с каноническим кодированием. Не вышло — пустые байты: получатель
    /// увидит ошибку разбора, утилита не упадёт.
    static func encoded(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }

    /// Действие из связи: не длиннее `limit`, разбирается и совпадает со своим каноническим видом.
    /// Сверка ловит то, что разбор не видит: повтор ключа, чужие поля во вложенных значениях.
    static func decodeAction<Action: Codable>(_ type: Action.Type, from data: Data, limit: Int) -> Action? {
        guard data.count <= limit, let action = try? JSONDecoder().decode(Action.self, from: data),
              encoded(action) == data else { return nil }
        return action
    }

    /// Весь `handle` модуля: сначала проверка, изменения только после неё. `perform` возвращает текст отказа или nil.
    /// `limit` — чуть больше самого длинного настоящего действия: длинное и разбирать незачем.
    static func handle<Action: Codable, State: Codable>(
        _ data: Data, as type: Action.Type, limit: Int, state: () -> State, perform: (Action) -> String?
    ) -> Data {
        guard let action = decodeAction(type, from: data, limit: limit) else {
            return encoded(LinkReply(state: state(), error: "Непонятная команда"))
        }
        let error = perform(action)
        return encoded(LinkReply(state: state(), error: error))
    }
}

/// Строгое чтение действия в `init(from:)`. Синтезированное чтение не видит чужих ключей, поэтому
/// `{"toggle":{},"x":1}` проходило бы как `toggle`. Здесь ровно одно действие и ровно его поля,
/// всё остальное — ошибка разбора. Имена как у синтезированного кодирования: его `encode(to:)` остаётся.
struct LinkActionFields {
    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    let name: String
    private let payload: KeyedDecodingContainer<Key>
    private let path: [CodingKey]

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Key.self)
        guard root.allKeys.count == 1, let key = root.allKeys.first else {
            throw Self.refusal(decoder.codingPath)
        }
        name = key.stringValue
        path = decoder.codingPath
        payload = try root.nestedContainer(keyedBy: Key.self, forKey: key)
    }

    private static func refusal(_ path: [CodingKey]) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: path, debugDescription: "Не одно известное действие"))
    }

    func refuse() -> DecodingError { Self.refusal(path) }

    /// Действие без значений.
    func none() throws {
        guard payload.allKeys.isEmpty else { throw refuse() }
    }

    /// Единственное значение без метки: `case set(Int)`.
    func value<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try fields("_0")
        return try payload.decode(T.self, forKey: Key(stringValue: "_0"))
    }

    /// Несколько значений: `case set(app: String, volume: Double)`. Сначала `fields("app", "volume")`, затем `field`.
    func fields(_ names: String...) throws {
        guard Set(payload.allKeys.map(\.stringValue)) == Set(names), payload.allKeys.count == names.count else { throw refuse() }
    }

    func field<T: Decodable>(_ name: String, _ type: T.Type = T.self) throws -> T {
        try payload.decode(T.self, forKey: Key(stringValue: name))
    }
}

/// Первый вызов идёт следующим витком, остальные не чаще раза в `interval`. Последний вызов не теряется:
/// за всплеском всегда идёт ещё один запуск. Следующий виток нужен потому, что `objectWillChange` приходит
/// до записи значения: читать надо после всех полей.
@MainActor final class LinkThrottle {
    private let interval: TimeInterval
    private let action: @MainActor () -> Void
    private var last = -Double.infinity
    private var scheduled = false

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func fire() {
        guard !scheduled else { return }
        scheduled = true
        let wait = max(0, last + interval - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                self.last = ProcessInfo.processInfo.systemUptime
                self.action()
            }
        }
    }
}
