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
    /// Сколько раз утилита открыла Студию в браузере. Сам код входа сюда не попадает: он меняется на токен, а лаунчеру токен
    /// не положен. Прежнего поля `page` нет: необязательное, прежний лаунчер читает состояние и без него.
    var login: Int
    /// Утилиты, мастера, дела: есть, пока сервер работает и экран открыт. nil — ключа на проводе нет.
    var board: StudioBoard? = nil
}

/// Что экран может попросить. Больше утилита ничего не примет.
enum StudioAction: Codable, Equatable, Sendable {
    /// Новая папка Студии; пустая строка снимает настройку.
    case setFolder(String)
    /// Открыть Студию в браузере по свежему одноразовому коду. Код берёт и открывает сама утилита.
    case openInBrowser
    /// Прежнее имя того же действия: так его шлёт лаунчер 0.9.4.
    case newLogin
    /// Подключиться заново: после ошибки сервера.
    case reconnect
    /// Выбрать утилиту: утилита подгрузит её дело и очередь.
    case select(String)
    case deselect
    /// Кнопки утилиты, те же, что у страницы: `/api/unit/<id>/open|stand|release|rotate`.
    case openSession(String)
    case stand(String)
    case release(String)
    case rotate(String)
    /// Задача мастеру (хабу, если утилита — оркестратор) и «Отдать хабу»: `/api/unit/<id>/task|hub` с `{text}`.
    case task(unit: String, text: String)
    case handToHub(unit: String, text: String)
    /// «Записать дела»: `/api/commit`.
    case commitCases

    /// Самое длинное настоящее действие: задача в `StudioText.maxLength` знаков, каждый может вырасти в экранированный вид.
    static let wireLimit = 32 * 1024

    /// Строго: ровно одно известное действие и ровно его поля. Кодирование остаётся синтезированным.
    init(from decoder: Decoder) throws {
        let wire = try LinkActionFields(from: decoder)
        switch wire.name {
        case "setFolder": self = .setFolder(try wire.value())
        case "openInBrowser": try wire.none(); self = .openInBrowser
        case "newLogin": try wire.none(); self = .newLogin
        case "reconnect": try wire.none(); self = .reconnect
        case "select": self = .select(try wire.value())
        case "deselect": try wire.none(); self = .deselect
        case "openSession": self = .openSession(try wire.value())
        case "stand": self = .stand(try wire.value())
        case "release": self = .release(try wire.value())
        case "rotate": self = .rotate(try wire.value())
        case "task":
            try wire.fields("unit", "text")
            self = .task(unit: try wire.field("unit"), text: try wire.field("text"))
        case "handToHub":
            try wire.fields("unit", "text")
            self = .handToHub(unit: try wire.field("unit"), text: try wire.field("text"))
        case "commitCases": try wire.none(); self = .commitCases
        default: throw wire.refuse()
        }
    }
}

/// Текст задачи: уходит в терминал мастера, поэтому чистится и ограничивается здесь, до сервера.
enum StudioText {
    static let maxLength = 4000

    /// Знаки, которых не видно, а действуют: управляющие (C0, DEL, C1 — U+009B терминал примет за CSI), форматные
    /// (bidi-переворот, нулевой ширины) и разделители строк и абзацев. В тексте сервера они подменяли бы видимое,
    /// в задаче ушли бы в терминал мастера.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Переводит строку: в однострочном тексте такой знак становится пробелом.
    static func breaksLine(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        return scalar == "\n" || scalar == "\r" || scalar == "\t" || category == .lineSeparator || category == .paragraphSeparator
    }

    /// Без невидимых знаков (`isHidden`), кроме перевода строки и табуляции; без пробелов по краям. nil — пусто или слишком длинно.
    static func task(_ raw: String) -> String? {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !isHidden($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= maxLength else { return nil }
        return cleaned
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

/// Адрес входа в браузер: только страница самой Студии на этом Mac.
enum StudioNavigation {
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

    /// Адрес входа с провода: тот же отбор, порт берётся из самого адреса.
    static func loginURL(_ page: String?) -> (url: URL, port: Int)? {
        guard let page, let url = URL(string: page), let port = port(of: url), isStudio(url, port: port) else { return nil }
        return (url, port)
    }
}

extension StudioState {
    /// Что экран покажет до первого ответа утилиты: сохранённая папка. Остальное знает только утилита.
    static func stored() -> StudioState {
        let folder = Kit.defaults.string(forKey: StudioKeys.folder).flatMap(StudioPath.validated) ?? ""
        return StudioState(folder: folder, phase: .stopped, message: nil, ownsServer: false, login: 0)
    }
}
