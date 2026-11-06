import SwiftUI

enum LoadViewMode: String, CaseIterable, Identifiable {
    case simple, full
    var id: String { rawValue }
    var title: String { self == .simple ? "Просто" : "Подробно" }
}

enum LoadTab: String, CaseIterable, Identifiable {
    case overview, sessions, background, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .sessions: return "Сессии"
        case .background: return "Фоновое"
        case .memory: return "Память"
        }
    }
}

/// Часть полосы памяти; клик по ней раскрывает разбор.
enum MemoryPart: String, CaseIterable, Identifiable {
    case app, wired, compressed, cached, free
    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "Приложения"
        case .wired: return "Зарезервировано"
        case .compressed: return "Сжато"
        case .cached: return "Кэш файлов"
        case .free: return "Свободно"
        }
    }

    func mb(_ m: MemoryTotals) -> Int {
        switch self {
        case .app: return m.appMB
        case .wired: return m.wiredMB
        case .compressed: return m.compressedMB
        case .cached: return m.cachedMB
        case .free: return m.freeMB
        }
    }

    /// Цвет части в «Просто» (в «Подробно» она разбита по программам).
    var baseColor: Color {
        switch self {
        case .app: return .blue
        case .wired: return LoadPalette.kernel
        case .compressed: return .orange
        case .cached: return LoadPalette.cache
        case .free: return LoadPalette.free
        }
    }

    var canFree: String {
        switch self {
        case .app, .compressed: return "можно освободить"
        case .wired: return "частично: помогает закрыть тяжёлые графические программы"
        case .cached: return "освобождается сам: macOS отдаст, когда понадобится"
        case .free: return ""
        }
    }
}

// MARK: Нажимаемые строки

/// Подсветка нажимаемой строки: при наведении — серый фон-скругление, как у строк списка macOS;
/// выбранная (`selected`) — акцентный фон и тонкая обводка. Раскладку не двигает: отступы компенсируются.
struct HoverRow: ViewModifier {
    var selected = false
    var enabled = true
    @State private var hovering = false
    @Environment(\.dsTint) private var tint

    private static let hPad: CGFloat = 6
    private static let vPad: CGFloat = 3

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .padding(.horizontal, Self.hPad).padding(.vertical, Self.vPad)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(tint.opacity(selected && enabled ? 0.5 : 0), lineWidth: 1))
            .padding(.horizontal, -Self.hPad).padding(.vertical, -Self.vPad)
            .onHover { hovering = $0 && enabled }
    }

    private var fill: Color {
        guard enabled else { return .clear }
        if selected { return tint.opacity(hovering ? 0.22 : 0.15) }
        return hovering ? Color.primary.opacity(0.09) : .clear
    }
}

extension View {
    /// Делает строку заметно нажимаемой: подсветка при наведении, `selected` — выделение выбранной.
    func hoverRow(selected: Bool = false, enabled: Bool = true) -> some View {
        modifier(HoverRow(selected: selected, enabled: enabled))
    }
}

/// Шеврон «откроется подробнее»: заметный, фиксированной ширины — выравнивается по правому краю.
struct DisclosureChevron: View {
    var open: Bool

    var body: some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12, alignment: .trailing)
    }
}

// MARK: Мелкие элементы

/// Плитка-итог: подпись, крупное число, пояснение. Цифры монохромные, цвет — только у индикатора.
struct KPITile: View {
    let title: String
    let value: String
    var unit = ""
    let subtitle: String
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if warn { Circle().fill(.orange).frame(width: 6, height: 6) }
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                if value != "—", !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Тонкая полоска доли.
struct ShareBar: View {
    var values: [Double]
    var maximum: Double
    /// nil — акцент модуля и оранжевый.
    var colors: [Color]?
    var width: CGFloat = 70
    @Environment(\.dsTint) private var tint

