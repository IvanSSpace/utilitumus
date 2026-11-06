import CoreGraphics
import Foundation

/// Раскладка боковой панели: три зоны (закреплённые, список, скрытые), порядок в каждой и перенос между ними.
/// Чистая модель без вида и без настроек: состав зон выводится из трёх источников правды (кто закреплён,
/// кто скрыт, кто установлен), порядок — из одного общего порядка модулей.
struct SidebarLayout: Equatable {
    enum Zone: String, CaseIterable { case pinned, list, hidden }

    /// Больше закрепить нельзя: десятое перетаскивание отклоняется.
    static let maxPinned = 9
    /// Столько значков и больше может не поместиться рядом с вырезом MacBook: только тихая подсказка.
    static let notchHintFrom = 7

    private(set) var pinned: [Module]
    private(set) var list: [Module]
    private(set) var hidden: [Module]

    init(pinned: [Module] = [], list: [Module] = [], hidden: [Module] = []) {
        self.pinned = pinned
        self.list = list
        self.hidden = hidden
    }

    /// Состав зон. `order` — общий порядок, `present` — модули, у которых есть строка (установленные и открытый сейчас),
    /// `pins` — у кого `MenuBarIcon.<id>` включён, `hidden` — скрытые из списка. Закрепление сильнее скрытия.
    static func resolve(order: [Module], present: Set<Module>, pins: Set<Module>, hidden: Set<Module>) -> SidebarLayout {
        var result = SidebarLayout()
        for module in order where present.contains(module) {
            if pins.contains(module) {
                if result.pinned.count < maxPinned { result.pinned.append(module) } else { result.list.append(module) }
            } else if hidden.contains(module) {
                result.hidden.append(module)
            } else {
                result.list.append(module)
            }
        }
        return result
    }

    func items(_ zone: Zone) -> [Module] {
        switch zone {
        case .pinned: return pinned
        case .list: return list
        case .hidden: return hidden
        }
    }

    func zone(of module: Module) -> Zone? {
        Zone.allCases.first { items($0).contains(module) }
    }

    /// Все модули подряд в порядке экрана: закреплённые, список, скрытые.
    var flattened: [Module] { pinned + list + hidden }

    var showsNotchHint: Bool { pinned.count >= Self.notchHintFrom }

    /// Можно ли перенести модуль в зону (закреплённых не больше `maxPinned`).
    func canMove(_ module: Module, to zone: Zone) -> Bool {
        zone != .pinned || self.zone(of: module) == .pinned || pinned.count < Self.maxPinned
    }

    /// Перенос модуля в зону на место `index` (счёт без самого модуля). false — отказ, ничего не изменилось.
    @discardableResult
    mutating func move(_ module: Module, to zone: Zone, at index: Int) -> Bool {
        guard let from = self.zone(of: module), canMove(module, to: zone) else { return false }
        remove(module, from: from)
        var target = items(zone)
        target.insert(module, at: min(max(index, 0), target.count))
        set(target, zone)
        return true
    }

    /// Сдвиг внутри зоны на `delta` мест (⌘⌥↑/↓).
    @discardableResult
    mutating func nudge(_ module: Module, by delta: Int) -> Bool {
        guard let zone = zone(of: module), let at = items(zone).firstIndex(of: module) else { return false }
        let new = min(max(at + delta, 0), items(zone).count - 1)
        guard new != at else { return false }
        return move(module, to: zone, at: new)
    }

    /// Общий порядок после раскладки: модули зон идут в порядке экрана, остальные (не установленные) сохраняют места после них.
    func mergedOrder(_ old: [Module]) -> [Module] {
        let shown = Set(flattened)
        return flattened + old.filter { !shown.contains($0) }
    }

    private mutating func remove(_ module: Module, from zone: Zone) {
        set(items(zone).filter { $0 != module }, zone)
    }

    private mutating func set(_ modules: [Module], _ zone: Zone) {
        switch zone {
        case .pinned: pinned = modules
        case .list: list = modules
        case .hidden: hidden = modules
        }
    }

    // MARK: Перетаскивание

    /// Куда сейчас целится перетаскиваемый модуль. nil у `Preview.target` — вернуть на место.
    struct Target: Equatable {
        var zone: Zone
        var index: Int
    }

    /// Зоны во время перетаскивания: на месте взятого пустота (nil), в целевой зоне на месте вставки тоже.
    func preview(_ module: Module, target: Target?) -> [Zone: [Module?]] {
        var result: [Zone: [Module?]] = [:]
        guard let source = zone(of: module) else {
            for zone in Zone.allCases { result[zone] = items(zone) }
            return result
        }
        guard let target, canMove(module, to: target.zone) else {
            for zone in Zone.allCases { result[zone] = items(zone).map { $0 == module ? nil : $0 } }
            return result
        }
        for zone in Zone.allCases { result[zone] = items(zone).filter { $0 != module } }
        _ = source
        var inserted = result[target.zone] ?? []
        inserted.insert(nil, at: min(max(target.index, 0), inserted.count))
        result[target.zone] = inserted
        return result
    }

