import SwiftUI

// Вкладка «Сессии»: сессии Claude Code, вкладки терминалов, tmux, Docker и сироты. Данные собирает
// логика модуля по замеру ядра, здесь — только отрисовка. Остановка — через
// `requestStop(_ target:)` модели: подтверждение и защита — общие с остальными вкладками.

struct SessionsTab<Model: LoadModel>: View {
    @ObservedObject var store: Model
    let mode: LoadViewMode

    /// Раскрытые руками «Потомки» — только на время показа вкладки. Ключ — pid + время старта, чтобы
    /// переиспользованный pid не унаследовал чужое раскрытие. Нигде не сохраняется.
    @State private var opened: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
            if let s = store.measure {
                if mode == .full { full(s) } else { simple(s) }
                FooterSection(host: s.host, live: store.live)
            } else {
                ProgressView("Считаю…").frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .onDisappear { opened = [] }
    }

    @ViewBuilder
    private func full(_ s: LoadMeasure) -> some View {
        let d = s.sessions
        let now = s.timestamp.timeIntervalSince1970
        DSSection("Claude Code", trailing: SessionsHeader.summary(count: d.claude.count, mb: d.claude.reduce(0) { $0 + $1.memMB })) {
            if d.claude.isEmpty { LoadEmpty(text: "Сессий Claude нет.") }
            ForEach(d.claude) { session in
                SessionCard(session: session, now: now, expanded: expandedBinding(session),
                            onStop: { store.requestStop(.session(session.rowID)) },
                            onStopChild: { store.requestStop(.sessionChild(session: session.rowID, child: $0.rowID)) })
            }
        }
        TerminalsSection(hosts: d.terminals, onStopShell: { store.requestStop(.shell($0.rowID)) },
                         onStopChild: { store.requestStop(.shellChild(shell: $0.rowID, child: $1.rowID)) })
        MuxSection(tmux: d.tmux, docker: d.docker)
        OrphansSection(orphans: d.orphans, stoppable: d.stoppableOrphans, onStop: { store.requestStop(.orphan($0.rowID)) })
    }

    @ViewBuilder
    private func simple(_ s: LoadMeasure) -> some View {
        SessionsSimpleSection(sessions: s.sessions.claude) { store.requestStop(.session($0.rowID)) }
    }

    private func expandedBinding(_ s: ClaudeSession) -> Binding<Bool> {
        let key = "\(s.pid)-\(Int(s.startedAt))"
        return Binding(
            get: { opened.contains(key) },
            set: { on in if on { opened.insert(key) } else { opened.remove(key) } })
    }
}
