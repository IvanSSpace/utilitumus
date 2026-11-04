import AppKit
import SwiftUI

// Мелкие элементы и секции вкладки «Сессии». Стиль — как у «Обзора» и «Памяти»: строки в `Section`,
// системные цвета и шрифты, цифры моноширинные.

/// Точка статуса сессии; со словом — `SessionStatusLabel`.
struct SessionStatusDot: View {
    let status: SessionStatus

    private var color: Color {
        switch status {
        case .busy, .shell: return .green
        case .idle: return .secondary
        case .unknown: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).help(status.title)
    }
}

struct SessionStatusLabel: View {
    let status: SessionStatus

    var body: some View {
        Text(status.title).font(.caption).foregroundStyle(.secondary).fixedSize()
    }
}

/// Капсула с коротким текстом.
struct SessionChip: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(tint ?? .secondary)
    }
}

/// «node 1.2 GB» — самый тяжёлый из «горячих» потомков.
func hotLabel(_ kids: [SessionChild]) -> String? {
    guard let top = kids.filter(\.isHot).max(by: { ($0.memMB ?? 0) < ($1.memMB ?? 0) }) else { return nil }
    return "\(top.name.split(separator: " ").first.map(String.init) ?? "потомок") \(top.memMB.map { Fmt.mb($0) } ?? "—")"
}

private func since(_ ts: TimeInterval?, now: TimeInterval) -> String? {
    ts.map { Fmt.duration(max(0, now - $0)) }
}

