import Foundation

// Подмена того, что ModuleManager и SatelliteRegistry берут у панели, «Обновить всё» и экранов: настоящие файлы тянут
// значки, дашборд и весь центр. Проверки передачи и миграции этого не касаются, поэтому здесь только имена.
// Панель проверяет run-sidebar-check, занятость утилиты run-update-all-check. Дойдёт сюда — падает, а не врёт.
@MainActor
final class SidebarModel {
    static let shared = SidebarModel()
    var pins: Set<Module> { fatalError("Проверка дошла до боковой панели") }
    static func layout(modules: ModuleManager, pins: Set<Module>, open: Module?) -> SidebarLayout {
        fatalError("Проверка дошла до боковой панели")
    }
}

enum UpdateBusy {
    static func reason(_ module: Module, state: Data) -> String? { fatalError("Проверка дошла до занятости утилиты") }
    static func readable(_ module: Module, state: Data) -> Bool { fatalError("Проверка дошла до занятости утилиты") }
}

@MainActor
enum RemoteModules {
    final class Surface { func refresh() {} }
    static func model(_ module: Module) -> Surface? { fatalError("Проверка дошла до экрана модуля") }
}