    var body: some View {
        let colors = colors ?? [tint, .orange]
        // Ширина известна заранее: без GeometryReader, который на сотне строк «Подробно» дорог.
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { i in
                Rectangle().fill(colors[min(i, colors.count - 1)])
                    .frame(width: maximum > 0 ? width * min(1, max(0, values[i] / maximum)) : 0)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 5)
        .background(.white.opacity(0.1))
        .clipShape(Capsule())
    }
}

/// Метка важности подсказки.
struct SeverityBadge: View {
    let severity: AdviceSeverity

    private var style: (String, Color) {
        switch severity {
        case .high: return ("важно", .red)
        case .med: return ("совет", .orange)
        case .low: return ("инфо", .gray)
        }
    }

    var body: some View {
        DSChip(style.0, color: style.1)
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

// MARK: Полоса памяти

struct BarPart {
    var weight: Double
    var color: Color
    var tip: String
}

struct BarSegment: Identifiable {
    var id: String
    var weight: Double
    var parts: [BarPart]
}

/// Полоса памяти: сегменты-категории, внутри — доли программ. Наведение — подсветка и подпись, клик — разбор.
///
/// Подпись своя, а не системная `.help`: экран обновляется каждые 3 с, полоса перерисовывается,
/// и системная подсказка (ждёт ~1 с неподвижного курсора) почти никогда не успевала появиться.
/// Под курсором храним только координату — подпись берётся из свежих данных и обновляется вместе с ними.
struct MemoryBar: View {
    var segments: [BarSegment]
    var height: CGFloat = 16
    var onTap: ((String) -> Void)?

    @State private var hoverX: CGFloat?
    @State private var calloutSize: CGSize = .zero

    private static let gap: CGFloat = 2

    private struct Piece: Identifiable {
        /// Сегмент и номер доли в нём: не зависит от общего порядка, пока состав сегментов тот же.
        var id: String
        var segment: String
        var x: CGFloat
        var width: CGFloat
        var color: Color
        var tip: String
    }

    private func layout(width: CGFloat) -> [Piece] {
        let gaps = CGFloat(max(segments.count - 1, 0)) * Self.gap
        let total = max(segments.reduce(0) { $0 + $1.weight }, 1)
        var x: CGFloat = 0
        var out: [Piece] = []
        for seg in segments {
            let w = max(2, (width - gaps) * seg.weight / total)
            let partsTotal = max(seg.parts.reduce(0) { $0 + $1.weight }, 1)
            var px = x
            for (n, part) in seg.parts.enumerated() {
                let pw = w * part.weight / partsTotal
                out.append(Piece(id: "\(seg.id)#\(n)", segment: seg.id, x: px, width: pw, color: part.color, tip: part.tip))
                px += pw
            }
            x += w + Self.gap
        }
        return out
    }

    /// Кусок под точкой; зазор между сегментами относим к левому — чтобы подпись не мигала.
    private func piece(at x: CGFloat, in pieces: [Piece]) -> Piece? {
        pieces.last { x >= $0.x } ?? pieces.first
    }

    var body: some View {
        GeometryReader { geo in
            let pieces = layout(width: geo.size.width)
            let hovered = hoverX.flatMap { piece(at: $0, in: pieces) }
            ZStack(alignment: .topLeading) {
                ForEach(pieces) { p in
                    Rectangle().fill(p.color)
                        .frame(width: max(p.width, 0), height: height)
                        .offset(x: p.x)
                        .opacity(hovered == nil || (hovered?.x == p.x) ? 1 : 0.4)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                if let p = piece(at: point.x, in: pieces) { onTap?(p.segment) }
            }
            .overlay(alignment: .topLeading) {
                if let hovered {
                    callout(hovered.tip)
                        .offset(x: calloutX(center: hovered.x + hovered.width / 2, width: geo.size.width),
                                y: -calloutSize.height - 6)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.1), value: hovered?.x)
        }
        .frame(height: height)
    }

    private func callout(_ tip: String) -> some View {
        Text(tip)
            .font(.caption)
            .monospacedDigit()
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { calloutSize = $0 }
    }

    /// Подпись по центру над куском, но в пределах полосы.
    private func calloutX(center: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, center - calloutSize.width / 2), max(0, width - calloutSize.width))
    }
}

// MARK: Карточка памяти

/// Содержимое карточки «Память»: итоги, полоса, легенда и (в «Подробно») раскрываемый разбор.
struct MemoryCard: View {
    let snapshot: LoadMeasure
    let palette: LoadPalette
    let mode: LoadViewMode
    /// Крупная версия для вкладки «Память»: с легендой «кто держит» и пояснением.
    var big = false
    @Binding var drill: MemoryPart?
    var onStop: (LoadRowID) -> Void

