import SwiftUI

// Точка расширения этапа 2: экран «Фоновое» (агенты launchd).
//
// Что взять из ядра: `LoadSnapshot.launchd` (метка → pid из `launchctl list`, обновляется раз в минуту),
// `LoadSnapshot.procs` / `.tree` для памяти агента и его потомков, `Attribution`/`Kinds.appName(of:)` для имени,
// остановка — `LoadSnapshot.stopPlan(process:)` + `LoadStore.shared.requestStop(process:)`.
// Действия launchctl (bootout/disable/enable) пишутся рядом с `StopExecutor` и защищаются по правилам из actions.py.

/// Вкладка «Фоновое». Этап 2 заменяет это представление.
struct BackgroundTab: View {
    var body: some View {
        ContentUnavailableView {
            Label("Фоновое — скоро", systemImage: "gearshape.2")
        } description: {
            Text("Фоновые агенты launchd и приложения без окна появятся здесь в следующем обновлении.")
        }
    }
}

/// Сводка фонового в «Обзоре». Этап 2 заменяет эту секцию.
struct BackgroundCompactSection: View {
    var body: some View {
        Section("Фоновое") {
            EmptyNote(text: "Скоро")
        }
    }
}
