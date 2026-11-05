import Foundation

struct CatalogApp: Codable, Equatable {
    let id: String
    let version: String
    let minHub: String
    let url: URL
    let sha256: String
    let sizeMB: Int
}

struct Catalog: Codable {
    let schema: Int
    let apps: [CatalogApp]
}

enum SatelliteCatalogError: LocalizedError, Equatable {
    case schema(Int)
    case invalidID(String)

    var errorDescription: String? {
        switch self {
        case .schema(let schema): return "Каталог модулей новее этой версии (формат \(schema))"
        case .invalidID(let id): return "В каталоге модулей недопустимый id: \(id)"
        }
    }
}

/// Какие утилиты можно поставить и откуда. Доверие держится не на каталоге, а на подписи скачанного.
enum SatelliteCatalog {
    static let url = URL(string: "https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/Catalog/catalog.json")!

    /// `id` подставляется в строку требования подписи, поэтому один плохой отвергает весь каталог.
    static func decode(_ data: Data) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schema == 1 else { throw SatelliteCatalogError.schema(catalog.schema) }
        for app in catalog.apps where !isValidID(app.id) {
            throw SatelliteCatalogError.invalidID(app.id)
        }
        return catalog
    }

    /// Приложения, которые эта версия центра умеет вести.
    static func available(_ catalog: Catalog, hubVersion: String) -> [CatalogApp] {
        catalog.apps.filter { !Kit.isNewer($0.minHub, than: hubVersion) }
    }

    /// `\z`, а не `$`: перевод строки в конце `$` пропускает или нет смотря по API (NSRegularExpression пропускает).
    private static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9.-]*\z"#, options: .regularExpression) != nil
    }
}
