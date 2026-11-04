import Foundation

/// Что известно о программе, чтобы решить, игра ли она. Без AppKit — чтобы
/// логику можно было проверить на подставных данных.
struct AppInfo: Equatable {
    var bundleID: String?
    /// Имя исполняемого файла. Нужно процессам без bundle id (Wine/CrossOver).
    var executableName: String?
    var name: String
    /// `LSApplicationCategoryType` из Info.plist.
    var category: String?

    var key: String? { GameRules.key(bundleID: bundleID, executableName: executableName) }
}

/// Игра из списка «Мои игры». `key` — bundle id или `exe:<имя файла>`.
struct GameEntry: Codable, Hashable, Identifiable {
    let key: String
    var name: String
    var id: String { key }
}

struct GameRules {
    /// Лаунчеры: у них игровая категория, но играть в них не значит нагружать машину.
    static let defaultLaunchers: [GameEntry] = [
        GameEntry(key: "com.valvesoftware.steam", name: "Steam"),
        GameEntry(key: "com.epicgames.EpicGamesLauncher", name: "Epic Games Launcher"),
        GameEntry(key: "net.battle.app", name: "Battle.net"),
        GameEntry(key: "com.gog.galaxy", name: "GOG Galaxy"),
        GameEntry(key: "com.ea.EADesktop", name: "EA app"),
        GameEntry(key: "com.heroicgameslauncher.hgl", name: "Heroic Games Launcher"),
        GameEntry(key: "io.itch.mac", name: "itch"),
    ]

    var myGames: Set<String> = []
    var excludedLaunchers: Set<String> = []

    /// Bundle id, а если его нет — имя исполняемого файла.
    static func key(bundleID: String?, executableName: String?) -> String? {
        if let id = bundleID, !id.isEmpty { return id }
        if let exe = executableName, !exe.isEmpty { return "exe:" + exe }
        return nil
    }

    static func isGameCategory(_ category: String?) -> Bool {
        guard let c = category?.lowercased() else { return false }
        return c == "public.app-category.games"
            || (c.hasPrefix("public.app-category.") && c.hasSuffix("-games"))
    }

    func isGame(_ app: AppInfo) -> Bool {
        guard let key = app.key else { return false }
        // Явный выбор пользователя сильнее исключения: добавил лаунчер сам — значит, надо.
        if myGames.contains(key) { return true }
        return Self.isGameCategory(app.category) && !excludedLaunchers.contains(key)
    }
}

/// Состояние режима «Максимум в играх». Время приходит снаружи, поэтому
/// ожидание в 60 с проверяется без реальных таймеров.
struct GameModeMachine {
    /// Короткие переключения (свернул в чат и вернулся) не должны дёргать вентиляторы.
    static let grace: TimeInterval = 60

    enum Phase: Equatable {
        case idle
        case playing(GameEntry)
        case leaving(GameEntry, until: Date)
    }

    enum Event: Equatable {
        case started(GameEntry)
        case leftGame(GameEntry)
        case resumed(GameEntry)
        case expired(GameEntry)
        case closed(GameEntry)
    }

    private(set) var phase: Phase = .idle

    /// Вентиляторы на максимуме и во время ожидания.
    var isActive: Bool { phase != .idle }

    var game: GameEntry? {
        switch phase {
        case .idle: return nil
        case .playing(let g), .leaving(let g, _): return g
        }
    }

    /// На передний план вышла программа; `game` — она же, если это игра.
    mutating func activated(_ game: GameEntry?, now: Date) -> Event? {
        switch (phase, game) {
        case (.idle, nil):
            return nil
        case (.idle, let g?):
            phase = .playing(g)
            return .started(g)
        case (.playing(let cur), let g?):
            guard cur.key != g.key else { return nil }
            phase = .playing(g)
            return .started(g)
        case (.playing(let cur), nil):
            phase = .leaving(cur, until: now.addingTimeInterval(Self.grace))
            return .leftGame(cur)
        case (.leaving(let cur, _), let g?):
            phase = .playing(g)
            return cur.key == g.key ? .resumed(g) : .started(g)
        case (.leaving, nil):
            // Срок идёт от первого ухода, переключения между не-играми его не продлевают.
            return nil
        }
    }

    /// Программа закрылась: если это текущая игра — сразу в обычный режим.
    mutating func terminated(key: String) -> Event? {
        guard let cur = game, cur.key == key else { return nil }
        phase = .idle
        return .closed(cur)
    }

    mutating func tick(now: Date) -> Event? {
        guard case .leaving(let cur, let until) = phase, now >= until else { return nil }
        phase = .idle
        return .expired(cur)
    }

    mutating func reset() { phase = .idle }
}