/// «~/…» вместо /Users/имя/….
func homeShort(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let home = NSHomeDirectory()
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

// MARK: Потомок

struct SessionChildRow: View {
    let child: SessionChild
    var onStop: () -> Void

    private var kindName: String? {
        switch child.kind {
        case .devServer: return "dev-сервер"
        case .mcp: return "MCP"
        case .shell: return "шелл"
        case .other: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(kindName ?? " ").font(.caption).foregroundStyle(child.isHot ? Color.orange : .secondary)
                .frame(width: 68, alignment: .leading)
            Text(child.name).lineLimit(1).truncationMode(.middle).help("\(child.name) · PID \(String(child.pid))")
            Spacer()
            Text(child.memMB.map { Fmt.mb($0) } ?? "—").monospacedDigit().frame(width: 76, alignment: .trailing)
            Text(Fmt.duration(child.age)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
            if child.stoppable {
                StopButton(help: "Остановить \(child.name)", action: onStop)
            } else {
                Color.clear.frame(width: 18, height: 1)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: Карточка сессии

struct SessionCard: View {
    let session: ClaudeSession
    let now: TimeInterval
    @Binding var expanded: Bool
    var onStop: () -> Void
    var onStopChild: (SessionChild) -> Void

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SessionStatusDot(status: s.status)
                Text(s.name).font(.headline).lineLimit(1).help(s.name)
                // Имя вида «my-project-b9» уже с проектом — чип прячем.
                if let project = s.project, !s.name.hasPrefix(project) {
                    SessionChip(text: project).help(s.cwd)
                }
                SessionStatusLabel(status: s.status)
                Spacer()
                Text(Fmt.mb(s.memMB)).fontWeight(.semibold).monospacedDigit().help("вместе с потомками")
            }
            // Последний шаг и запрос — из хвоста транскрипта.
            if !s.activity.lastAction.isEmpty {
                HStack(spacing: 4) {
                    Text(s.status.isWorking ? "Сейчас:" : "Последнее:").foregroundStyle(.secondary)
                    Text(s.activity.lastAction).lineLimit(1).truncationMode(.tail).help(s.activity.lastAction)
                    if let ago = since(s.activity.lastActionTS, now: now) {
                        Text("· \(ago) назад").foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    }
                }
                .font(.callout)
            }
            if !s.activity.lastPrompt.isEmpty {
                Text("Запрос: \(s.activity.lastPrompt)").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).help(s.activity.lastPrompt)
            }
            Text(meta).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            if !s.children.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(spacing: 0) {
                        ForEach(s.children) { c in SessionChildRow(child: c) { onStopChild(c) } }
                    }
                    .padding(.top, 2)
                } label: {
                    HStack(spacing: 8) {
                        Text("Потомки").font(.callout)
                        Text("\(s.children.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        if let hot = hotLabel(s.children) { SessionChip(text: hot, tint: .orange).monospacedDigit() }
                        Spacer()
                        Text(Fmt.mb(s.kidsMB)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            HStack(spacing: 8) {
                // Команду копируют в терминал — повторная проверка sessionId даже при готовой строке.
                if !s.resumeCommand.isEmpty, s.sessionID.map(TranscriptReader.isSafeID) == true {
                    Text(s.resumeCommand).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s.resumeCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Скопировать команду")
                } else {
                    Text(s.hostApp == nil ? "продолжить нельзя: нет файла сессии" : "продолжает \(s.hostApp!).app")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                control
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private var meta: String {
        let s = session
        var parts = ["PID \(s.pid)"]
        if s.startedAt > 0 { parts.append("возраст \(Fmt.duration(max(0, now - s.startedAt)))") }
        parts.append(s.lastActivity > 0 ? "активность \(Fmt.duration(max(0, now - s.lastActivity))) назад" : "активность —")
        if !s.children.isEmpty { parts.append("сам \(Fmt.mb(max(0, s.memMB - s.kidsMB)))") }
        if !s.version.isEmpty { parts.append("v\(s.version)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var control: some View {
        if session.isSelf {
            SessionChip(text: "это текущая сессия")
        } else if session.stoppable {
            Button("Остановить…", action: onStop)
        } else if let app = session.hostApp {
            Text("сессией управляет \(app).app").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("не управляется").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Секции

struct SessionsSimpleSection: View {
    let sessions: [ClaudeSession]
    var onStop: (ClaudeSession) -> Void

    var body: some View {
        Section {
            if sessions.isEmpty { EmptyNote(text: "Сессий Claude нет.") }
            ForEach(sessions) { s in
                HStack(spacing: 10) {
                    SessionStatusDot(status: s.status)
                    Text(s.name).lineLimit(1).help(s.isSelf ? "это текущая сессия — её отсюда не останавливают" : s.name)
                    Spacer()
                    SessionStatusLabel(status: s.status)
                    Text(Fmt.mb(s.memMB)).monospacedDigit()
                    if s.stoppable && !s.isSelf {
                        StopButton(help: "Остановить \(s.name)") { onStop(s) }
                    } else {
                        Color.clear.frame(width: 18, height: 1)
                    }
                }
            }
        } header: {
            SessionsHeader(title: "Сессии Claude", count: sessions.count, mb: sessions.reduce(0) { $0 + $1.memMB })
        }
    }
}

struct SessionsHeader: View {
    let title: String
    let count: Int
    var mb: Double?

    var body: some View {
        HStack {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if let mb, count > 0 { Text(Fmt.mb(mb)).monospacedDigit() }
        }
    }
}

/// Сводка сессий в «Обзоре»: строка на сессию, клик открывает вкладку «Сессии».
struct SessionsCompactSection: View {
    let sessions: [ClaudeSession]
    let now: TimeInterval
    @AppStorage("LoadTab") private var tabRaw = LoadTab.overview.rawValue

    var body: some View {
        Section {
            if sessions.isEmpty { EmptyNote(text: "Сессий Claude нет.") }
            ForEach(sessions) { s in
                Button {
                    tabRaw = LoadTab.sessions.rawValue
                } label: {
                    HStack(spacing: 10) {
                        SessionStatusDot(status: s.status)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.name).lineLimit(1)
                            if !s.activity.lastAction.isEmpty {
                                Text(s.activity.lastAction).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let hot = hotLabel(s.children) { SessionChip(text: hot, tint: .orange).monospacedDigit() }
                        Text(Fmt.mb(s.memMB)).monospacedDigit()
                        Text(Fmt.duration(max(0, now - s.startedAt))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        DisclosureChevron(open: false)
                    }
                    .contentShape(Rectangle())
                    .hoverRow()
                }
                .buttonStyle(.plain)
                .help(s.name + (s.activity.lastAction.isEmpty ? "" : "\n" + s.activity.lastAction))
            }
        } header: {
            SessionsHeader(title: "Сессии Claude", count: sessions.count, mb: sessions.reduce(0) { $0 + $1.memMB })
        }
    }
}

struct TerminalsSection: View {
    let hosts: [TerminalHost]
    var onStopShell: (TerminalShell) -> Void
    var onStopChild: (TerminalShell, SessionChild) -> Void

    var body: some View {
        let n = hosts.reduce(0) { $0 + $1.shells.count }
        Section {
            if n == 0 { EmptyNote(text: "Открытых шеллов нет.") }
            ForEach(hosts) { h in
                Text("\(h.app) · host \(String(h.hostPid))").font(.caption).foregroundStyle(.secondary)
                ForEach(h.shells) { sh in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(sh.tty ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sh.project ?? homeShort(sh.cwd) ?? "—").lineLimit(1)
                                if sh.project != nil, let cwd = homeShort(sh.cwd) {
                                    Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .help(sh.cwd ?? "")
                            Spacer()
                            if !sh.foreground.isEmpty {
                                SessionChip(text: sh.foreground).help("на переднем плане")
                            }
                            if sh.stoppable {
                                StopButton(help: "Закрыть шелл \(sh.tty ?? String(sh.pid))") { onStopShell(sh) }
                            } else {
                                Color.clear.frame(width: 18, height: 1)
                            }
                        }
                        ForEach(sh.children) { c in
                            SessionChildRow(child: c) { onStopChild(sh, c) }.padding(.leading, 24)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        } header: {
            SessionsHeader(title: "Терминалы", count: n)
        }
    }
}

struct MuxSection: View {
    let tmux: TmuxInfo
    let docker: DockerInfo

    var body: some View {
        Section("tmux · Docker") {
            line("tmux", on: tmux.running, items: tmux.sessions.map { $0.name + ($0.attached ? " (подключён)" : "") })
            line("Docker", on: docker.running, items: docker.containers.map { c in
                let st = c.status.isEmpty ? c.state : c.status
                return c.name + (st.isEmpty ? "" : " — " + st)
            })
        }
    }

    private func line(_ name: String, on: Bool, items: [String]) -> some View {
        HStack(spacing: 8) {
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(name)
            Text(!on ? "не запущен" : items.isEmpty ? "запущен, пусто" : items.joined(separator: " · "))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}

struct OrphansSection: View {
    let orphans: [Advice.Orphan]
    let stoppable: Set<Int32>
    var onStop: (Advice.Orphan) -> Void

    var body: some View {
        Section {
            if orphans.isEmpty { EmptyNote(text: "Сирот нет.") }
            ForEach(orphans) { o in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(o.name).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text("PID \(String(o.pid)) · родитель завершился, launchd им не управляет")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.mb(o.memMB)).monospacedDigit()
                    Text(Fmt.duration(o.age)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
                    if stoppable.contains(o.pid) {
                        StopButton(help: "Остановить \(o.name)") { onStop(o) }
                    } else {
                        Color.clear.frame(width: 18, height: 1)
                    }
                }
            }
        } header: {
            SessionsHeader(title: "Сироты", count: orphans.count, mb: orphans.reduce(0) { $0 + $1.memMB })
        }
    }
}

// MARK: Карточка «ИИ»

/// Плитка «ИИ» в итогах «Обзора»: сколько памяти держит ИИ; клик раскрывает разбор.
struct AIMemoryKPI: View {
    let ai: AIMemory
    @Binding var open: Bool

    var body: some View {
        Button {
            open.toggle()
        } label: {
            KPITile(title: "ИИ", value: Fmt.gb(ai.totalMB), unit: "GB",
                    subtitle: Fmt.plural(ai.count, "процесс", "процесса", "процессов"))
                .overlay(alignment: .topTrailing) { DisclosureChevron(open: open) }
                .contentShape(Rectangle())
                .hoverRow(selected: open)
        }
        .buttonStyle(.plain)
        .help("Сколько памяти ест ИИ — нажми, чтобы разобрать")
    }
}

/// Разбор карточки «ИИ»: части и доли. Как `DrillPanel` у полосы памяти.
struct AIDrillPanel: View {
    let ai: AIMemory

    var body: some View {
        let total = max(1, ai.totalMB)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Разбор: память ИИ").font(.subheadline.weight(.semibold))
                Spacer()
                Text(Fmt.mb(ai.totalMB)).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(ai.parts) { p in
                HStack {
                    Text(p.label).lineLimit(1)
                    Text(p.count > 0 ? "\(p.count) проц." : "не запущено").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(Fmt.mb(p.memMB)).monospacedDigit()
                    ShareBar(values: [p.memMB], maximum: total, colors: [.accentColor], width: 60)
                }
                .opacity(p.memMB > 0 ? 1 : 0.55)
            }
            Text("Dev-серверы (webpack, vite…) сюда не входят — это не ИИ.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
