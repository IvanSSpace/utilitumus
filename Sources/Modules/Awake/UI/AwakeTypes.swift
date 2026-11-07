import Foundation

/// На сколько включать «Не спать».
enum AwakeDuration: Int, CaseIterable, Codable {
    case forever = 0, hour1 = 3600, hour2 = 7200, hour4 = 14400

    var title: String {
        switch self {
        case .forever: return "Пока не выключу"
        case .hour1: return "1 ч"
        case .hour2: return "2 ч"
        case .hour4: return "4 ч"
        }
    }
}

/// Ключи настроек и текст, общие для контроллера и экрана. Домен настроек у центра и утилиты один.
enum AwakeKeys {
    static let display = "AwakeKeepDisplay"
    static let duration = "AwakeDuration"

    /// «1 ч 23 мин» / «12 мин» / «меньше минуты».
    static func remainingText(until end: Date, now: Date = Date()) -> String {
        let minutes = Int((end.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "меньше минуты" }
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }
}
