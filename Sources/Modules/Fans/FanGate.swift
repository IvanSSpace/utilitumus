import Foundation

/// Скользящее среднее температуры: шум датчика не должен гонять цель оборотов.
struct TempSmoother {
    private(set) var samples: [Double] = []
    let size: Int
    init(size: Int = 4) { self.size = size }

    /// Добавить замер, вернуть среднее по последним `size`.
    mutating func add(_ value: Double) -> Double {
        samples.append(value)
        if samples.count > size { samples.removeFirst(samples.count - size) }
        return samples.reduce(0, +) / Double(samples.count)
    }

    mutating func reset() { samples = [] }
}

/// Гистерезис команд помощнику (запуск setuid-процесса дорог).
enum FanGate {
    /// Минимальный сдвиг цели относительно последней отправленной.
    static let step = 150.0
    /// Через столько секунд шлём при любом отличии.
    static let refresh: TimeInterval = 10
    /// Ручной режим держит клиент: служба отдаёт вентилятор системе, если удержание не повторялось `FanLink.holdTimeout`.
    /// Повтор втрое чаще срока; такт 2 с, так что на деле раз в 6 с.
    static let holdRefresh: TimeInterval = 5

    /// `urgent` — «Полная мощность», игры, «Всё авто», безопасность, смена режима
    /// и не-датчиковые режимы: ждать нельзя. Нет истории — тоже шлём.
    static func shouldSend(desired: Double, lastSent: Double?, lastSentAt: Date?, now: Date, urgent: Bool) -> Bool {
        if urgent { return true }
        guard let lastSent, let lastSentAt else { return true }
        let diff = abs(desired.rounded() - lastSent.rounded())
        if diff >= step { return true }
        return diff > 0 && now.timeIntervalSince(lastSentAt) >= refresh
    }
}
