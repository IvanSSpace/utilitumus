import SwiftUI

/// Страница модуля, который ведёт отдельная утилита: всё остальное у неё в окне.
struct SatellitePage: View {
    let module: Module
    @ObservedObject private var registry = SatelliteRegistry.shared

    var body: some View {
        let entry = registry.entries[module]
        let status = entry?.status
        let needs = status?.needsSetup ?? 0
        DSPage(module: module,
               subtitle: entry?.installedVersion.map { "Отдельное приложение · версия \($0)" },
               primary: DSAction("Открыть окно", icon: "macwindow") { registry.openWindow(module) },
               controls: false) {
            DSSection("Сейчас") {
                if status == nil, registry.busy.contains(module) {
                    DSRow(icon: "arrow.triangle.2.circlepath", title: "Обновляется…",
                          subtitle: "Через несколько секунд экран вернётся сам") { EmptyView() }
                } else if let status {
                    DSRow(icon: module.icon, title: status.line.isEmpty ? module.title : status.line) { EmptyView() }
                } else {
                    DSRow(icon: "exclamationmark.triangle.fill", title: "Не отвечает",
                          subtitle: "Модуль не запущен или завис. Попробуй открыть его окно",
                          iconTint: .orange) { EmptyView() }
                }
                DSRow(icon: "power", title: status?.enabled == true ? "Включён" : "Выключен",
                      subtitle: "Фоновая работа модуля") {
                    DSToggle("Модуль включён", isOn: Binding(
                        get: { status?.enabled ?? false }, set: { registry.setEnabled(module, $0) }))
                        .disabled(status == nil)
                }
                if needs > 0 {
                    DSRow(icon: "exclamationmark.shield.fill", title: "Нужны доступы: \(needs)",
                          subtitle: "Выдаются в окне модуля", iconTint: .orange) { EmptyView() }
                }
            }
        }
        // Таймера нет: на открытой заново странице могла остаться строка упавшей утилиты.
        .onAppear { registry.refresh(module) }
    }
}