    private var m: MemoryTotals { snapshot.memory }
    private var map: MemoryMap { snapshot.map }

    private var wiredNamed: Double {
        min(Double(m.wiredMB), snapshot.map.wiredBreakdown.reduce(0) { $0 + $1.mb })
    }

    private func segments() -> [BarSegment] {
        MemoryPart.allCases.compactMap { p -> BarSegment? in
            let total = p.mb(m)
            guard total > 0 else { return nil }
            func bar(_ name: String, _ mb: Int, _ color: Color, note: String) -> BarPart {
                BarPart(weight: Double(mb), color: color,
                        tip: "\(p.title) · \(name): \(Fmt.mb(mb))" + (note.isEmpty ? "" : "\n\(note)"))
            }
            if mode == .simple {
                return BarSegment(id: p.rawValue, weight: Double(total), parts: [bar(p.title, total, p.baseColor, note: "")])
            }
            switch p {
            case .app, .compressed:
                let rows = (p == .app ? map.splitApp : map.splitCompressed).filter { $0.mb > 0 }
                let opacity = p == .compressed ? 0.6 : 1
                let subs = rows.map { r in
                    bar(r.name, r.mb, palette.color(forKey: r.colorKey).opacity(opacity),
                        note: r.key == "macos" ? "службы macOS — что можно сделать, в группе «Система»" : p.canFree)
                }
                return BarSegment(id: p.rawValue, weight: Double(total), parts: subs.isEmpty ? [bar(p.title, total, p.baseColor, note: "")] : subs)
            case .wired:
                let named = Int(wiredNamed.rounded())
                var subs: [BarPart] = []
                if named > 0 { subs.append(bar("программы: GPU и драйверы", named, LoadPalette.rest, note: p.canFree)) }
                if total - named > 0 { subs.append(bar("ядро macOS, драйверы, видеопамять", total - named, LoadPalette.kernel, note: "не освобождается вручную")) }
                return BarSegment(id: p.rawValue, weight: Double(total), parts: subs)
            default:
                return BarSegment(id: p.rawValue, weight: Double(total), parts: [bar(p.title, total, p.baseColor, note: p.canFree)])
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .simple { simpleHeader } else { fullHeader }
            MemoryBar(segments: segments(), height: big || mode == .simple ? 18 : 14) { id in
                if mode == .full, let part = MemoryPart(rawValue: id) { drill = drill == part ? nil : part }
            }
            legend
            if mode == .full, let part = drill { DrillPanel(snapshot: snapshot, part: part, palette: palette, onStop: onStop) }
            if mode == .full, big { programsLegend }
            if mode == .full, big, map.heldMB > 0 {
                Text("Программы держат \(Fmt.mb(map.heldMB)), из них \(Fmt.mb(map.swappedMB)) сжато или в свопе"
                     + (map.heldMB > m.totalMB ? " — поэтому сумма больше \(Fmt.gb(Double(m.totalMB))) GB." : "."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var simpleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text("Занято ") + Text(Fmt.gb(Double(m.usedMB))).fontWeight(.semibold) + Text(" из \(Fmt.gb(Double(m.totalMB))) GB · давление ")
                + Text(LoadText.pressureWord(m.pressure)).fontWeight(.semibold))
                .font(.title3).monospacedDigit()
            summaryLine(simple: true)
        }
    }

    private var fullHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Занято \(Fmt.gb(Double(m.usedMB))) GB · \(Fmt.percent(Double(m.usedMB), of: Double(m.totalMB)))")
                    .font(.headline).monospacedDigit()
                Spacer()
                Text("из \(Fmt.gb(Double(m.totalMB))) GB").foregroundStyle(.secondary).monospacedDigit()
            }
            summaryLine(simple: false)
        }
    }

