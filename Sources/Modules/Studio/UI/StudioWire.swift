import Foundation

/// Что сейчас с сервером Студии.
enum StudioPhase: String, Codable, Equatable, Sendable {
    case stopped, starting, running, failed
}

/// То, что показывает экран «Студия». Токена здесь нет и быть не может: только готовый адрес с одноразовым кодом,
/// который утилита получила у самой Студии (`/api/boot`). Код живёт две минуты и меняется на токен один раз.
struct StudioState: Codable, Equatable, Sendable {
    /// Папка Студии из настройки; пусто — не задана.
    var folder: String
    var phase: StudioPhase
    /// Текст ошибки или подсказка; только готовые строки, без ответов сервера.
    var message: String?
    /// Сервер запущен этой утилитой: выключение его остановит. Чужой процесс только подключён и при выключении живёт дальше.
    var ownsServer: Bool
    /// `http://127.0.0.1:<порт>/#b=<код>`, пока сервер работает.
    var page: String?
    /// Номер выданного кода входа: по смене экран понимает, что адрес новый, даже если текст совпал.
    var login: Int
}

/// Что экран может попросить. Больше утилита ничего не примет.
enum StudioAction: Codable, Equatable, Sendable {
    /// Новая папка Студии; пустая строка снимает настройку.
    case setFolder(String)
    /// Новый одноразовый код входа: «обновить» и «открыть в браузере».
    case newLogin

    /// Строго: ровно одно известное действие и ровно его поля. Кодирование остаётся синтезированным.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setFolder": self = .setFolder(try wire.value())
        case "newLogin": try wire.none(); self = .newLogin
        default: throw wire.refuse()
        }
    }
}

enum StudioKeys {
    /// Папка Студии. По умолчанию пусто: путей автора в коде нет.
    static let folder = "studio.folder"
}

enum StudioPath {
    /// Самый длинный допустимый путь.
    static let maxLength = 1024

    /// Путь из настройки или с провода: абсолютный, без `.` и `..`, без управляющих символов. Пусто — «не задана».
    /// nil — путь не годится. Симлинки и права смотрит `StudioRunner`, здесь только форма.
    static func validated(_ raw: String) -> String? {
        if raw.isEmpty { return "" }
        guard raw.utf8.count <= maxLength, raw.hasPrefix("/"),
              !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return "/" + parts.joined(separator: "/")
    }
}

/// Куда можно ходить странице Студии. Всё остальное уходит в браузер по умолчанию, страница это не загружает.
enum StudioNavigation {
    enum Decision: Equatable { case allow, openInBrowser, refuse }

    /// Порт от 1024: Студия слушает не привилегированный.
    static func port(of url: URL) -> Int? {
        guard let port = url.port, (1024...65535).contains(port) else { return nil }
        return port
    }

    /// Адрес самой Студии: `http`, свой хост, порт, без логина и пароля.
    static func isStudio(_ url: URL, port: Int) -> Bool {
        guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
              Self.port(of: url) == port else { return false }
        return true
    }

    /// Решение о переходе. `http` и `https` чужих адресов — в браузер; `file`, `javascript`, `data`, `blob`, `about` и
    /// прочие схемы не открываются нигде.
    static func decide(_ url: URL?, port: Int) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .refuse }
        if isStudio(url, port: port) { return .allow }
        return scheme == "http" || scheme == "https" ? .openInBrowser : .refuse
    }

    /// Адрес входа с провода: тот же отбор, что у перехода, и порт берётся из самого адреса.
    static func loginURL(_ page: String?) -> (url: URL, port: Int)? {
        guard let page, let url = URL(string: page), let port = port(of: url), isStudio(url, port: port) else { return nil }
        return (url, port)
    }
}

extension StudioState {
    /// Что экран покажет до первого ответа утилиты: сохранённая папка. Остальное знает только утилита.
    static func stored() -> StudioState {
        let folder = Kit.defaults.string(forKey: StudioKeys.folder).flatMap(StudioPath.validated) ?? ""
        return StudioState(folder: folder, phase: .stopped, message: nil, ownsServer: false, page: nil, login: 0)
    }
}
