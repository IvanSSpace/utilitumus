import Foundation

/// Какие модули показывает центр. Обычная сборка показывает все, кроме личных без бандла (`Module.isPersonal`).
/// Сборка `scripts/dev.sh` (флаг `KIT_DEV_SCOPE`) показывает только свой набор: `KitDevScope` лежит в папке разработки
/// и зашит при компиляции. Других входов нет: ни настроек, ни окружения, ни аргументов.
///
/// Только показ. Всё, что работает и пишет настройки (опрос утилит, передача им модулей, переход на утилиты,
/// сброс при первом запуске), идёт по `Module.allCases` мимо этого типа: модули вне набора живут как жили.
enum ModuleScope {
    #if KIT_DEV_SCOPE
    /// nil: видны все (`scripts/dev.sh --all`).
    private static let ids = parse(KitDevScope.line)

    /// Строка вида `<метка>=mixer,load`; `=*` значит все, пустой список — ни одного.
    static func parse(_ line: String) -> Set<String>? {
        let list = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first ?? ""
        return list == "*" ? nil : Set(list.split(separator: ",").map(String.init))
    }
    #endif

    /// Личные модули (`Module.isPersonal`), чей бандл лежит на диске. Читается один раз при запуске: поставили бандл —
    /// центр увидит его при следующем запуске. У всех остальных людей бандла нет, и модуля нет ни в Сторе, ни в панели.
    /// Стенд (`KIT_TEST_DEFAULTS`) настоящую папку программ не читает: набор пуст, пока проверка не задала его сама.
    /// Обычная сборка смотрит туда же, куда реестр утилит: стенд, задавший `SatelliteRegistry.standEnvironment`,
    /// получает свою временную папку, а не настоящую /Applications/Utilitumus.
    #if KIT_TEST_DEFAULTS
    nonisolated(unsafe) static var personalPresent: Set<Module> = []
    #else
    private static let personalPresent: Set<Module> = {
        let apps = SatelliteRegistry.standEnvironment?.paths.appsDir ?? SatellitePaths.live.appsDir
        return Set(Module.allCases.filter {
            $0.isPersonal && FileManager.default.fileExists(atPath: apps.appendingPathComponent(SatelliteRegistry.bundleName($0) + ".app").path)
        })
    }()
    #endif

    static func shows(_ module: Module) -> Bool {
        #if KIT_DEV_SCOPE
        // Набор назван явно: личный модуль в нём виден и без бандла на диске, иначе его не собрать на стенде.
        if let ids { return ids.contains(module.rawValue) }
        #endif
        return !module.isPersonal || personalPresent.contains(module)
    }

    static func shown(_ modules: [Module]) -> [Module] {
        modules.filter(shows)
    }

    /// Категории, в которых есть что показать. Состав категории остаётся полным: от него зависит цвет модуля.
    static var categories: [ModuleCategory] {
        ModuleCategory.all.filter { !shown($0.modules).isEmpty }
    }

    /// Плитки «скоро» к модулям не относятся: в суженной сборке им делать нечего.
    static var showsSoon: Bool {
        #if KIT_DEV_SCOPE
        ids == nil
        #else
        true
        #endif
    }

    /// Что сказать вместо витрины, когда модулей в сборке нет вообще (`scripts/dev.sh --hub`).
    static var emptyNote: String? {
        #if KIT_DEV_SCOPE
        ids?.isEmpty == true ? "В этой сборке только центр, модулей нет" : nil
        #else
        nil
        #endif
    }

    /// Настоящий порядок после перестановки показанных: показанные занимают свои же места в новом порядке, остальные не двигаются.
    /// Без этого перенос строки в суженной панели записал бы в настройки порядок только из набора.
    static func merged(_ new: [Module], into full: [Module]) -> [Module] {
        var next = shown(new).makeIterator()
        return full.map { shows($0) ? next.next() ?? $0 : $0 }
    }
}
