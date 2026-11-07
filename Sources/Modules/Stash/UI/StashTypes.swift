import Foundation
import CryptoKit

/// Окно программы в стеше: кадр в глобальных координатах экрана (AX, начало сверху слева).
struct StashedWindow: Codable, Equatable {
    /// Хэш заголовка: заголовок нужен только для сопоставления окон, а темы писем и названия документов
    /// незачем держать открытым текстом. В записях старых версий здесь сам заголовок.
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Что сохранять вместо заголовка. Пустой заголовок остаётся пустым: по нему окна не сопоставляются.
    static func storedTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        return SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(title current: String?) -> Bool {
        guard !title.isEmpty, let current, !current.isEmpty else { return false }
        return title == current || title == Self.storedTitle(current)
    }
}

/// Запись стеша: чем была программа и где стояли её окна.
/// Хранится в UserDefaults и переживает обновления приложения. Формат менять
/// только совместимо: новые поля — опциональные, старые не переименовывать,
/// иначе стеш, сделанный до обновления, не вернётся.
struct StashedApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var path: String
    var name: String
    var windows: [StashedWindow]
    var id: String { bundleID }
}

/// Сколько программа ест вместе со всеми своими процессами (у Chrome их десятки).
struct AppUsage: Codable, Equatable, Sendable {
    let memoryMB: Double
    let cpu: Double
    /// Порог «тяжёлой»: от 1 ГБ памяти или от четверти ядра процессора.
    var isHeavy: Bool { memoryMB >= 1024 || cpu >= 25 }
}

/// Сценарий: именованный набор программ, который прячется одним нажатием.
/// Хранится в UserDefaults; формат менять только совместимо (новые поля — опциональные).
struct StashScenario: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var bundleIDs: [String]
}

/// Итог возврата — показывается на экране, чтобы пропавшее с диска не терялось молча.
struct RestoreReport: Codable, Equatable, Sendable {
    var restored = 0
    var windowsPlaced = 0
    var missing: [String] = []
    var failed: [String] = []
    var hadAccess = true
}
