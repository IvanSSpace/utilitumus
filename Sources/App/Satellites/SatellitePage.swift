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
                if registry.busy.contains(module) {
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

/// Модуль включён, а утилиты нет: ставится, установка сорвалась или каталог недоступен. Работать за неё центру нечем.
struct ModuleMissingPage: View {
    let module: Module
    @ObservedObject private var registry = SatelliteRegistry.shared

    private var lead: String {
        if registry.busy.contains(module) { return "Утилита модуля ставится…" }
        // До первого опроса неизвестно, есть ли она: при каждом запуске здесь мигало бы «не установлена».
        guard registry.polled.contains(module) else { return "Проверяем утилиту модуля…" }
        if let error = registry.installFailures[module] {
            return StoreModel.failureMessage(error, fallback: "Не получилось поставить утилиту модуля")
        }
        guard registry.catalogApp(module) != nil else {
            return registry.catalogFailed ? "Утилита модуля не установлена, а каталог недоступен: проверь сеть"
                                          : "Утилита модуля не установлена, в каталоге её пока нет"
        }
        return "Утилита модуля не установлена"
    }

    var body: some View {
        ModuleCentered(module: module, title: module.title, lead: lead) {
            EmptyView()
        } actions: {
            DSButton("Установить", style: .primary) { registry.installMissing(module) }
                .disabled(registry.busy.contains(module) || !registry.polled.contains(module) || registry.catalogApp(module) == nil)
        }
        // Каталог мог сорваться при запуске: открытая страница пробует его снова.
        .onAppear { registry.refresh() }
    }
}
