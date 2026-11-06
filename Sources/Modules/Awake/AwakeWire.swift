import Foundation

/// Сборка со швом работает под тестовой меткой launchd и своим id: настоящие имена ей не нужны.
/// Исключение — `KIT_TEST_REAL_ID`: сквозной проверке нужен плист, который пишет настоящий установщик.
enum AwakeIdentity {
    #if KIT_TEST_DEFAULTS && !KIT_TEST_REAL_ID
    static let id = "test.awake"
    static let label = "local.utilitumus.test.awake"
    #else
    static let id = Module.awake.rawValue
    static let label = KitLink.bundleID(id)
    #endif
}

/// То, что вкладка центра показывает на экране.
struct AwakeState: Codable, Equatable {
    var isActive: Bool
    var endDate: Date?
    var keepDisplay: Bool
    var duration: AwakeDuration
    var canStart: Bool
}

/// Что вкладка центра может попросить. Больше утилита ничего не примет.
enum AwakeAction: Codable, Equatable {
    case toggle
    case setKeepDisplay(Bool)
    case setDuration(Int)
}

/// Ответ на действие: состояние после него и текст, если действие не выполнено.
struct AwakeReply: Codable, Equatable {
    let state: AwakeState
    let error: String?
}

enum AwakeWire {
    /// Закодировать не вышло — пустой ответ: центр получит ошибку разбора, утилита не упадёт.
    static func encoded(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

extension AwakeController {
    var wireState: AwakeState {
        AwakeState(isActive: isActive, endDate: endDate, keepDisplay: keepDisplay, duration: duration, canStart: canStart)
    }

    /// Действие из связи: сначала проверка, изменения только после неё.
    func handle(_ data: Data) -> AwakeReply {
        // Самое длинное настоящее действие короче: длинное и разбирать незачем.
        guard data.count <= 256, let action = try? JSONDecoder().decode(AwakeAction.self, from: data) else {
            return AwakeReply(state: wireState, error: "Непонятная команда")
        }
        switch action {
        case .toggle:
            guard isActive || canStart else {
                return AwakeReply(state: wireState, error: "Сейчас модуль не может включиться")
            }
            toggle()
        case .setKeepDisplay(let on):
            keepDisplay = on
        case .setDuration(let seconds):
            guard let value = AwakeDuration(rawValue: seconds) else {
                return AwakeReply(state: wireState, error: "Такой длительности нет")
            }
            duration = value
        }
        return AwakeReply(state: wireState, error: nil)
    }
}
