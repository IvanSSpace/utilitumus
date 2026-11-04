import Charts
import SwiftUI

/// График памяти за сутки: группы стопкой, под ним своп. Мак спал — линия рвётся, а не тянется.
struct HistoryChart: View {
    let window: HistoryWindow
    let ramMB: Int
    let swapTotalMB: Int
    let colors: [Color]

    @State private var selected: Date?

    /// Точка с номером непрерывного отрезка: между отрезками рисуем разрыв.
    private struct Row: Identifiable {
        var id: Int { point.ts }
        var run: Int
        var point: HistoryWindow.Point
        var date: Date { Date(timeIntervalSince1970: TimeInterval(point.ts)) }
    }

    private var rows: [Row] {
        var run = 0
        var out: [Row] = []
        for (i, p) in window.points.enumerated() {
            if i > 0, Double(p.ts - window.points[i - 1].ts) > Double(window.stepSeconds) * 2.5 { run += 1 }
            out.append(Row(run: run, point: p))
        }
        return out
    }

    /// Окно по данным, если их меньше суток, но не уже часа.
    private var domain: ClosedRange<Date> {
        let last = Double(window.points.last?.ts ?? window.to)
        let t1 = max(Double(window.to), last)
        let first = Double(window.firstSample ?? window.points.first?.ts ?? window.from)
        let t0 = first > Double(window.from + window.stepSeconds)
            ? max(Double(window.from), min(first, Double(window.points.first?.ts ?? Int(first)), t1 - 3600))
            : Double(window.from)
        return Date(timeIntervalSince1970: t0)...Date(timeIntervalSince1970: t1)
    }

    private var yMax: Double {
        let top = Double(max(ramMB, rows.map { $0.point.values.reduce(0, +) }.max() ?? 0)) * 1.03 / 1024
        let step = [1.0, 2, 4, 5, 10, 20, 50, 100].first { top / $0 <= 5 } ?? 200
        return max(step, (top / step).rounded(.up) * step) * 1024
    }

    private var yTicks: [Double] {
        let step = [1.0, 2, 4, 5, 10, 20, 50, 100].first { yMax / 1024 / $0 <= 5 } ?? 200
        return stride(from: 0, through: yMax, by: step * 1024).map { $0 }
    }

    private var swapMax: Double { Double(max(swapTotalMB, window.points.map(\.swapMB).max() ?? 1, 1)) }

    private var nearest: HistoryWindow.Point? {
        guard let selected else { return nil }
        let ts = selected.timeIntervalSince1970
        return window.points.min { abs(Double($0.ts) - ts) < abs(Double($1.ts) - ts) }
    }

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
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
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
            ForEach(rows) { r in
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
            if let p = nearest {
                RuleMark(x: .value("Время", Date(timeIntervalSince1970: TimeInterval(p.ts))))
                    .foregroundStyle(.secondary.opacity(0.6))
                    // Подсказка внутри графика: над ним её срезал край карточки.
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { tip(p) }
            }
        }
        .chartForegroundStyleScale(domain: window.series.map(\.key), range: colors)
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(values: yTicks) { v in
                AxisGridLine()
                AxisValueLabel { if let mb = v.as(Double.self) { Text(mb == 0 ? "0" : "\(Int(mb / 1024)) GB").monospacedDigit() } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartXSelection(value: $selected)
        .frame(height: 170)
    }

    private var swap: some View {
        Chart {
            ForEach(rows) { r in
                if r.point.pressure > 1 {
                    RectangleMark(xStart: .value("с", r.date.addingTimeInterval(-Double(window.stepSeconds) / 2)),
                                  xEnd: .value("по", r.date.addingTimeInterval(Double(window.stepSeconds) / 2)),
                                  yStart: .value("низ", 0.0), yEnd: .value("верх", swapMax))
                        .foregroundStyle(r.point.pressure >= 4 ? Color.red.opacity(0.25) : Color.orange.opacity(0.25))
                }
                AreaMark(x: .value("Время", r.date), y: .value("Своп", Double(r.point.swapMB)), series: .value("Ряд", r.run))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                LineMark(x: .value("Время", r.date), y: .value("Своп", Double(r.point.swapMB)), series: .value("Ряд", r.run))
                    .foregroundStyle(Color.secondary)
            }
            if let p = nearest {
                RuleMark(x: .value("Время", Date(timeIntervalSince1970: TimeInterval(p.ts))))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...swapMax)
        .chartYAxis {
            AxisMarks(values: [0, swapMax]) { v in
                AxisGridLine()
                AxisValueLabel { if let mb = v.as(Double.self) { Text(mb == 0 ? "0" : "\(Fmt.gb(mb)) GB").monospacedDigit() } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        .chartXSelection(value: $selected)
        .frame(height: 56)
    }

    private func tip(_ p: HistoryWindow.Point) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date(timeIntervalSince1970: TimeInterval(p.ts)), format: .dateTime.hour().minute()).font(.caption.weight(.semibold))
            ForEach(Array(window.series.enumerated()), id: \.element.id) { i, s in
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
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Мини-график для «Просто»: занято и своп, без осей.
struct HistorySpark: View {
    let window: HistoryWindow

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
                             yEnd: .value("занято", Double(p.usedMB))).foregroundStyle(Color.accentColor.opacity(0.25))
                    LineMark(x: .value("t", Date(timeIntervalSince1970: TimeInterval(p.ts))), y: .value("занято", Double(p.usedMB)))
                        .foregroundStyle(Color.accentColor)
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
