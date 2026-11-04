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

    private static let hPad: CGFloat = 6
    private static let vPad: CGFloat = 3

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .padding(.horizontal, Self.hPad).padding(.vertical, Self.vPad)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(selected && enabled ? 0.5 : 0), lineWidth: 1))
            .padding(.horizontal, -Self.hPad).padding(.vertical, -Self.vPad)
            .onHover { hovering = $0 && enabled }
    }

    private var fill: Color {
        guard enabled else { return .clear }
        if selected { return Color.accentColor.opacity(hovering ? 0.22 : 0.15) }
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
    var colors: [Color] = [.accentColor, .orange]
    var width: CGFloat = 70

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Rectangle().fill(colors[min(i, colors.count - 1)])
                        .frame(width: maximum > 0 ? geo.size.width * min(1, v / maximum) : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: 5)
        .background(.quaternary)
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
        case .low: return ("инфо", .secondary)
        }
    }

    var body: some View {
        Text(style.0)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(style.1.opacity(0.18), in: Capsule())
            .foregroundStyle(style.1)
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

    private struct Piece {
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
            for part in seg.parts {
                let pw = w * part.weight / partsTotal
                out.append(Piece(segment: seg.id, x: px, width: pw, color: part.color, tip: part.tip))
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
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
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
    let snapshot: LoadSnapshot
    let palette: LoadPalette
    let mode: LoadViewMode
    /// Крупная версия для вкладки «Память»: с легендой «кто держит» и пояснением.
    var big = false
    @Binding var drill: MemoryPart?
    var onStop: (Int32) -> Void

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
                + Text(LoadScreen.pressureWord(m.pressure)).fontWeight(.semibold))
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
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
    let snapshot: LoadSnapshot
    let part: MemoryPart
    let palette: LoadPalette
    var onStop: (Int32) -> Void

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
                            StopButton(help: "Остановить \(r.name)") { onStop(r.pid) }
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
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle")
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
