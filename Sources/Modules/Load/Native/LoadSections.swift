import SwiftUI

/// Общие секции экрана «Нагрузка»: подсказки, «кто больше всех», диск, «что можно освободить», группы.

struct AdviceSection: View {
    let items: [AdviceItem]
    /// Сколько показать; nil — все.
    var limit: Int?
    var onStop: (Int32) -> Void
    var onMore: (() -> Void)?
    var moreTitle = ""

    private func icon(_ s: AdviceSeverity) -> String {
        switch s {
        case .high: return "exclamationmark.triangle.fill"
        case .med: return "lightbulb.fill"
        case .low: return "info.circle.fill"
        }
    }

    var body: some View {
        DSSection("Что выключить", trailing: items.isEmpty ? nil : String(items.count)) {
            if items.isEmpty {
                LoadEmpty(text: "Подсказок нет — всё спокойно.")
            }
            ForEach(Array(items.prefix(limit ?? items.count))) { item in
                DSRow(icon: icon(item.severity), title: item.title, subtitle: item.detail) {
                    HStack(spacing: 8) {
                        SeverityBadge(severity: item.severity)
                        if let pid = item.stopPid {
                            if item.savesMB > 0 {
                                Text("−\(Fmt.mb(item.savesMB))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                                    .help("Освободит \(Fmt.mb(item.savesMB))")
                            }
                            DSButton("Остановить…", small: true) { onStop(pid) }
                        }
                    }
                }
            }
            if let limit, items.count > limit, let onMore {
                LoadLine {
                    DSButton("ещё \(items.count - limit) — \(moreTitle)", icon: "chevron.right", style: .plain, small: true, action: onMore)
                }
            }
        }
    }
}

/// «Кто больше всех»: пять программ по RAM + сжато, каждая одним итогом.
struct TopProgramsSection: View {
    let map: MemoryMap

    var body: some View {
        let list = map.freeCandidates.filter { $0.key != "macos" }.sorted { $0.totalMB > $1.totalMB }.prefix(5)
        let maxV = Double(list.map(\.totalMB).max() ?? 1)
        DSSection("Кто больше всех", trailing: "RAM + сжато") {
            if list.isEmpty { LoadEmpty(text: "Пока нет данных.") }
            ForEach(Array(list)) { c in
                DSRow(title: c.name) {
                    Text(Fmt.mb(c.totalMB)).monospacedDigit()
                    ShareBar(values: [Double(c.totalMB)], maximum: maxV, width: 80)
                }
            }
        }
    }
}

/// «Что можно освободить»: группы по убыванию, с кнопкой остановки или подсказкой.
struct FreeCandidatesSection: View {
    let map: MemoryMap
    let palette: LoadPalette
    var onStopGroup: (String) -> Void

    var body: some View {
        DSSection("Что можно освободить", trailing: "RAM + сжато") {
            ForEach(map.freeCandidates) { c in
                LoadLine {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.color(forKey: c.key)).frame(width: 10, height: 10)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name).font(DS.rowTitle).lineLimit(1)
                            if !c.hint.isEmpty {
                                Text(c.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.mb(c.totalMB)).fontWeight(.semibold).monospacedDigit()
                            Text("\(Fmt.mb(c.ramMB)) + \(Fmt.mb(c.compressedMB))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let gid = c.stoppableGroup {
                            DSButton("Остановить…", small: true) { onStopGroup(gid) }
                                .help("Остановить группу")
                        }
                    }
                }
            }
        }
    }
}

/// Диск: износ SSD (только если установлен smartctl) и запись в своп.
struct DiskSection: View {
    let disk: DiskCard

    private func pct(_ v: Int?) -> String { v.map { "\($0) %" } ?? "нет данных" }

