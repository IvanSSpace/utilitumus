import Charts
import SwiftUI

/// Всё, что график считает по окну истории, — один раз при смене окна (раз в минуту), а не в каждом `body`.
/// Точки прорежены: на 24 ч их 288 × 6 рядов, а глазу хватает ~120.
struct HistoryChartModel {
    /// Точка с номером непрерывного отрезка: между отрезками рисуем разрыв.
    struct Row: Identifiable {
        var run: Int
        var point: HistoryWindow.Point
        var id: Int { point.ts }
        let date: Date
    }

    let window: HistoryWindow
    let rows: [Row]
    /// Ширина одной точки после прореживания, секунды.
    let step: Double
    let domain: ClosedRange<Date>
    let yMax: Double
    let yTicks: [Double]
    let swapMax: Double
    let seriesKeys: [String]
    /// Строки с `date` для быстрого поиска ближайшей по x.
    let times: [Double]

    static let maxPoints = 120

    init(window: HistoryWindow, ramMB: Int) {
        self.window = window
        seriesKeys = window.series.map(\.key)

        // Разрывы — по исходному шагу, до прореживания.
        var run = 0
        var tagged: [(run: Int, p: HistoryWindow.Point)] = []
        for (i, p) in window.points.enumerated() {
            if i > 0, Double(p.ts - window.points[i - 1].ts) > Double(window.stepSeconds) * 2.5 { run += 1 }
            tagged.append((run, p))
        }
        let k = max(1, Int((Double(tagged.count) / Double(Self.maxPoints)).rounded(.up)))
        var out: [Row] = []
        var i = 0
        while i < tagged.count {
            var j = i + 1
            while j < tagged.count, j - i < k, tagged[j].run == tagged[i].run { j += 1 }
            let chunk = tagged[i..<j]
            var p = chunk[chunk.endIndex - 1].p
            if chunk.count > 1 {
                let n = chunk.count
                p.usedMB = chunk.reduce(0) { $0 + $1.p.usedMB } / n
                p.swapMB = chunk.map(\.p.swapMB).max() ?? p.swapMB
                p.pressure = chunk.map(\.p.pressure).max() ?? p.pressure
                p.values = window.series.indices.map { s in chunk.reduce(0) { $0 + $1.p.values[safe: s] } / n }
            }
            out.append(Row(run: tagged[i].run, point: p, date: Date(timeIntervalSince1970: TimeInterval(p.ts))))
            i = j
        }
        rows = out
        step = Double(window.stepSeconds * k)
        times = out.map { Double($0.point.ts) }

        let last = Double(window.points.last?.ts ?? window.to)
        let t1 = max(Double(window.to), last)
        let first = Double(window.firstSample ?? window.points.first?.ts ?? window.from)
        let t0 = first > Double(window.from + window.stepSeconds)
            ? max(Double(window.from), min(first, Double(window.points.first?.ts ?? Int(first)), t1 - 3600))
            : Double(window.from)
        domain = Date(timeIntervalSince1970: t0)...Date(timeIntervalSince1970: t1)

        let top = Double(max(ramMB, window.points.map { $0.values.reduce(0, +) }.max() ?? 0)) * 1.03 / 1024
        let stepGB = [1.0, 2, 4, 5, 10, 20, 50, 100].first { top / $0 <= 5 } ?? 200
        let y = max(stepGB, (top / stepGB).rounded(.up) * stepGB) * 1024
        yMax = y
        yTicks = stride(from: 0, through: y, by: stepGB * 1024).map { $0 }
        swapMax = Double(max(window.points.map(\.swapMB).max() ?? 1, 1))
    }

    /// Ближайшая к моменту точка (по времени; `times` отсортированы).
    func nearest(to ts: Double) -> Row? {
        guard !rows.isEmpty else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < ts { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(times[lo - 1] - ts) <= abs(times[lo] - ts) { lo -= 1 }
        return rows[lo]
    }
}

/// Что сейчас под курсором. Отдельный объект: меняется только слой подсказки, сами графики не пересобираются.
@MainActor
final class ChartHover: ObservableObject {
    @Published private(set) var ts: Int?

