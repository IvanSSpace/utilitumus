import SwiftUI

// Вкладка «Сессии»: сессии Claude Code, вкладки терминалов, tmux, Docker и сироты. Данные собирает
// `SessionsBuilder` (Sessions/) по замеру ядра, здесь — только отрисовка. Остановка — через
// `LoadStore.requestStop(...)` (Sessions/SessionStop.swift): подтверждение и защита — общие с остальными вкладками.

struct SessionsTab: View {
    @ObservedObject var store: LoadStore
    let mode: LoadViewMode

    /// Раскрытые и свёрнутые руками «Потомки»: у кого есть горячий потомок, список открыт сам, пока его не свернули.
    @State private var opened: Set<Int32> = []
    @State private var closed: Set<Int32> = []

    var body: some View {
        Form {
            if let s = store.snapshot {
                if mode == .full { full(s) } else { simple(s) }
                FooterSection(snapshot: s)
            } else {
                ProgressView("Считаю…").frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func full(_ s: LoadSnapshot) -> some View {
        let d = s.sessions
        let now = s.timestamp.timeIntervalSince1970
        Section {
            if d.claude.isEmpty { EmptyNote(text: "Сессий Claude нет.") }
            ForEach(d.claude) { session in
                SessionCard(session: session, now: now, expanded: expandedBinding(session),
                            onStop: { store.requestStop(session: session) },
                            onStopChild: { store.requestStop(session: session, child: $0) })
            }
        } header: {
            SessionsHeader(title: "Claude Code", count: d.claude.count, mb: d.claude.reduce(0) { $0 + $1.memMB })
        }
        TerminalsSection(hosts: d.terminals, onStopShell: { store.requestStop(shell: $0) },
                         onStopChild: { store.requestStop(shell: $0, child: $1) })
        MuxSection(tmux: d.tmux, docker: d.docker)
        OrphansSection(orphans: d.orphans, stoppable: d.stoppableOrphans, onStop: { store.requestStop(orphan: $0) })
    }

    @ViewBuilder
    private func simple(_ s: LoadSnapshot) -> some View {
        SessionsSimpleSection(sessions: s.sessions.claude) { store.requestStop(session: $0) }
    }

    private func expandedBinding(_ s: ClaudeSession) -> Binding<Bool> {
        Binding(
            get: { opened.contains(s.pid) || (s.children.contains(where: \.isHot) && !closed.contains(s.pid)) },
            set: { on in
                if on { opened.insert(s.pid); closed.remove(s.pid) } else { opened.remove(s.pid); closed.insert(s.pid) }
            })
    }
}
