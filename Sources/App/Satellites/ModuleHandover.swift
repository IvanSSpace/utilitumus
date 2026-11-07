import Foundation

/// Кто ведёт модуль. Работать за утилиту в центре нечему, поэтому решают только бандл и отметка о передаче.
enum ModuleHandover {
    enum Decision: Equatable {
        /// Утилиты не было и нет.
        case notInstalled
        case handOver
        case satelliteOwns
        /// Передавали, а бандла нет: человек убрал утилиту мимо центра.
        case utilityGone
    }

    /// Пишет центр при передаче. Читает и утилита (`SatelliteRole`): имя менять нельзя.
    static func handedOverKey(_ id: String) -> String { "App.\(id).HandedOver" }
    /// Включённость утилиты. Хозяин ключа — утилита; центр ставит его только перед первой установкой.
    static func enabledKey(_ id: String) -> String { "App.\(id).Enabled" }

    /// Бандл есть, передачи не было — передаём сразу, что бы ни ответила утилита и сделан ли её чек-лист. Выпущенные
    /// утилиты держат себя пассивными, пока центр запущен, `ModuleOn` включён и ключа нет (`SatelliteRole.decide`):
    /// без передачи они не заработали бы никогда. Разрешения она попросит сама, уже активной.
    static func decide(bundlePresent: Bool, handedOver: Bool) -> Decision {
        switch (bundlePresent, handedOver) {
        case (false, false): return .notInstalled
        case (false, true): return .utilityGone
        case (true, true): return .satelliteOwns
        case (true, false): return .handOver
        }
    }
}
