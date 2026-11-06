import Foundation

/// Всё, что экран «Боты» берёт у своей модели. Работает ли модуль здесь же (`BotsStore`) или в утилите, экран не знает.
@MainActor
protocol BotsModel: ObservableObject {
    var state: BotsState { get }
    func refreshNow()
    func screenAppeared()
    func screenDisappeared()
    func request(_ bot: BotCard, _ verb: BotVerb)
    func cancel()
    func confirm(_ planID: UUID)
    func dismissNotice()
}

enum BotsText {
    /// «2 из 3 работают» — строка статуса: по файлу и последнему замеру, без аптайма и памяти.
    static func summary(_ state: BotsState) -> String {
        switch state.file.kind {
        case .missing: return "bots.toml не найден"
        case .unsafe: return "bots.toml небезопасен"
        case .invalid: return "bots.toml не читается"
        case .ok:
            let total = state.bots.count
            if total == 0 { return "в bots.toml нет ботов" }
            let on = state.bots.filter { $0.state == .running || $0.state == .partial }.count
            return "\(on) из \(total) \(Fmt.word(on, "работает", "работают", "работают"))"
        }
    }

    static let example = """
    [[bot]]
    id = "news"
    name = "Новости"
    project = "my-project"
    url = "http://127.0.0.1:8080/"
    launchd = ["com.example.news"]
    start = ["/bin/launchctl", "kickstart", "gui/501/com.example.news"]
    stop = ["/bin/launchctl", "bootout", "gui/501/com.example.news"]
    restart = ["/bin/launchctl", "kickstart", "-k", "gui/501/com.example.news"]
    requires_env = ["BOT_TOKEN"]
    env_file = "/path/to/news/.env"
    note = "Что это за бот"
    """
}
