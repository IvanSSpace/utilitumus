import Foundation

/// LaunchAgent утилиты: launchd запускает её при входе и по подключению к Mach-сервису.
struct SatelliteAgent {
    static func plist(id: String, executable: URL) -> Data {
        var agent: [String: Any] = [
            "Label": KitLink.bundleID(id),
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "MachServices": [KitLink.machService(id): true, KitLink.selfService(id): true],
        ]
        #if KIT_TEST_DEFAULTS
        // Утилита стенда живёт с подставным домом: иначе всё от NSHomeDirectory попало бы в настоящие каталоги автора.
        let home = NSTemporaryDirectory() + "utilitumus-test-home/\(id)"
        try? FileManager.default.createDirectory(atPath: home + "/Library", withIntermediateDirectories: true)
        agent["EnvironmentVariables"] = ["CFFIXED_USER_HOME": home, "HOME": home]
        #endif
        // Только строки, массивы и булевы значения: сериализация здесь упасть не может.
        return try! PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
    }
}