    /// Что стоит в зоне на экране, пока тянут `module`. В закреплённых и в списке место вставки открыто пустотой,
    /// в «Скрытых» остальные не двигаются (там показывается линия вставки) и открывают место, только когда модуль отпустили.
    func slots(_ zone: Zone, dragging module: Module?, target: Target?, settling: Bool) -> [Module?] {
        guard let module else { return items(zone) }
        if zone != .hidden { return preview(module, target: target)[zone] ?? [] }
        var rows: [Module?] = hidden.filter { $0 != module }
        guard settling else { return rows }
        let at: Int?
        if let target { at = target.zone == .hidden ? target.index : nil } else { at = hidden.firstIndex(of: module) }
        if let at { rows.insert(nil, at: min(max(at, 0), rows.count)) }
        return rows
    }
}

/// Размеры и места. Всё считается по числам: строки одной высоты, плитки сетки одного размера.
enum SidebarMetrics {
    static let tileHeight: CGFloat = 40
    static let tileGap: CGFloat = 6
    static let rowHeight: CGFloat = 46
    static let rowGap: CGFloat = 2
    static let hiddenRowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 30
    static let sectionGap: CGFloat = 8
    /// Пустая зона закреплённых: пунктирная подсказка.
    static let emptyHintHeight: CGFloat = 40
    /// Отступ от плиток до списка и от верха списка до первой строки.
    static let pinnedBottomGap: CGFloat = 8
    static let listTop: CGFloat = 2

    /// Столбцов по числу плиток: 1–4 — одной строкой, 5–6 — три, 7–8 — четыре, 9 — три.
    static func columns(_ count: Int) -> Int {
        switch count {
        case ...1: return 1
        case 2...4: return count
        case 5, 6: return 3
        case 7, 8: return 4
        default: return 3
        }
    }

    /// Места плиток слева направо, сверху вниз, в координатах сетки. Неполная последняя строка прижата влево.
    static func pinnedFrames(count: Int, width: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = columns(count)
        let tile = (width - tileGap * CGFloat(cols - 1)) / CGFloat(cols)
        return (0..<count).map { i in
            CGRect(x: CGFloat(i % cols) * (tile + tileGap), y: CGFloat(i / cols) * (tileHeight + tileGap),
                   width: tile, height: tileHeight)
        }
    }

    static func pinnedHeight(count: Int) -> CGFloat {
        guard count > 0 else { return emptyHintHeight }
        let rows = (count + columns(count) - 1) / columns(count)
        return CGFloat(rows) * tileHeight + CGFloat(rows - 1) * tileGap
    }

    static func listHeight(count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * (rowHeight + rowGap) - rowGap
    }

    static func listFrame(index: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * (rowHeight + rowGap), width: width, height: rowHeight)
    }

    static func hiddenFrame(index: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * (hiddenRowHeight + rowGap), width: width, height: hiddenRowHeight)
    }

    /// Размер поднятой копии в зоне: плитка по числу плиток, строка по ширине.
    static func size(of zone: SidebarLayout.Zone, pinnedCount: Int, width: CGFloat) -> CGSize {
        switch zone {
        case .pinned:
            let frames = pinnedFrames(count: max(pinnedCount, 1), width: width)
            return CGSize(width: frames[0].width, height: tileHeight)
        case .list: return CGSize(width: width, height: rowHeight)
        case .hidden: return CGSize(width: width, height: hiddenRowHeight)
        }
    }

    /// Куда вставить: ближайшая к точке (в координатах сетки) из мест сетки на `count + 1` плиток.
    static func pinnedInsertion(point: CGPoint, others count: Int, width: CGFloat) -> Int {
        let slots = pinnedFrames(count: count + 1, width: width)
        let best = slots.indices.min { a, b in
            hypot(slots[a].midX - point.x, slots[a].midY - point.y) < hypot(slots[b].midX - point.x, slots[b].midY - point.y)
        }
        return best ?? 0
    }

    /// Куда вставить в столбец строк: `y` — от верха зоны, `count` — сколько там других.
    static func columnInsertion(y: CGFloat, others count: Int, rowHeight: CGFloat) -> Int {
        let stride = rowHeight + rowGap
        return min(max(Int(((y - rowHeight / 2) / stride).rounded()), 0), count)
    }
}
