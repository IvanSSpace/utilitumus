import SwiftUI

/// Общие секции экрана «Нагрузка»: подсказки, «кто больше всех», диск, «что можно освободить», группы.

struct AdviceSection: View {
    let items: [AdviceItem]
    /// Сколько показать; nil — все.
    var limit: Int?
    var onStop: (Int32) -> Void
    var onMore: (() -> Void)?
    var moreTitle = ""

    var body: some View {
        Section {
            if items.isEmpty {
                EmptyNote(text: "Подсказок нет — всё спокойно.")
            }
            ForEach(Array(items.prefix(limit ?? items.count))) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SeverityBadge(severity: item.severity)
                        Text(item.title).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let pid = item.stopPid {
                        HStack {
                            Button("Остановить…") { onStop(pid) }
                            if item.savesMB > 0 {
                                Text("освободит \(Fmt.mb(item.savesMB))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if let limit, items.count > limit, let onMore {
                Button("ещё \(items.count - limit) — \(moreTitle)", action: onMore).buttonStyle(.link)
            }
        } header: {
            HStack {
                Text("Что выключить")
                if !items.isEmpty { Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit() }
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
        Section {
            if list.isEmpty { EmptyNote(text: "Пока нет данных.") }
            ForEach(Array(list)) { c in
                HStack {
                    Text(c.name).lineLimit(1)
                    Spacer()
                    Text(Fmt.mb(c.totalMB)).monospacedDigit()
                    ShareBar(values: [Double(c.totalMB)], maximum: maxV, colors: [.accentColor], width: 80)
                }
            }
        } header: {
            HStack { Text("Кто больше всех"); Spacer(); Text("в RAM + сжато").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// «Что можно освободить»: группы по убыванию, с кнопкой остановки или подсказкой.
struct FreeCandidatesSection: View {
    let map: MemoryMap
    let palette: LoadPalette
    var onStopGroup: (String) -> Void

    var body: some View {
        Section {
            ForEach(map.freeCandidates) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.color(forKey: c.key)).frame(width: 10, height: 10)
                        Text(c.name).lineLimit(1)
                        Spacer()
                        Text("\(Fmt.mb(c.ramMB)) + \(Fmt.mb(c.compressedMB))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        Text(Fmt.mb(c.totalMB)).fontWeight(.semibold).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    if let gid = c.stoppableGroup {
                        Button("Остановить группу…") { onStopGroup(gid) }
                            .controlSize(.small)
                    }
                    if !c.hint.isEmpty {
                        Text(c.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack { Text("Что можно освободить"); Spacer(); Text("в RAM + сжато").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Диск: износ SSD (только если установлен smartctl) и запись в своп.
struct DiskSection: View {
    let disk: DiskCard

    private func pct(_ v: Int?) -> String { v.map { "\($0) %" } ?? "нет данных" }

    var body: some View {
        Section {
            if disk.hasSmart {
                LabeledContent("Износ SSD") {
                    Text("\(pct(disk.wearPct)) · записано \(disk.writtenTB.map { Fmt.compact($0) + " TB" } ?? "—") · запас \(pct(disk.sparePct))")
                        .monospacedDigit()
                }
                if let errors = disk.mediaErrors, errors > 0 {
                    Label("Ошибок чтения/записи: \(errors) — сделай резервную копию", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            LabeledContent("Запись в своп") {
                let day = "≈\(Fmt.compact(disk.swapGBPerDay)) GB/день"
                let share = disk.swapSharePct.map { " (\($0) % всей записи)" } ?? ""
                Text(day + share).monospacedDigit()
            }
            LabeledContent(disk.swap24SpanHours.map { "За последние \(Int(min(24, $0.rounded()))) ч" } ?? "За сутки") {
                if let gb = disk.swapWritten24hGB, let span = disk.swap24SpanHours {
                    // История короче суток: число — за то, что накоплено, а не пересчёт на сутки.
                    Text(Fmt.compact(span < 23 ? gb * span / 24 : gb) + " GB").monospacedDigit()
                } else {
                    Text("копится").foregroundStyle(.secondary)
                }
            }
            Text("Своп опасен не износом диска, а тормозами.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Диск")
                Spacer()
                Text([disk.model, disk.sizeGB.map { "\($0) GB" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
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
    var onStopProcess: (Int32) -> Void
    var onStopGroup: (String) -> Void

    var body: some View {
        let maxMem = Double(groups.map(\.memMB).max() ?? 1)
        Section {
            if groups.isEmpty { EmptyNote(text: "Сейчас таких процессов нет.") }
            ForEach(groups) { g in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(g.id) },
                    set: { if $0 { expanded.insert(g.id) } else { expanded.remove(g.id) } })
                ) {
                    GroupBody(group: g, snapshot: snapshot, showAll: Binding(
                        get: { showAll.contains(g.id) },
                        set: { if $0 { showAll.insert(g.id) } else { showAll.remove(g.id) } }),
                        onStopProcess: onStopProcess, onStopGroup: onStopGroup)
                } label: {
                    HStack(spacing: 8) {
                        Text(g.name).lineLimit(1).help(g.path ?? "")
                        Text("\(g.count) проц.").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Text(Fmt.mb(g.memMB)).monospacedDigit()
                        Text(Fmt.percent(Double(g.memMB), of: Double(snapshot.memory.totalMB)))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                        ShareBar(values: [Double(g.memMB)], maximum: maxMem, colors: [.accentColor], width: 60)
                    }
                }
            }
        } header: {
            HStack {
                Text(kind.title)
                Text("\(groups.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(Fmt.mb(groups.reduce(0) { $0 + $1.memMB })).monospacedDigit()
            }
        }
    }
}

private struct GroupBody: View {
    let group: ProcessGroup
    let snapshot: LoadSnapshot
    @Binding var showAll: Bool
    var onStopProcess: (Int32) -> Void
    var onStopGroup: (String) -> Void

    var body: some View {
        let rows = showAll ? group.members : Array(group.top)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                // В «top» память подогнана под итог группы, в полном списке — как есть.
                ProcessRow(member: m, snapshot: snapshot, mb: showAll ? m.memMB : group.topMB[safe: i], onStop: onStopProcess)
            }
            if group.restCount > 0 || showAll {
                HStack {
                    Text(showAll ? "всего \(Fmt.plural(group.count, "процесс", "процесса", "процессов"))"
                         : "ещё \(Fmt.plural(group.restCount, "процесс", "процесса", "процессов")) — \(Fmt.mb(group.restMB))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(showAll ? "свернуть" : "показать все") { showAll.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.top, 6)
            }
            if group.kind == .project || group.kind == .app, group.stoppableMB > 0 {
                Button("Остановить группу…") { onStopGroup(group.id) }
                    .controlSize(.small)
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
        .padding(.vertical, 4)
    }
}

private struct ProcessRow: View {
    let member: GroupMember
    let snapshot: LoadSnapshot
    let mb: Int?
    var onStop: (Int32) -> Void

    private static let kindNames: [ProcessKind: String] = [.devServer: "dev-сервер", .mcp: "MCP", .shell: "шелл"]

    var body: some View {
        let p = snapshot.procs[member.pid]
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
                Color.clear.frame(width: 18, height: 1)
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
