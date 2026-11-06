import AppKit

/// Строка списка на экране. Иконка по связи не ходит: экран находит её по `id`.
struct MixerAppState: Codable, Equatable {
    var id: String
    var name: String
    var volume: Double
    var muted: Bool
}

/// То, что экран показывает.
struct MixerState: Codable, Equatable {
    var apps: [MixerAppState]
    var idleApps: [MixerAppState]
    var presetApps: [MixerAppState]
    var otherApps: [MixerAppState]
    var permissionProblem: Bool
    var lastError: String?
}

/// Что экран может попросить. Больше модуль ничего не примет.
enum MixerAction: Codable, Equatable {
    case setVolume(id: String, value: Double)
    case setMuted(id: String, muted: Bool)
    case reset(id: String)
    case commitVolumes
    case setScreenVisible(visible: Bool)
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

extension MixerApp {
    /// Строка экрана из состояния, пришедшего по связи.
    @MainActor init(_ row: MixerAppState) {
        self.init(id: row.id, name: row.name, icon: MixerAppIcon.icon(for: row.id), volume: row.volume, muted: row.muted)
    }
}

extension MixerController {
    /// Ползунок меняет громкость сразу, а списки публикуются позже (`schedulePersist`): значения берём
    /// живые, иначе ответ на шаг ползунка вернул бы прежнюю громкость.
    var wireState: MixerState {
        func rows(_ list: [MixerApp]) -> [MixerAppState] {
            list.map { MixerAppState(id: $0.id, name: $0.name, volume: volume(for: $0.id), muted: isMuted($0.id)) }
        }
        return MixerState(apps: rows(apps), idleApps: rows(idleApps), presetApps: rows(presetApps), otherApps: rows(otherApps),
                          permissionProblem: permissionProblem, lastError: lastError)
    }

    /// Действие из связи: сначала проверка, изменения только после неё. Вернёт текст ошибки или nil.
    /// `id` принимается только из показанных списков: иначе в настройки можно дописать любой мусор.
    func handle(_ action: MixerAction) -> String? {
        let unknown = "Такого приложения нет в списке"
        func issued(_ id: String) -> Bool {
            [apps, idleApps, presetApps, otherApps].contains { $0.contains { $0.id == id } }
        }
        switch action {
        case .setVolume(let id, let value):
            guard value.isFinite else { return "Такой громкости нет" }
            guard issued(id) else { return unknown }
            setVolume(value, for: id) // Диапазон 0...1 держит сам setVolume.
        case .setMuted(let id, let on):
            guard issued(id) else { return unknown }
            setMuted(on, for: id)
        case .reset(let id):
            guard issued(id) else { return unknown }
            reset(id)
        case .commitVolumes:
            commitVolumes()
        case .setScreenVisible(let visible):
            setScreenVisible(visible)
        }
        return nil
    }
}
