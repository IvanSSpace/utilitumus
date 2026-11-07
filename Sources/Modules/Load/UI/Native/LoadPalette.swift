import SwiftUI

/// Цвета программ на полосе памяти и графике. Слот программы закрепляется за ней, пока она в списке,
/// поэтому цвет не прыгает между замерами.
struct LoadPalette {
    /// Цвета программ; macOS и «прочее» — серые, у них свои.
    static let slotColors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .yellow, .indigo]
    static let macOS = Color(nsColor: .systemGray)
    static let rest = Color(nsColor: .tertiaryLabelColor)
    static let kernel = Color(nsColor: .darkGray)
    static let cache = Color.cyan.opacity(0.45)
    static let free = Color.secondary.opacity(0.18)

    private(set) var slots: [String: Int] = [:]

    /// Строка легенды «кто держит»: имя, MB, цвет.
    struct Entry: Identifiable {
        var name: String
        var mb: Int
        var color: Color
        var id: String { name }
    }

    func color(forKey key: String) -> Color {
        if key == "macos" || key == "system" { return Self.macOS }
        if let slot = slots[key] { return Self.slotColors[slot] }
        return Self.rest
    }

    /// Суммы по программам из карт «Приложения» и «Сжато»; macOS и «прочее» отдельно.
    private struct Totals {
        var byKey: [String: Int] = [:]
        var names: [String: String] = [:]
        var macos = 0
        var rest = 0

        init(_ map: MemoryMap) {
            for r in map.splitApp + map.splitCompressed {
                switch r.key {
                case "macos": macos += r.mb
                case "rest": rest += r.mb
                default:
                    byKey[r.colorKey, default: 0] += r.mb
                    names[r.colorKey] = r.name
                }
            }
        }

        /// Программы по убыванию памяти.
        var order: [String] {
            byKey.keys.sorted { byKey[$0]! != byKey[$1]! ? byKey[$0]! > byKey[$1]! : $0 < $1 }
        }
    }

    /// Раздаёт слоты: самым большим программам — свободные цвета, остальные идут в «прочее».
    mutating func update(from map: MemoryMap) {
        let totals = Totals(map)
        slots = slots.filter { totals.byKey[$0.key] != nil }
        for key in totals.order where slots[key] == nil {
            let used = Set(slots.values)
            guard let free = Self.slotColors.indices.first(where: { !used.contains($0) }) else { break }
            slots[key] = free
        }
    }

    /// Легенда «кто держит»: macOS, программы со своим цветом, прочее (в него — программы без цвета).
    func legend(for map: MemoryMap) -> [Entry] {
        let totals = Totals(map)
        var rest = totals.rest
        var out: [Entry] = []
        if totals.macos > 0 { out.append(Entry(name: "macOS", mb: totals.macos, color: Self.macOS)) }
        for key in totals.order {
            if slots[key] != nil { out.append(Entry(name: totals.names[key] ?? key, mb: totals.byKey[key]!, color: color(forKey: key))) }
            else { rest += totals.byKey[key]! }
        }
        if rest > 0 { out.append(Entry(name: "прочее", mb: rest, color: Self.rest)) }
        return out
    }

    /// Цвета рядов истории: у кого есть слот — тот же, что на карте; остальным — свободные.
    func colors(forSeries series: [HistoryWindow.Series]) -> [Color] {
        var mine: [Color?] = series.map { s in
            if s.key == "system" { return Self.macOS }
            if s.key == "rest" { return Self.rest }
            return slots[s.key].map { Self.slotColors[$0] }
        }
        let usedSlots = Set(slots.values)
        var spare = Self.slotColors.indices.filter { !usedSlots.contains($0) }.map { Self.slotColors[$0] }
        for i in mine.indices where mine[i] == nil {
            mine[i] = spare.isEmpty ? Self.rest : spare.removeFirst()
        }
        return mine.map { $0 ?? Self.rest }
    }
}
