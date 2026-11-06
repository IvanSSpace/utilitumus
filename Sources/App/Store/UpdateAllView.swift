import SwiftUI

/// Плашка внизу боковой панели. Появляется, только когда есть что сказать; тишина — когда обновлять нечего.
struct UpdateAllNotice: View {
    @ObservedObject private var updates = UpdateAll.shared

    private struct Content {
        let icon: String
        let tint: Color
        let title: String
        var subtitle: String?
        var progress: Double?
    }

    private var content: Content? {
        if updates.running {
            let current = updates.current?.title
            return Content(icon: "arrow.triangle.2.circlepath", tint: .accentColor,
                           title: "Обновляю: \(updates.finished + 1) из \(updates.total)", subtitle: current,
                           progress: Double(updates.finished) / Double(max(updates.total, 1)))
        }
        let rows = updates.rows
        guard !rows.isEmpty else { return nil }
        if updates.failedCount > 0 {
            return Content(icon: "exclamationmark.triangle.fill", tint: .orange, title: "Не вышло: \(updates.failedCount)",
                           subtitle: "Открой, чтобы повторить")
        }
        let startable = updates.startable
        if !startable.isEmpty {
            let names = startable.prefix(2).map(\.title).joined(separator: ", ")
            let more = startable.count > 2 ? " и ещё \(startable.count - 2)" : ""
            return Content(icon: "arrow.down.circle.fill", tint: .orange, title: "Обновления: \(startable.count)", subtitle: names + more)
        }
        if updates.waitingCount > 0 {
            return Content(icon: "hourglass", tint: .white.opacity(0.7), title: "Ждут: \(updates.waitingCount)",
                           subtitle: "Обновятся, когда освободятся")
        }
        if updates.doneCount > 0 {
            return Content(icon: "checkmark.circle.fill", tint: .green, title: "Обновлено: \(updates.doneCount)")
        }
        return Content(icon: "arrow.up.circle", tint: .white.opacity(0.7), title: "Есть новые версии",
                       subtitle: "Сначала обнови Utilitumus")
    }

    var body: some View {
        if let content {
            HStack(spacing: 9) {
                Image(systemName: content.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(content.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    if let subtitle = content.subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    if let progress = content.progress { StoreProgressBar(value: progress, tint: content.tint).padding(.top, 2) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .hoverFill(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous),
                       normal: .white.opacity(0.06), hovered: .white.opacity(0.1))
            .contentShape(Rectangle())
            .onTapGesture { updates.showList() }
            .accessibilityAddTraits(.isButton)
            .padding(.bottom, 6)
        }
    }
}

/// Список обновлений: что поменяется, ход и итог по каждой утилите. Закрыть можно в любой момент.
struct UpdateAllSheet: View {
    @ObservedObject private var updates = UpdateAll.shared
    @ObservedObject private var satellites = SatelliteRegistry.shared

    var body: some View {
        let rows = updates.rows
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Обновления утилит").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                if updates.checking { ProgressView().controlSize(.small) }
            }
            if satellites.catalogFailed { catalogNote }
            if rows.isEmpty {
                if !satellites.catalogFailed { nothing }
            } else {
                DSScroll(inset: DS.groupRadius) {
                    VStack(spacing: 8) {
                        ForEach(rows) { UpdateAllRowView(row: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
            footer(rows)
        }
        .padding(18)
        .frame(width: 520, height: 560)
    }

    private var catalogNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Не получилось проверить обновления").font(.system(size: 12.5, weight: .semibold))
                Text("Похоже, нет сети. Всё работает как работало").font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 6)
            DSButton("Проверить ещё раз", style: .secondary, small: true) { Task { await updates.check() } }.fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(.white.opacity(0.05)))
    }

    private var nothing: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
            Text("Всё обновлено").font(.system(size: 14, weight: .semibold))
            Text("У установленных утилит последние версии").font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity).padding(.top, 90)
    }

    @ViewBuilder
    private func footer(_ rows: [UpdateRow]) -> some View {
        if updates.running {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(updates.finished + 1) из \(updates.total)\(updates.current.map { ": \($0.title)" } ?? "")")
                    .font(.system(size: 12, weight: .semibold))
                StoreProgressBar(value: Double(updates.finished) / Double(max(updates.total, 1)))
                Text("Можно закрыть это окно: обновление продолжится").font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
            }
        }
        HStack(spacing: 8) {
            Text(summary).font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.55))
            Spacer()
            DSButton("Закрыть", style: .secondary, small: true) { updates.listShown = false }
                .keyboardShortcut(.cancelAction)
            let count = updates.startable.count
            if count > 0 && !updates.running {
                DSButton("Обновить всё (\(count))", icon: "arrow.down.circle.fill", style: .primary, small: true) { updates.start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var summary: String {
        guard !updates.running else { return "" }
        var parts: [String] = []
        if updates.doneCount > 0 { parts.append("Обновлено: \(updates.doneCount)") }
        if updates.failedCount > 0 { parts.append("не вышло: \(updates.failedCount)") }
        if updates.waitingCount > 0 { parts.append("ждут: \(updates.waitingCount)") }
        return parts.joined(separator: ", ")
    }
}

private struct UpdateAllRowView: View {
    let row: UpdateRow
    @ObservedObject private var updates = UpdateAll.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ModuleIconBadge(module: row.module, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.module.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(row.phase == .done ? row.to : "\(row.from) → \(row.to)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                status
                if row.phase != .done {
                    ForEach(Array(row.notes.enumerated()), id: \.offset) { _, note in
                        // `verbatim`: заметки из сети, разметку не разбираем.
                        Text(verbatim: "• \(note)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous).fill(.white.opacity(0.05)))
    }

    @ViewBuilder
    private var status: some View {
        switch row.phase {
        case .ready: EmptyView()
        case .queued: line("В очереди", .white.opacity(0.5))
        case .working: line("Обновляется…", .white.opacity(0.8))
        case .done: line("Обновлено", .green)
        case .failed(let message): line(message, .orange)
        case .waiting(let reason): line("Занята: \(reason). Обновится, когда освободится", .white.opacity(0.7))
        case .needsHub(let version): line("Сначала обнови Utilitumus: нужна версия \(version) или новее", .white.opacity(0.7))
        }
    }

    private func line(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.phase {
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            DSButton("Повторить", style: .secondary, small: true) { updates.retry(row.module) }.fixedSize()
        case .waiting: Image(systemName: "hourglass").foregroundStyle(.white.opacity(0.5))
        default: EmptyView()
        }
    }
}
