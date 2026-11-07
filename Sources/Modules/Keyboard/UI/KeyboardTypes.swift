import Foundation

/// Когда переключать раскладку: на отпускании Fn (как в системе) или сразу на нажатии.
enum FnTrigger: String, CaseIterable {
    case onRelease, onPress
    var title: String { self == .onRelease ? "При отпускании" : "При нажатии" }
}

/// Режим выбора следующей раскладки.
enum LayoutMode: String, CaseIterable {
    case lastTwo, cycle
    var title: String { self == .lastTwo ? "Между двумя последними" : "По кругу" }
}

/// Запись журнала модуля: так она лежит в журнале и так ходит по связи.
struct KeyboardLogEntry: Codable, Equatable {
    let date: Date
    let text: String

    /// Время для списка на экране.
    static func shortTime(_ date: Date) -> String { String(stamp(date).dropFirst(11)) }

    static func stamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