    var body: some View {
        let model = [disk.model, disk.sizeGB.map { "\($0) GB" }].compactMap { $0 }.joined(separator: " · ")
        DSSection("Диск", trailing: model.isEmpty ? nil : model) {
            if disk.hasSmart {
                DSRow(icon: "internaldrive.fill", title: "Износ SSD") {
                    Text("\(pct(disk.wearPct)) · записано \(disk.writtenTB.map { Fmt.compact($0) + " TB" } ?? "—") · запас \(pct(disk.sparePct))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if let errors = disk.mediaErrors, errors > 0 {
                    LoadLine {
                        Label("Ошибок чтения/записи: \(errors) — сделай резервную копию", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            DSRow(icon: disk.hasSmart ? nil : "internaldrive.fill", title: "Запись в своп") {
                let day = "≈\(Fmt.compact(disk.swapGBPerDay)) GB/день"
                let share = disk.swapSharePct.map { " (\($0) % всей записи)" } ?? ""
                Text(day + share).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            DSRow(title: disk.swap24SpanHours.map { "За последние \(Int(min(24, $0.rounded()))) ч" } ?? "За сутки") {
                if let gb = disk.swapWritten24hGB, let span = disk.swap24SpanHours {
                    // История короче суток: число — за то, что накоплено, а не пересчёт на сутки.
                    Text(Fmt.compact(span < 23 ? gb * span / 24 : gb) + " GB").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("копится").font(.callout).foregroundStyle(.secondary)
                }
            }
            LoadNote(text: "Своп опасен не износом диска, а тормозами.")
        }
    }
}

/// Одна строка про диск для «Просто».
func simpleDiskLine(_ d: DiskCard) -> String {
    var parts: [String] = []
    if let wear = d.wearPct { parts.append("износ \(wear) %") }
    parts.append("своп ≈\(Fmt.compact(d.swapGBPerDay)) GB/день")
    return "Диск: " + parts.joined(separator: " · ")
}

// MARK: Группы

struct GroupsSection: View {
    let kind: GroupKind
    let groups: [ProcessGroup]
    let snapshot: LoadSnapshot
    @Binding var expanded: Set<String>
    @Binding var showAll: Set<String>
    /// Виды, у которых показан весь список, а не первые `Self.initialLimit` групп.
    @Binding var fullKinds: Set<GroupKind>
    var onStopProcess: (Int32) -> Void
    var onStopGroup: (String) -> Void

    /// Сколько групп каждого вида видно сразу: сотни строк разом перерисовываются заметно.
    static let initialLimit = 15

    var body: some View {
        let maxMem = Double(groups.map(\.memMB).max() ?? 1)
        let totalRAM = snapshot.memory.totalMB
        let all = fullKinds.contains(kind)
        // Раскрытые группы остаются на виду, даже если уехали ниже первых строк.
        let shown = all ? groups : groups.enumerated().filter { $0.offset < Self.initialLimit || expanded.contains($0.element.id) }.map(\.element)
        DSSection(kind.title, trailing: "\(groups.count) · " + Fmt.mb(groups.reduce(0) { $0 + $1.memMB })) {
            if groups.isEmpty { LoadEmpty(text: "Сейчас таких процессов нет.") }
            ForEach(shown) { g in
                let open = expanded.contains(g.id)
                LoadLine {
                    GroupHeader(group: g, totalRAM: totalRAM, maxMem: maxMem, open: open) {
                        if open { expanded.remove(g.id) } else { expanded.insert(g.id) }
                    }
                }
                if open {
                    LoadLine(divider: false) {
                        GroupBody(group: g, procs: snapshot.procs, showAll: Binding(
                            get: { showAll.contains(g.id) },
                            set: { if $0 { showAll.insert(g.id) } else { showAll.remove(g.id) } }),
                            onStopProcess: onStopProcess, onStopGroup: onStopGroup)
                    }
                    .padding(.top, -9)
                }
            }
            if groups.count > Self.initialLimit {
                LoadLine {
                    DSButton(all ? "свернуть до \(Self.initialLimit)" : "ещё \(groups.count - shown.count) — показать все",
                             icon: all ? "chevron.up" : "chevron.down", style: .plain, small: true) {
                        if all { fullKinds.remove(kind) } else { fullKinds.insert(kind) }
                    }
                }
            }
        }
    }
}

/// Строка группы: имя, число процессов, память, доля, полоса.
private struct GroupHeader: View {
    let group: ProcessGroup
    let totalRAM: Int
    let maxMem: Double
    let open: Bool
    var toggle: () -> Void

    var body: some View {
        let g = group
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(g.name).font(DS.rowTitle).lineLimit(1).help(g.path ?? "")
                Text("\(g.count) проц.").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(Fmt.mb(g.memMB)).monospacedDigit()
                Text(Fmt.percent(Double(g.memMB), of: Double(totalRAM)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                ShareBar(values: [Double(g.memMB)], maximum: maxMem, width: 60)
                DisclosureChevron(open: open)
            }
            .contentShape(Rectangle())
            .hoverRow(selected: open)
        }
        .buttonStyle(.plain)
    }
}

private struct GroupBody: View {
    let group: ProcessGroup
    /// Только процессы: из всего снимка группе нужны лишь они.
    let procs: [Int32: LoadProcess]
    @Binding var showAll: Bool
    var onStopProcess: (Int32) -> Void
    var onStopGroup: (String) -> Void

    var body: some View {
        let rows = showAll ? group.members : Array(group.top)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                // В «top» память подогнана под итог группы, в полном списке — как есть.
                ProcessRow(member: m, process: procs[m.pid], mb: showAll ? m.memMB : group.topMB[safe: i], onStop: onStopProcess)
            }
            if group.restCount > 0 || showAll {
                HStack {
                    Text(showAll ? "всего \(Fmt.plural(group.count, "процесс", "процесса", "процессов"))"
                         : "ещё \(Fmt.plural(group.restCount, "процесс", "процесса", "процессов")) — \(Fmt.mb(group.restMB))")
                        .font(.caption).foregroundStyle(.secondary)
                    DSButton(showAll ? "свернуть" : "показать все", style: .plain, small: true) { showAll.toggle() }
                }
                .padding(.top, 6)
            }
            if group.kind == .project || group.kind == .app, group.stoppableMB > 0 {
                DSButton("Остановить группу…", small: true) { onStopGroup(group.id) }
                    .padding(.top, 8)
            }
            if !group.hints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Что можно сделать").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.hints) { h in
                        (Text(h.title).fontWeight(.semibold) + Text(" — \(h.how)") + Text(h.savesMB > 0 ? " ≈ \(Fmt.mb(h.savesMB))" : ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct ProcessRow: View {
    let member: GroupMember
    let process: LoadProcess?
    let mb: Int?
    var onStop: (Int32) -> Void

    private static let kindNames: [ProcessKind: String] = [.devServer: "dev-сервер", .build: "сборка", .mcp: "MCP", .shell: "шелл"]

    var body: some View {
        let p = process
        HStack(spacing: 8) {
            Text(String(member.pid)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.map { Kinds.label($0) } ?? "—").lineLimit(1).truncationMode(.middle)
                if let why = whyText(p) {
                    Text(why).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let cpu = p?.cpuPercent, cpu >= 1 {
                Text("\(Int(cpu.rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("Загрузка процессора (100% = одно ядро)")
            }
            Text(mb.map { Fmt.mb($0) } ?? "—").monospacedDigit().frame(width: 76, alignment: .trailing)
            if member.stoppable {
                StopButton(help: "Остановить") { onStop(member.pid) }
            } else {
                StopButton.gap
            }
        }
        .padding(.vertical, 2)
    }

    private func whyText(_ p: LoadProcess?) -> String? {
        guard let p else { return nil }
        if Kinds.isClaude(p) { return "сессия Claude" }
        return Self.kindNames[Kinds.childKind(p)]
    }
}
