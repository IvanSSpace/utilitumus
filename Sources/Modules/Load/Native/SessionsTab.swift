import SwiftUI

// Точка расширения этапа 2: экран «Сессии» (Claude Code, терминалы, tmux, Docker, сироты).
//
// Что взять из ядра (`Native/Core`):
// - `LoadSnapshot.procs` / `.tree` — все процессы и дерево; `Kinds.isClaude(_:)` находит сессию claude,
//   `Kinds.hostApp(of:procs:)` — приложение, которое её ведёт, `Kinds.childKind(_:)` — shell / mcp / dev-server;
// - `ProcessTree.subtree(of:)` — сессия и потомки (глубокие первыми), `LoadProcess.age(now:)`, `.memMB`, `.cpuPercent`;
// - `Attribution.sessionProject(cwd:roots:)` и `LoadSnapshot.roots` — проект сессии;
// - `Advice.orphans(...)` — сироты;
// - остановка: `LoadSnapshot.stopPlan(process:)` → `LoadStore.shared.requestStop(process:)` (подтверждение и
//   SIGTERM → SIGKILL уже есть, защита — в `Protection`).
// Правило подсказок про простой сессии и одинаковые MCP (advice.py: _idle, _mcp) добавляется в `Advice.build`.

/// Вкладка «Сессии». Этап 2 заменяет это представление.
struct SessionsTab: View {
    var body: some View {
        ContentUnavailableView {
            Label("Сессии — скоро", systemImage: "terminal")
        } description: {
            Text("Сессии Claude Code, вкладки терминалов, tmux и Docker появятся здесь в следующем обновлении.")
        }
    }
}

/// Сводка сессий в «Обзоре». Этап 2 заменяет эту секцию.
struct SessionsCompactSection: View {
    var body: some View {
        Section("Сессии Claude") {
            EmptyNote(text: "Скоро")
        }
    }
}

/// Плитка «ИИ» в итогах «Обзора». Этап 2 считает память ИИ (сессии, MCP, Claude.app, ollama, whisper).
struct AIMemoryKPI: View {
    var body: some View {
        KPITile(title: "ИИ", value: "—", subtitle: "скоро")
    }
}
