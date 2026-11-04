import Foundation

/// Остановка со своими словами для сессий, шеллов и сирот: те же правила и тот же план, что у
/// `LoadStore.requestStop(process:)`, но подтверждение называет сессию по имени и напоминает, как её продолжить.
@MainActor
extension LoadStore {
    /// `head` заменяет начало «Остановит <команда>»; `note` — хвост перед «Сначала SIGTERM».
    func requestStop(process pid: Int32, title: String, head: String, note: String = "") {
        guard let snapshot = latest, var plan = snapshot.stopPlan(process: pid) else { return }
        if let p = snapshot.procs[pid] {
            plan.message = plan.message.replacingOccurrences(of: "Остановит \(Kinds.label(p))", with: head)
        }
        if !note.isEmpty { plan.message += " " + note }
        plan.title = title
        pendingStop = plan
    }

    func requestStop(session s: ClaudeSession) {
        var note = s.resumeCommand.isEmpty ? "sessionId неизвестен — продолжить через --resume не выйдет." : "Продолжить потом: \(s.resumeCommand)."
        if s.status.isWorking { note += " Сессия сейчас работает — остановка прервёт задачу." }
        requestStop(process: s.pid, title: "Остановить сессию \(s.name)", head: "Остановит сессию Claude «\(s.name)»", note: note)
    }

    func requestStop(child c: SessionChild, owner: String) {
        let what = c.kind == .devServer ? "dev-сервер" : "процесс"
        let age = c.age > 0 ? ", работает \(Fmt.age(c.age))" : ""
        requestStop(process: c.pid, title: "Остановить \(c.name)", head: "Остановит \(c.name) — \(what) \(owner)\(age)")
    }

    func requestStop(session s: ClaudeSession, child c: SessionChild) {
        requestStop(child: c, owner: "сессии «\(s.name)»")
        appendNote("Сама сессия останется.")
    }

    func requestStop(shell sh: TerminalShell, child c: SessionChild) {
        requestStop(child: c, owner: "во вкладке \(Self.tab(sh))")
        appendNote("Шелл останется.")
    }

    func requestStop(shell sh: TerminalShell) {
        let label = Self.tab(sh) + (sh.project.map { " (\($0))" } ?? "")
        guard !sh.sessions.isEmpty else {
            requestStop(process: sh.pid, title: "Закрыть шелл \(label)", head: "Закроет шелл \(label)")
            return
        }
        let names = sh.sessions.map { "«\($0.name)»" }.joined(separator: ", ")
        var note = sh.sessions.first.map { $0.resumeCommand.isEmpty ? "sessionId неизвестен — продолжить через --resume не выйдет." : "Продолжить сессию потом: \($0.resumeCommand)." } ?? ""
        note += sh.sessions.contains { $0.status.isWorking } ? " Сессия сейчас работает — остановка прервёт задачу."
            : " Вместе с шеллом завершится сессия Claude \(names)."
        requestStop(process: sh.pid, title: "Закрыть шелл \(label)", head: "Закроет шелл \(label) и убьёт сессию Claude \(names)", note: note)
    }

    func requestStop(orphan o: Advice.Orphan) {
        requestStop(process: o.pid, title: "Остановить \(o.name)",
                    head: "Остановит \(o.name): родитель завершился, работает \(Fmt.age(o.age))")
    }

    private func appendNote(_ s: String) {
        pendingStop?.message += " " + s
    }

    private static func tab(_ sh: TerminalShell) -> String { sh.tty ?? String(sh.pid) }
}
