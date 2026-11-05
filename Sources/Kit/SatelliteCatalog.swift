import Foundation

struct CatalogApp: Codable, Equatable {
    let id: String
    let version: String
    let minHub: String
    let url: URL
    let sha256: String
    let sizeMB: Int
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
            sizeMB: try container.decode(Int.self, forKey: .sizeMB))
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
    static let url = URL(string: "https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/Catalog/catalog.json")!

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

    static func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+(\.[0-9]+)*\z"#, options: .regularExpression) != nil
    }
}