    func set(_ new: Int?) { if ts != new { ts = new } }
}

/// График памяти за сутки: группы стопкой, под ним своп. Мак спал — линия рвётся, а не тянется.
/// `Equatable` + `.equatable()` на месте вызова: окно меняется раз в минуту, а экран обновляется каждые 3 с.
struct HistoryChart: View, Equatable {
    let window: HistoryWindow
    let ramMB: Int
    let swapTotalMB: Int
    let colors: [Color]

    var body: some View {
        HistoryChartBody(model: HistoryChartModel(window: window, ramMB: ramMB), ramMB: ramMB, swapTotalMB: swapTotalMB, colors: colors)
    }
}

private struct HistoryChartBody: View {
    let model: HistoryChartModel
    let ramMB: Int
    let swapTotalMB: Int
    let colors: [Color]

    @State private var hover = ChartHover()

    private var window: HistoryWindow { model.window }
    private var swapMax: Double { max(model.swapMax, Double(swapTotalMB)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            legend
            stack
            Text("своп").font(.caption).foregroundStyle(.secondary)
            swap
        }
    }

    private var legend: some View {
        let last = window.points.last
        return FlowGrid(minWidth: 170, spacing: 8, rowSpacing: 4) {
            ForEach(Array(window.series.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(colors[safe: i]).frame(width: 10, height: 10)
                    Text(s.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.mb(last?.values[safe: i] ?? 0)).fontWeight(.semibold).monospacedDigit()
                }
                .font(.callout)
            }
        }
    }