    /// «macOS ≈ X + ядро Y · твои программы ≈ Z · кэш W»
    private func summaryLine(simple: Bool) -> some View {
        let kern = Int(max(0, Double(m.wiredMB) - wiredNamed).rounded())
        var parts: [String] = []
        if simple {
            // macOS вместе с ядром — с программами сходится с «занято».
            parts.append("macOS ≈ \(Fmt.mb(map.macosMB + m.wiredMB))")
        } else {
            parts.append("macOS ≈ \(Fmt.mb(map.macosMB))" + (kern > 0 ? " + ядро \(Fmt.mb(kern))" : ""))
        }
        parts.append("твои программы ≈ \(Fmt.mb(map.programsMB))")
        parts.append("кэш \(Fmt.mb(map.cacheMB)) (освобождается сам)")
        return Text(parts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }

    private var legend: some View {
        FlowGrid(minWidth: 200, spacing: 8, rowSpacing: 4) {
            ForEach(MemoryPart.allCases.filter { $0.mb(m) > 0 }) { p in
                Button {
                    if mode == .full { drill = drill == p ? nil : p }
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(p.baseColor).frame(width: 10, height: 10)
                        Text(p.title)
                        Spacer(minLength: 4)
                        Text(Fmt.mb(p.mb(m))).fontWeight(.semibold).monospacedDigit()
                        if mode == .full { DisclosureChevron(open: drill == p) }
                    }
                    .contentShape(Rectangle())
                    .hoverRow(selected: drill == p, enabled: mode == .full)
                }
                .buttonStyle(.plain)
                .help(p == .wired ? "Ядро macOS, драйверы, видеопамять" : p.title)
                .allowsHitTesting(mode == .full)
            }
        }
        .font(.callout)
    }

