import Foundation

struct CatalogApp: Codable, Equatable {
    let id: String
    let version: String
    let minHub: String
    let url: URL
    let sha256: String
    let sizeMB: Int
    /// Что изменилось в этой версии: простой текст после `SatelliteCatalog.cleanNotes`.
    var notes: [String] = []
    /// Выпуск просит у человека новое разрешение, которое по файлу не видно («Универсальный доступ», мониторинг ввода):
    /// автообновление его не ставит, остаётся кнопка.
    var manualUpdate = false
}

extension CatalogApp {
    /// Проверка здесь, а не в `decode`: `id` подставляется в требование подписи и в путь к плисту,
    /// а версия с мусором сравнивалась бы как 0 и прошла бы проверку `minHub`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard SatelliteCatalog.isValidID(id) else { throw SatelliteCatalogError.invalidID(id) }
        let version = try container.decode(String.self, forKey: .version)
        let minHub = try container.decode(String.self, forKey: .minHub)
        for value in [version, minHub] where !SatelliteCatalog.isValidVersion(value) {
            throw SatelliteCatalogError.invalidVersion(value)
        }
        self.init(
            id: id,
            version: version,
            minHub: minHub,
            url: try container.decode(URL.self, forKey: .url),
            sha256: try container.decode(String.self, forKey: .sha256),
            sizeMB: try container.decode(Int.self, forKey: .sizeMB),
            // Заметки только для чтения человеком: кривые не должны отвергать весь каталог.
            notes: SatelliteCatalog.cleanNotes((try? container.decodeIfPresent([String].self, forKey: .notes)) ?? []))
        // Кривое значение считается отметкой: ошибка должна вести к кнопке, а не к тихой установке.
        if container.contains(.manualUpdate) { manualUpdate = (try? container.decode(Bool.self, forKey: .manualUpdate)) ?? true }
    }
}

struct Catalog: Codable {
    let schema: Int
    let apps: [CatalogApp]
}

enum SatelliteCatalogError: LocalizedError, Equatable {
    case schema(Int)
    case invalidID(String)
    case invalidVersion(String)

    var errorDescription: String? {
        switch self {
        case .schema(let schema): return "Каталог модулей новее этой версии (формат \(schema))"
        case .invalidID(let id): return "В каталоге модулей недопустимый id: \(id)"
        case .invalidVersion(let version): return "В каталоге модулей недопустимая версия: \(version)"
        }
    }
}

/// Какие утилиты можно поставить и откуда. Доверие держится не на каталоге, а на подписи скачанного.
enum SatelliteCatalog {
    /// Обновляются только по кнопке в центре, что бы ни было в каталоге. Список один: его читают и автообновление центра
    /// (`AutoUpdatePolicy.personOnly`), и сама утилита при закрытом центре (`SatelliteSelfUpdate`).
    /// `fans` — центр не знает, поднята ли в выпуске версия службы; поднята — вентиляторы не работают, пока человек
    /// не введёт пароль (`FanHelperInstaller`). Плюс выход утилиты снимает выбранные человеком обороты.
    /// `clipboard` — ключ истории в файловой связке, подпись без Team ID: новый бинарник может вызвать окно пароля связки
    /// (`ClipboardKeyring`), а проверить это на настоящей связке нельзя.
    /// Строки, а не `Module`: этот файл собирается и без него. Опечатку ловит run-auto-update-check.
    static let personOnly: Set<String> = ["fans", "clipboard"]

    /// Подмена адреса только флагом компилятора: окружение, аргументы и настройки здесь не читаются.
    /// `KitPilotCatalog` пишет scripts/build-pilot.sh, в обычной сборке этого имени нет.
    #if KIT_PILOT_CATALOG
    static let url = URL(fileURLWithPath: KitPilotCatalog.path)
    #else
    static let url = URL(string: "https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/Catalog/catalog.json")!
    #endif

    /// Одно приложение с плохим `id` или версией отвергает весь каталог: см. `CatalogApp.init(from:)`.
    static func decode(_ data: Data) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schema == 1 else { throw SatelliteCatalogError.schema(catalog.schema) }
        return catalog
    }

    /// Приложения, которые эта версия центра умеет вести.
    static func available(_ catalog: Catalog, hubVersion: String) -> [CatalogApp] {
        catalog.apps.filter { !Kit.isNewer($0.minHub, than: hubVersion) }
    }

    /// `\z`, а не `$`: перевод строки в конце `$` пропускает или нет смотря по API (NSRegularExpression пропускает).
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9.-]*\z"#, options: .regularExpression) != nil
    }

    /// До 18 цифр в части: больше не влезает в Int, и `Kit.isNewer` посчитал бы такую часть нулём.
    static func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]{1,18}(\.[0-9]{1,18})*\z"#, options: .regularExpression) != nil
    }

    /// Те же пределы проверяет scripts/release-app.sh: при выпуске заметку не молча обрежут, а откажут.
    static let maxNotes = 8
    static let maxNoteLength = 200

    /// Заметки приходят из сети. Пустые не считаются в предел, лишние отбрасываются.
    static func cleanNotes(_ notes: [String]) -> [String] {
        Array(notes.lazy.compactMap(cleanNote).prefix(maxNotes))
    }

    /// Одна строка без управляющих символов: они ломают строку и переворачивают текст (U+202E).
    /// Диакритика ограничена, иначе знаки, наложенные друг на друга, вылезают за строку.
    private static func cleanNote(_ note: String) -> String? {
        var kept = String.UnicodeScalarView()
        var marks = 0
        var space = false
        for scalar in note.unicodeScalars {
            if scalar.properties.isWhitespace {
                space = !kept.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned:
                continue
            case .nonspacingMark, .enclosingMark:
                marks += 1
                if marks > 2 { continue }
            default:
                marks = 0
            }
            if space { kept.append(" ") }
            space = false
            kept.append(scalar)
            if kept.count > maxNoteLength {
                return String(String.UnicodeScalarView(kept.prefix(maxNoteLength - 1))) + "…"
            }
        }
        return kept.isEmpty ? nil : String(kept)
    }
}
