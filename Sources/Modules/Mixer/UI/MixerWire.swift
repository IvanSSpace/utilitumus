import AppKit

/// Строка списка на экране. Иконка по связи не ходит: экран находит её по `id`.
struct MixerAppState: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var volume: Double
    var muted: Bool
}

/// То, что экран показывает.
struct MixerState: Codable, Equatable, Sendable {
    var apps: [MixerAppState]
    var idleApps: [MixerAppState]
    var presetApps: [MixerAppState]
    var otherApps: [MixerAppState]
    var permissionProblem: Bool
    var lastError: String?
}

/// Что экран может попросить. Больше модуль ничего не примет. Открыт ли экран, связь знает сама (аренда экрана).
enum MixerAction: Codable, Equatable, Sendable {
    case setVolume(id: String, value: Double)
    case setMuted(id: String, muted: Bool)
    case reset(id: String)
    case commitVolumes

    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setVolume":
            try wire.fields("id", "value")
            self = .setVolume(id: try wire.field("id"), value: try wire.field("value"))
        case "setMuted":
            try wire.fields("id", "muted")
            self = .setMuted(id: try wire.field("id"), muted: try wire.field("muted"))
        case "reset":
            try wire.fields("id")
            self = .reset(id: try wire.field("id"))
        case "commitVolumes":
            try wire.none()
            self = .commitVolumes
        default:
            throw wire.refuse()
        }
    }
}

/// Иконка приложения по `id` из состояния: у запущенного как в списках контроллера, у незапущенного
/// как в «Настроены заранее», у `exe:` и неизвестного общий значок.
@MainActor
enum MixerAppIcon {
    private static var found: [String: NSImage] = [:]

    static func icon(for id: String) -> NSImage {
        if let hit = found[id] { return hit }
        let generic = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
        guard !id.hasPrefix("exe:") else { return generic }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        guard let icon = running ?? installed else { return generic }
        found[id] = icon
        return icon
    }
}

/// Приложение в списке микшера.
struct MixerApp: Identifiable, Equatable {
    /// Bundle id приложения (или `exe:<имя>` у программ без бандла) — по нему
    /// запоминается громкость.
    let id: String
    let name: String
    let icon: NSImage
    var volume: Double
    var muted: Bool

    /// Иконка в сравнение не входит: она не меняется, а сравнивать картинки дорого.
    static func == (a: MixerApp, b: MixerApp) -> Bool {
        a.id == b.id && a.name == b.name && a.volume == b.volume && a.muted == b.muted
    }
}

extension MixerApp {
    /// Строка экрана из состояния, пришедшего по связи.
    @MainActor init(_ row: MixerAppState) {
        self.init(id: row.id, name: row.name, icon: MixerAppIcon.icon(for: row.id), volume: row.volume, muted: row.muted)
    }
}
