import Foundation

/// Кто ведёт модуль: встроенный код центра или отдельная утилита.
enum ModuleHandover {
    enum Decision: Equatable {
        case keepBuiltIn
        case handOver
        case satelliteOwns
        case returnToBuiltIn
    }

    /// Пишет центр, выключив встроенный вариант. Читает и утилита (`SatelliteRole`): имя менять нельзя.
    static func handedOverKey(_ id: String) -> String { "App.\(id).HandedOver" }
    /// Включённость утилиты. Хозяин ключа — утилита; центр ставит его только перед первой установкой.
    static func enabledKey(_ id: String) -> String { "App.\(id).Enabled" }

    /// Передача случается один раз: когда утилита ответила и её чек-лист сделан. Передано и нет ответа —
    /// всё равно утилита: вернуть встроенный рядом с живым агентом значило бы двойную работу.
    static func decide(bundlePresent: Bool, handedOver: Bool, reply: LinkStatus?) -> Decision {
        switch (bundlePresent, handedOver) {
        case (false, false): return .keepBuiltIn
        case (false, true): return .returnToBuiltIn
        case (true, true): return .satelliteOwns
        case (true, false): return reply?.needsSetup == 0 ? .handOver : .keepBuiltIn
        }
    }
}
