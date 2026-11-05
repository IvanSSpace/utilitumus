import Foundation

/// LaunchAgent утилиты: launchd запускает её при входе и по подключению к Mach-сервису.
struct SatelliteAgent {
    static func plist(id: String, executable: URL) -> Data {
        let agent: [String: Any] = [
            "Label": KitLink.bundleID(id),
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "MachServices": [KitLink.machService(id): true],
        ]
        // Только строки, массивы и булевы значения: сериализация здесь упасть не может.
        return try! PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
    }
}
