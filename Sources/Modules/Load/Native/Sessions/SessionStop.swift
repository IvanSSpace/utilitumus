import Foundation

/// План остановки по цели. У сессий, шеллов и сирот правила и план те же, что у процесса,
/// но подтверждение называет сессию по имени и напоминает, как её продолжить.
@MainActor
extension LoadStore {
    func stopPlan(for target: LoadStopTarget) -> StopPlan? {
        let d = snapshot?.sessions
        let shells = d?.terminals.flatMap(\.shells) ?? []
        switch target {
        case .process(let id):
            return latest?.stopPlan(process: id.pid)
        case .group(let id):
            return latest?.stopPlan(group: id)
        case .session(let id):
            return d?.claude.first { $0.pid == id.pid }.flatMap { plan(session: $0) }
        case .sessionChild(let owner, let child):
            guard let s = d?.claude.first(where: { $0.pid == owner.pid }),
                  let c = s.children.first(where: { $0.pid == child.pid }) else { return nil }
            return plan(child: c, owner: "сессии «\(s.name)»", note: "Сама сессия останется.")
        case .shell(let id):
            return shells.first { $0.pid == id.pid }.flatMap { plan(shell: $0) }
        case .shellChild(let owner, let child):
            guard let sh = shells.first(where: { $0.pid == owner.pid }),
                  let c = sh.children.first(where: { $0.pid == child.pid }) else { return nil }
            return plan(child: c, owner: "во вкладке \(Self.tab(sh))", note: "Шелл останется.")
        case .orphan(let id):
            return d?.orphans.first { $0.pid == id.pid }.flatMap { plan(orphan: $0) }
        }
    }

    /// `head` заменяет начало «Остановит <команда>»; `note` — хвост перед «Сначала SIGTERM».
    private func plan(process pid: Int32, title: String, head: String, note: String = "") -> StopPlan? {
        guard let snapshot = latest, var plan = snapshot.stopPlan(process: pid) else { return nil }
        if let p = snapshot.procs[pid] {
            plan.message = plan.message.replacingOccurrences(of: "Остановит \(Kinds.label(p))", with: head)
        }
        if !note.isEmpty { plan.message += " " + note }
        plan.title = title
        return plan
    }

    private func plan(session s: ClaudeSession) -> StopPlan? {
        var note = s.resumeCommand.isEmpty ? "sessionId неизвестен — продолжить через --resume не выйдет." : "Продолжить потом: \(s.resumeCommand)."
        if s.status.isWorking { note += " Сессия сейчас работает — остановка прервёт задачу." }
        return plan(process: s.pid, title: "Остановить сессию \(s.name)", head: "Остановит сессию Claude «\(s.name)»", note: note)
    }

    private func plan(child c: SessionChild, owner: String, note: String) -> StopPlan? {
        let what = c.kind == .devServer ? "dev-сервер" : c.kind == .build ? "сборку" : "процесс"
        let age = c.age > 0 ? ", работает \(Fmt.age(c.age))" : ""
        return plan(process: c.pid, title: "Остановить \(c.name)", head: "Остановит \(c.name) — \(what) \(owner)\(age)", note: note)
    }

    private func plan(shell sh: TerminalShell) -> StopPlan? {
        let label = Self.tab(sh) + (sh.project.map { " (\($0))" } ?? "")
        guard !sh.sessions.isEmpty else {
            return plan(process: sh.pid, title: "Закрыть шелл \(label)", head: "Закроет шелл \(label)")
        }
        let names = sh.sessions.map { "«\($0.name)»" }.joined(separator: ", ")
        var note = sh.sessions.first.map { $0.resumeCommand.isEmpty ? "sessionId неизвестен — продолжить через --resume не выйдет." : "Продолжить сессию потом: \($0.resumeCommand)." } ?? ""
        note += sh.sessions.contains { $0.status.isWorking } ? " Сессия сейчас работает — остановка прервёт задачу."
            : " Вместе с шеллом завершится сессия Claude \(names)."
        return plan(process: sh.pid, title: "Закрыть шелл \(label)", head: "Закроет шелл \(label) и убьёт сессию Claude \(names)", note: note)
    }

    private func plan(orphan o: Advice.Orphan) -> StopPlan? {
        plan(process: o.pid, title: "Остановить \(o.name)",
             head: "Остановит \(o.name): родитель завершился, работает \(Fmt.age(o.age))")
    }

    private static func tab(_ sh: TerminalShell) -> String { sh.tty ?? String(sh.pid) }
}
