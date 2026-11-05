import AppKit
import SwiftUI

// Мелкие элементы и секции вкладки «Сессии». Стиль — как у «Обзора» и «Памяти»: строки в `DSSection`
// (`LoadLine` / `DSRow`), цифры моноширинные.

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
            .background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
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
        case .build: return "сборка"
        case .mcp: return "MCP"
        case .shell: return "шелл"
        case .other: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(kindName ?? " ").font(.caption).foregroundStyle(child.isHot ? Color.orange : .secondary)
                .frame(width: 68, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(child.name).lineLimit(1).truncationMode(.middle).help("\(child.name) · PID \(String(child.pid))")
                if let place = child.place { PlaceLabel(place: place, showHome: false) }
            }
            Spacer()
            Text(child.memMB.map { Fmt.mb($0) } ?? "—").monospacedDigit().frame(width: 76, alignment: .trailing)
            Text(Fmt.duration(child.age)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
            if child.stoppable {
                StopButton(help: "Остановить \(child.name)", action: onStop)
            } else {
                StopButton.gap
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: Потомки сессии

/// Курсор-рука над кликабельной строкой. Пара push/pop не должна разойтись, поэтому pop ещё и при исчезновении.
private struct PointerCursor: ViewModifier {
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !inside { NSCursor.pointingHand.push(); inside = true }
                if !hovering, inside { NSCursor.pop(); inside = false }
            }
            .onDisappear { if inside { NSCursor.pop(); inside = false } }
    }
}

/// Блок «Потомки» карточки сессии: по умолчанию свёрнут в одну строку-кнопку со сводкой; открывается
/// только нажатием. Открытыми показываем самых тяжёлых, остальных — за «Ещё N».
struct SessionChildrenBlock: View {
    let children: [SessionChild]
    @Binding var expanded: Bool
    var onStopChild: (SessionChild) -> Void
    @State private var showAll = false

    private static let visibleCount = 6
    private static let animation = Animation.easeOut(duration: 0.2)

    private var kidsMB: Double { children.reduce(0) { $0 + ($1.memMB ?? 0) } }

    var body: some View {
        Button {
            withAnimation(Self.animation) {
                expanded.toggle()
                if !expanded { showAll = false }
            }
        } label: {
            HStack(spacing: 8) {
                Text(expanded ? "Скрыть" : "Показать потомков (\(children.count))").font(.callout.weight(.medium))
                if let hot = hotLabel(children) { SessionChip(text: hot, tint: .orange).monospacedDigit() }
                Spacer()
                Text(Fmt.mb(kidsMB)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 12)
            }
            .contentShape(Rectangle())
            .hoverRow(selected: expanded)
        }
        .buttonStyle(.plain)
        .modifier(PointerCursor())
        .accessibilityLabel(expanded ? "Скрыть потомков" : "Показать потомков, \(children.count)")
        if expanded {
            let shown = showAll ? children : Array(children.prefix(Self.visibleCount))
            VStack(spacing: 0) {
                ForEach(shown) { c in SessionChildRow(child: c) { onStopChild(c) } }
                if shown.count < children.count {
                    Button {
                        withAnimation(Self.animation) { showAll = true }
                    } label: {
                        HStack {
                            Text("Ещё \(children.count - shown.count)").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .hoverRow()
                    }
                    .buttonStyle(.plain)
                    .modifier(PointerCursor())
                    .padding(.top, 4)
                }
            }
            .transition(.opacity)
        }
    }
}

// MARK: Карточка сессии

/// Сессия Claude Code одной строкой секции: состояние, последний шаг, потомки, команда resume, «Остановить…».
struct SessionCard: View {
    let session: ClaudeSession
    let now: TimeInterval
    @Binding var expanded: Bool
    var onStop: () -> Void
    var onStopChild: (SessionChild) -> Void