    private var programsLegend: some View {
        let entries = palette.legend(for: map).filter { $0.mb > 0 }
        return VStack(alignment: .leading, spacing: 4) {
            Text("кто держит:").font(.caption).foregroundStyle(.secondary)
            FlowGrid(minWidth: 170, spacing: 8, rowSpacing: 4) {
                ForEach(entries) { e in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(e.color).frame(width: 10, height: 10)
                        Text(e.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.mb(e.mb)).fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Разбор части полосы: из чего она состоит.
struct DrillPanel: View {
    let snapshot: LoadMeasure
    let part: MemoryPart
    let palette: LoadPalette
    var onStop: (LoadRowID) -> Void

    private var map: MemoryMap { snapshot.map }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Разбор: \(part.title)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(Fmt.mb(part.mb(snapshot.memory))).monospacedDigit().foregroundStyle(.secondary)
            }
            switch part {
            case .free:
                note(MemoryMap.freeNote)
            case .cached:
                note(MemoryMap.cachedNote)
            case .app:
                if map.appBreakdown.isEmpty { EmptyNote(text: "Нет данных о процессах в RAM.") } else {
                    let maxV = Double(map.appBreakdown.map { $0.ramMB + $0.swappedMB }.max() ?? 1)
                    ForEach(map.appBreakdown) { r in
                        HStack {
                            Text(r.name).lineLimit(1)
                            Text(kindName(r.kind)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            (Text("в RAM ") + Text(Fmt.mb(r.ramMB)).fontWeight(.semibold) + Text(" · сжато/своп ")
                                + Text(Fmt.mb(r.swappedMB)).fontWeight(.semibold))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            ShareBar(values: [Double(r.ramMB), Double(r.swappedMB)], maximum: maxV, colors: [.blue, .orange], width: 60)
                        }
                    }
                    note("Общие страницы считаются в каждом процессе, поэтому сумма может быть больше «Приложений».")
                }
            case .compressed:
                note("Сжато или в свопе: footprint минус RAM.")
                if map.compressedBreakdown.isEmpty { EmptyNote(text: "Сжатого и выгруженного в своп почти нет.") }
                ForEach(map.compressedBreakdown) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.name).lineLimit(1)
                            Text(r.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.mb(r.mb)).monospacedDigit()
                        if r.stoppable {
                            StopButton(help: "Остановить \(r.name)") { onStop(r.rowID) }
                        }
                    }
                }
            case .wired:
                note(MemoryMap.wiredNote)
                if map.wiredBreakdown.isEmpty { EmptyNote(text: "Своих процессов с заметной зарезервированной памятью нет.") }
                ForEach(map.wiredBreakdown) { r in
                    HStack {
                        Text(r.name).lineLimit(1)
                        Text("PID \(r.pid)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.mb(r.mb)).monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func kindName(_ k: GroupKind) -> String {
        switch k {
        case .project: return "проект"
        case .app: return "приложение"
        case .system: return "система"
        case .other: return "прочее"
        }
    }
}

/// Маленькая кнопка «Остановить» в строке.
struct StopButton: View {
    /// Ширина кнопки: на месте отсутствующей ставят `StopButton.gap`, чтобы колонки не плясали.
    static let slot: CGFloat = 34
    static var gap: some View { Color.clear.frame(width: slot, height: 1) }

    var help: String
    var action: () -> Void

    var body: some View {
        DSButton("", icon: "stop.circle", style: .plain, small: true, action: action)
            .frame(width: Self.slot)
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: Строки в стиле DSRow

/// Строка с произвольным содержимым внутри `DSSection`: отступы и тонкий разделитель как у `DSRow`.
/// `divider: false` — продолжение предыдущей строки (раскрытое тело группы).
struct LoadLine<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .overlay(alignment: .top) {
                if divider { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
            }
    }
}

/// Пустая секция: заметка в строке.
struct LoadEmpty: View {
    let text: String
    var body: some View { LoadLine { EmptyNote(text: text) } }
}

/// Подпись мелким под строками секции.
struct LoadNote: View {
    let text: String
    var body: some View {
        LoadLine { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}

// MARK: Сетка колонок

/// Адаптивная сетка: сколько колонок влезет по `minWidth`, столько и будет, колонки одной ширины.
/// Не ленивая: `LazyVGrid` внутри прокрутки с якорем сверху не рисовал содержимое до первой прокрутки.
struct FlowGrid: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 4

    private func columns(for width: CGFloat) -> Int {
        // При неопределённой ширине (бесконечность) — одна колонка.
        guard width.isFinite else { return 1 }
        return max(1, Int(((width + spacing) / (minWidth + spacing)).rounded(.down)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minWidth
        let cols = columns(for: width)
        let colWidth = max(0, (width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        var height: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let row = subviews[start..<min(start + cols, subviews.count)]
            height += row.map { $0.sizeThatFits(.init(width: colWidth, height: nil)).height }.max() ?? 0
            height += rowSpacing
        }
        return CGSize(width: width, height: max(0, height - rowSpacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = columns(for: bounds.width)
        let colWidth = max(0, (bounds.width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        var y = bounds.minY
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let row = subviews[start..<min(start + cols, subviews.count)]
            let rowHeight = row.map { $0.sizeThatFits(.init(width: colWidth, height: nil)).height }.max() ?? 0
            for (i, view) in row.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (colWidth + spacing), y: y),
                           anchor: .topLeading, proposal: .init(width: colWidth, height: rowHeight))
            }
            y += rowHeight + rowSpacing
        }
    }
}
