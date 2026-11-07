import Foundation
import SwiftUI

/// Всегда-меняющееся из замера: время, память и CPU самой панели, длительность замера.
/// Отдельный маленький объект: подвал экрана наблюдает его, а тяжёлые секции — нет.
@MainActor
final class LiveStats: ObservableObject {
    @Published var timestamp = Date()
    @Published var measureMillis = 0.0
    @Published var selfMemMB = 0.0
    @Published var selfCPU: Double?

    func update(from s: LoadLive) {
        measureMillis = s.measureMillis
        selfMemMB = s.selfMemMB
        selfCPU = s.selfCPU
    }
}

extension LoadPalette: Equatable {
    static func == (a: LoadPalette, b: LoadPalette) -> Bool { a.slots == b.slots }
}
