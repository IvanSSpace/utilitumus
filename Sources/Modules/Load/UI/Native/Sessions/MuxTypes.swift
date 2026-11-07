import Foundation

/// Отдельный файл без зависимостей: опрос tmux и Docker проверяется один, без остального кода (Tests/run-tool-spawn-check.sh).
struct TmuxInfo: Sendable, Codable, Equatable {
    struct Session: Sendable, Codable, Equatable, Identifiable {
        var name: String
        var windows: Int = 0
        var attached: Bool
        var id: String { name }

        /// `windows` экран не показывает.
        private enum CodingKeys: String, CodingKey { case name, attached }
    }

    var running = false
    var sessions: [Session] = []
}

struct DockerInfo: Sendable, Codable, Equatable {
    struct Container: Sendable, Codable, Equatable, Identifiable {
        var id: String = ""
        var name: String
        var image: String = ""
        var state: String
        var status: String

        /// `id` и `image` экран не показывает.
        private enum CodingKeys: String, CodingKey { case name, state, status }
    }

    var running = false
    var containers: [Container] = []
}