    private var stack: some View {
        Chart {
            ForEach(model.rows) { r in
                ForEach(Array(window.series.enumerated()), id: \.element.id) { i, s in
                    AreaMark(x: .value("Время", r.date), y: .value("MB", Double(r.point.values[safe: i])),
                             series: .value("Ряд", "\(s.key)#\(r.run)"))
                        .foregroundStyle(by: .value("Группа", s.key))
                }
            }
            if ramMB > 0 {
                RuleMark(y: .value("RAM", Double(ramMB)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("RAM \(Fmt.gb(Double(ramMB))) GB").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: model.seriesKeys, range: colors)
        .chartLegend(.hidden)
        .chartXScale(domain: model.domain)
        .chartYScale(domain: 0...model.yMax)
        .chartYAxis {
            AxisMarks(values: model.yTicks) { v in
                AxisGridLine()
                AxisValueLabel { if let mb = v.as(Double.self) { Text(mb == 0 ? "0" : "\(Int(mb / 1024)) GB").monospacedDigit() } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartOverlay { proxy in HoverLayer(proxy: proxy, model: model, colors: colors, hover: hover, showTip: true) }
        .frame(height: 170)
    }

    private var swap: some View {
        Chart {
            ForEach(model.rows) { r in
                if r.point.pressure > 1 {
                    RectangleMark(xStart: .value("с", r.date.addingTimeInterval(-model.step / 2)),
                                  xEnd: .value("по", r.date.addingTimeInterval(model.step / 2)),
                                  yStart: .value("низ", 0.0), yEnd: .value("верх", swapMax))
                        .foregroundStyle(r.point.pressure >= 4 ? Color.red.opacity(0.25) : Color.orange.opacity(0.25))
                }
                AreaMark(x: .value("Время", r.date), y: .value("Своп", Double(r.point.swapMB)), series: .value("Ряд", r.run))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                LineMark(x: .value("Время", r.date), y: .value("Своп", Double(r.point.swapMB)), series: .value("Ряд", r.run))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXScale(domain: model.domain)
        .chartYScale(domain: 0...swapMax)
        .chartYAxis {
            AxisMarks(values: [0, swapMax]) { v in
                AxisGridLine()
                AxisValueLabel { if let mb = v.as(Double.self) { Text(mb == 0 ? "0" : "\(Fmt.gb(mb)) GB").monospacedDigit() } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartOverlay { proxy in HoverLayer(proxy: proxy, model: model, colors: colors, hover: hover, showTip: false) }
        .frame(height: 56)
    }
}

/// Слой наведения поверх графика: вертикальная линия и подсказка. Единственное, что перерисовывается
/// при движении мыши: сам `Chart` (сотни меток) остаётся как был.
private struct HoverLayer: View {
    let proxy: ChartProxy
    let model: HistoryChartModel
    let colors: [Color]
    let hover: ChartHover
    let showTip: Bool

    var body: some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame.map({ geo[$0] }) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let x = p.x - plot.minX
                            if x >= 0, x <= plot.width, let date = proxy.value(atX: x, as: Date.self) {
                                hover.set(model.nearest(to: date.timeIntervalSince1970)?.point.ts)
                            } else {
                                hover.set(nil)
                            }
                        case .ended:
                            hover.set(nil)
                        }
                    }
                HoverMark(hover: hover, proxy: proxy, plot: plot, model: model, colors: colors, showTip: showTip)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct HoverMark: View {
    @ObservedObject var hover: ChartHover
    let proxy: ChartProxy
    let plot: CGRect
    let model: HistoryChartModel
    let colors: [Color]
    let showTip: Bool

    private static let tipWidth: CGFloat = 190

    var body: some View {
        if let ts = hover.ts, let row = model.rows.first(where: { $0.point.ts == ts }),
           let px = proxy.position(forX: row.date) {
            let x = plot.minX + px
            Rectangle().fill(.secondary.opacity(0.6)).frame(width: 1, height: plot.height)
                .position(x: x, y: plot.midY)
            if showTip {
                // Подсказка внутри графика: над ним её срезал край карточки.
                tip(row.point)
                    .position(x: min(max(x, plot.minX + Self.tipWidth / 2), plot.maxX - Self.tipWidth / 2), y: plot.minY)
                    .offset(y: tipHeight / 2)
            }
        }
    }

    private var tipHeight: CGFloat { CGFloat(40 + 14 * model.window.series.count) }

    private func tip(_ p: HistoryWindow.Point) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date(timeIntervalSince1970: TimeInterval(p.ts)), format: .dateTime.hour().minute()).font(.caption.weight(.semibold))
            ForEach(Array(model.window.series.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 4) {
                    Circle().fill(colors[safe: i]).frame(width: 6, height: 6)
                    Text(s.name).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.mb(p.values[safe: i])).monospacedDigit()
                }
            }
            Divider()
            Text("своп \(Fmt.mb(p.swapMB)) · занято \(Fmt.mb(p.usedMB))").monospacedDigit()
            if p.pressure > 1 { Text("давление \(p.pressure >= 4 ? "критическое" : "высокое")") }
        }
        .font(.caption2)
        .padding(6)
        .frame(width: Self.tipWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Мини-график для «Просто»: занято и своп, без осей.
struct HistorySpark: View, Equatable {
    let window: HistoryWindow
    static func == (a: Self, b: Self) -> Bool { a.window == b.window }
    @Environment(\.dsTint) private var tint

    private var points: [HistoryWindow.Point] { window.points }

    private func range(_ f: (HistoryWindow.Point) -> Int, minSpan: Int) -> ClosedRange<Double> {
        let v = points.map(f)
        let lo = Double(v.min() ?? 0), hi = Double(v.max() ?? 0)
        let pad = max(0, Double(minSpan) - (hi - lo)) / 2
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        if points.count < 2 {
            Text("История ещё копится.").font(.caption).foregroundStyle(.secondary)
        } else {
            let used = range({ $0.usedMB }, minSpan: 2048), swap = range({ $0.swapMB }, minSpan: 1024)
            let hours = Double((points.last?.ts ?? 0) - (points.first?.ts ?? 0)) / 3600
            VStack(alignment: .leading, spacing: 4) {
                Text("За \(hours >= 1 ? "\(Int(hours.rounded())) ч" : Fmt.duration(hours * 3600)): занято \(Fmt.gb(used.lowerBound + 1))–\(Fmt.gb(used.upperBound)) GB · своп \(Fmt.gb(max(0, swap.lowerBound)))–\(Fmt.gb(swap.upperBound)) GB")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Chart(points) { p in
                    AreaMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))), yStart: .value("низ", used.lowerBound),
                             yEnd: .value("занято", Double(p.usedMB))).foregroundStyle(tint.opacity(0.25))
                    LineMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))), y: .value("занято", Double(p.usedMB)))
                        .foregroundStyle(tint)
                }
                .chartYScale(domain: used).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 36)
                Chart(points) { p in
                    LineMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))), y: .value("своп", Double(p.swapMB)))
                        .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                .chartYScale(domain: swap).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 24)
            }
        }
    }
}

extension Array where Element == Color {
    subscript(safe i: Int) -> Color { indices.contains(i) ? self[i] : LoadPalette.rest }
}

extension Array where Element == Int {
    subscript(safe i: Int) -> Int { indices.contains(i) ? self[i] : 0 }
}