    var body: some View {
        let s = session
        LoadLine {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SessionStatusDot(status: s.status)
                    Text(s.name).font(DS.rowTitle).lineLimit(1).help(s.name)
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
                if !s.children.isEmpty { children }
                HStack(spacing: 8) {
                    // Команду копируют в терминал — повторная проверка sessionId даже при готовой строке.
                    if !s.resumeCommand.isEmpty, s.sessionID.map(TranscriptReader.isSafeID) == true {
                        Text(s.resumeCommand).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        DSButton("", icon: "doc.on.doc", style: .plain, small: true) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(s.resumeCommand, forType: .string)
                        }
                        .help("Скопировать команду")
                        .accessibilityLabel("Скопировать команду")
                    } else {
                        Text(s.hostApp == nil ? "продолжить нельзя: нет файла сессии" : "продолжает \(s.hostApp!).app")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    control
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var children: some View {
        SessionChildrenBlock(children: session.children, expanded: $expanded, onStopChild: onStopChild)
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
            DSButton("Остановить…", small: true, action: onStop)
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
        DSSection("Сессии Claude", trailing: SessionsHeader.summary(count: sessions.count, mb: sessions.reduce(0) { $0 + $1.memMB })) {
            if sessions.isEmpty { LoadEmpty(text: "Сессий Claude нет.") }
            ForEach(sessions) { s in
                LoadLine {
                    HStack(spacing: 10) {
                        SessionStatusDot(status: s.status)
                        Text(s.name).font(DS.rowTitle).lineLimit(1).help(s.isSelf ? "это текущая сессия — её отсюда не останавливают" : s.name)
                        Spacer()
                        SessionStatusLabel(status: s.status)
                        Text(Fmt.mb(s.memMB)).monospacedDigit()
                        if s.stoppable && !s.isSelf {
                            StopButton(help: "Остановить \(s.name)") { onStop(s) }
                        } else {
                            StopButton.gap
                        }
                    }
                }
            }
        }
    }
}

/// Подпись справа в заголовке секции: «3 · 4.2 GB».
enum SessionsHeader {
    static func summary(count: Int, mb: Double? = nil) -> String {
        if let mb, count > 0 { return "\(count) · \(Fmt.mb(mb))" }
        return String(count)
    }
}

/// Сводка сессий в «Обзоре»: строка на сессию, клик открывает вкладку «Сессии».
struct SessionsCompactSection: View {
    let sessions: [ClaudeSession]
    let now: TimeInterval
    @AppStorage("LoadTab") private var tabRaw = LoadTab.overview.rawValue

    var body: some View {
        DSSection("Сессии Claude", trailing: SessionsHeader.summary(count: sessions.count, mb: sessions.reduce(0) { $0 + $1.memMB })) {
            if sessions.isEmpty { LoadEmpty(text: "Сессий Claude нет.") }
            ForEach(sessions) { s in
                LoadLine {
                    Button {
                        tabRaw = LoadTab.sessions.rawValue
                    } label: {
                        HStack(spacing: 10) {
                            SessionStatusDot(status: s.status)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.name).font(DS.rowTitle).lineLimit(1)
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
            }
        }
    }
}

struct TerminalsSection: View {
    let hosts: [TerminalHost]
    var onStopShell: (TerminalShell) -> Void
    var onStopChild: (TerminalShell, SessionChild) -> Void

    var body: some View {
        let n = hosts.reduce(0) { $0 + $1.shells.count }
        DSSection("Терминалы", trailing: SessionsHeader.summary(count: n)) {
            if n == 0 { LoadEmpty(text: "Открытых шеллов нет.") }
            ForEach(hosts) { h in
                LoadLine {
                    Text("\(h.app) · host \(String(h.hostPid))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(h.shells) { sh in
                    LoadLine {
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
                                    StopButton.gap
                                }
                            }
                            ForEach(sh.children) { c in
                                SessionChildRow(child: c) { onStopChild(sh, c) }.padding(.leading, 24)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MuxSection: View {
    let tmux: TmuxInfo
    let docker: DockerInfo

    var body: some View {
        DSSection("tmux · Docker") {
            line("tmux", on: tmux.running, items: tmux.sessions.map { $0.name + ($0.attached ? " (подключён)" : "") })
            line("Docker", on: docker.running, items: docker.containers.map { c in
                let st = c.status.isEmpty ? c.state : c.status
                return c.name + (st.isEmpty ? "" : " — " + st)
            })
        }
    }

    private func line(_ name: String, on: Bool, items: [String]) -> some View {
        LoadLine {
            HStack(spacing: 8) {
                Circle().fill(on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(name).font(DS.rowTitle)
                Text(!on ? "не запущен" : items.isEmpty ? "запущен, пусто" : items.joined(separator: " · "))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }
}

struct OrphansSection: View {
    let orphans: [Advice.Orphan]
    let stoppable: Set<Int32>
    var onStop: (Advice.Orphan) -> Void

    var body: some View {
        DSSection("Сироты", trailing: SessionsHeader.summary(count: orphans.count, mb: orphans.reduce(0) { $0 + $1.memMB })) {
            if orphans.isEmpty { LoadEmpty(text: "Сирот нет.") }
            ForEach(orphans) { o in
                LoadLine {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(o.name).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text("PID \(String(o.pid)) · родитель завершился, launchd им не управляет")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let place = o.place { PlaceLabel(place: place) }
                        }
                        Spacer()
                        Text(Fmt.mb(o.memMB)).monospacedDigit()
                        Text(Fmt.duration(o.age)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
                        if stoppable.contains(o.pid) {
                            StopButton(help: "Остановить \(o.name)") { onStop(o) }
                        } else {
                            StopButton.gap
                        }
                    }
                }
            }
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
                    ShareBar(values: [p.memMB], maximum: total, width: 60)
                }
                .opacity(p.memMB > 0 ? 1 : 0.55)
            }
            Text("Dev-серверы (webpack, vite…) сюда не входят — это не ИИ.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
